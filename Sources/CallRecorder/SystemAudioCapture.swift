import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays (Zoom, Meet, Teams, Slack huddles, …) through a global
/// Core Audio process tap (macOS 14.2+), and writes it to an uncompressed CAF file.
///
/// Self-healing: Bluetooth headsets switch into call (HFP) mode when any app opens their mic,
/// which reconfigures the output device and stalls the tap. A watchdog and a default-output
/// listener rebuild the tap, and gaps are padded with silence so the track stays wall-clock
/// aligned with the mic track.
final class SystemAudioCapture {
    let level = LevelMeter()
    private(set) var firstHostTime: UInt64 = 0
    private(set) var restarts = 0

    // Tap state (owned by controlQueue)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var watchdog: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var lastPad = Date.distantPast // writeQueue
    private var lastRestart = Date.distantPast // controlQueue

    // Stream state (touched on ioQueue while running; replaced only while stopped)
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var loggedLayout = false

    // File state
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var framesWritten: Int64 = 0 // in fileFormat frames; only touched on writeQueue

    private let lastCallbackLock = NSLock()
    private var lastCallback = Date()

    private let controlQueue = DispatchQueue(label: "callrecorder.system.control")
    private let ioQueue = DispatchQueue(label: "callrecorder.system.io", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "callrecorder.system.write", qos: .utility)

    func start(writingTo url: URL) throws {
        try controlQueue.sync {
            do {
                try setUpTap()
                guard let tapFormat else { throw CoreAudioError(what: "no tap format", status: -1) }
                fileFormat = tapFormat
                file = try AVAudioFile(forWriting: url, settings: tapFormat.settings,
                                       commonFormat: tapFormat.commonFormat, interleaved: tapFormat.isInterleaved)
                try startDevice()
                running = true
            } catch {
                tearDownTap()
                file = nil
                throw error
            }
            installWatchers()
        }
    }

    func stop() {
        controlQueue.sync {
            running = false
            removeWatchers()
            tearDownTap()
        }
        ioQueue.sync {}
        writeQueue.sync {}
        file = nil // finalises the CAF
    }

    // MARK: - Tap lifecycle (controlQueue)

    private func setUpTap() throws {
        // 1. Tap of all processes' output, mixed down to stereo. Audio keeps playing normally.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Call Recorder"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        try caCheck(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create system audio tap")

        // 2. Read the tap's stream format rather than assuming one.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = caAddress(kAudioTapPropertyFormat)
        try caCheck(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")

        // 3. A private aggregate device that contains the tap, clocked by the current output device.
        let outputUID = try defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Call Recorder Tap",
            kAudioAggregateDeviceUIDKey: "local.callrecorder.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]
        try caCheck(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                    "create aggregate device")

        // The tap's samples arrive at the aggregate's rate (i.e. the output device's), which can differ
        // from kAudioTapPropertyFormat — e.g. a Bluetooth headset in call mode runs at 16 kHz.
        var deviceRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddr = caAddress(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectGetPropertyData(aggregateID, &rateAddr, 0, nil, &rateSize, &deviceRate) == noErr, deviceRate > 0 {
            if deviceRate != asbd.mSampleRate {
                NSLog("CallRecorder: tap reports %.0f Hz, aggregate runs at %.0f Hz; using the latter",
                      asbd.mSampleRate, deviceRate)
            }
            asbd.mSampleRate = deviceRate
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(what: "unsupported tap format", status: -1)
        }
        NSLog("CallRecorder: system stream format %@", fmt.description)
        tapFormat = fmt
        loggedLayout = false
        if let fileFormat, fileFormat != fmt {
            converter = AVAudioConverter(from: fmt, to: fileFormat)
        } else {
            converter = nil
        }

        // 4. IOProc on a dispatch queue (not the realtime thread).
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input: input, time: inputTime)
        }, "create IOProc")
    }

    private func startDevice() throws {
        markCallback()
        try caCheck(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    private func tearDownTap() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        ioQueue.sync {} // no IOProc block in flight past this point
    }

    private func restart(reason: String) {
        guard running else { return }
        // One device change can fire several triggers (rate listener, stall, slow stream); coalesce them.
        guard Date().timeIntervalSince(lastRestart) > 1.0 else { return }
        lastRestart = Date()
        restarts += 1
        NSLog("CallRecorder: restarting system tap (%@)", reason)
        tearDownTap()
        removeRateListener()
        installRateListener()
        do {
            try setUpTap()
            try startDevice()
        } catch {
            // Leave it torn down; the watchdog will try again.
            NSLog("CallRecorder: system tap restart failed: \(error)")
            tearDownTap()
            markCallback()
        }
    }

    private func installWatchers() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.secondsSinceCallback() > 1.0 { self.restart(reason: "stalled") }
        }
        timer.resume()
        watchdog = timer

        var addr = caAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.restart(reason: "output device changed") }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, listener)
        outputListener = listener
        installRateListener()
    }

    /// Bluetooth headsets change rate (44.1/48 kHz ↔ 16/24 kHz) when a call app opens their mic.
    /// The aggregate doesn't always notice, so rebuild the tap when the output device's rate changes.
    private func installRateListener() {
        guard let device = try? defaultOutputDevice() else { return }
        var addr = caAddress(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.restart(reason: "output sample rate changed") }
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, controlQueue, listener) == noErr {
            rateListener = listener
            rateListenerDevice = device
        }
    }

    private func removeRateListener() {
        if let rateListener {
            var addr = caAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &addr, controlQueue, rateListener)
        }
        rateListener = nil
        rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func removeWatchers() {
        watchdog?.cancel()
        watchdog = nil
        if let outputListener {
            var addr = caAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, outputListener)
        }
        outputListener = nil
        removeRateListener()
    }

    private func markCallback() {
        lastCallbackLock.lock(); lastCallback = Date(); lastCallbackLock.unlock()
    }

    private func secondsSinceCallback() -> TimeInterval {
        lastCallbackLock.lock(); defer { lastCallbackLock.unlock() }
        return Date().timeIntervalSince(lastCallback)
    }

    // MARK: - IO (ioQueue)

    private func handle(input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        markCallback()
        guard let format = tapFormat else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // If the output device also has input streams (e.g. a headset mic), they come first;
        // the tap's buffers are the last ones.
        let expected = format.isInterleaved ? 1 : Int(format.channelCount)
        if !loggedLayout {
            loggedLayout = true
            let layout = buffers.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
            NSLog("CallRecorder: system IOProc buffers [%@], using last %d", layout, expected)
        }
        guard buffers.count >= expected else { return }
        let first = buffers.count - expected
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frames = buffers[first].mDataByteSize / bytesPerFrame
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        copy.frameLength = frames

        let dest = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<expected {
            let src = buffers[first + i]
            guard let s = src.mData, let d = dest[i].mData else { continue }
            memcpy(d, s, Int(min(src.mDataByteSize, dest[i].mDataByteSize)))
        }

        var hostTime: UInt64 = 0
        if time.pointee.mFlags.contains(.hostTimeValid) {
            hostTime = time.pointee.mHostTime
            if firstHostTime == 0 { firstHostTime = hostTime }
        }
        level.update(copy)
        guard let out = convert(copy) else { return }
        let start = firstHostTime

        writeQueue.async { [weak self] in
            guard let self, let file = self.file, let fileFormat = self.fileFormat else { return }
            do {
                // Pad gaps (tap restarts) with silence so we stay aligned with wall-clock time.
                if hostTime != 0, start != 0 {
                    let elapsed = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: start)
                    let expectedFrames = Int64(elapsed * fileFormat.sampleRate)
                    let gap = expectedFrames - self.framesWritten
                    if gap > Int64(fileFormat.sampleRate * 0.2) {
                        NSLog("CallRecorder: padding %.2fs of silence in call audio", Double(gap) / fileFormat.sampleRate)
                        try self.writeSilence(frames: gap, to: file, format: fileFormat)
                        // Gaps in quick succession mean the stream runs slower than its declared
                        // rate (stale device format), not a one-off hiccup: rebuild the tap.
                        if Date().timeIntervalSince(self.lastPad) < 2 {
                            self.lastPad = .distantPast
                            self.controlQueue.async { self.restart(reason: "stream slower than declared rate") }
                        } else {
                            self.lastPad = Date()
                        }
                    }
                }
                try file.write(from: out)
                self.framesWritten += Int64(out.frameLength)
            } catch {
                NSLog("CallRecorder: system write failed: \(error)")
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let fileFormat else { return buffer }
        let ratio = fileFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return out.frameLength > 0 ? out : nil
    }

    private func writeSilence(frames: Int64, to file: AVAudioFile, format: AVAudioFormat) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, 48_000))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            silence.frameLength = n
            for b in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
            try file.write(from: silence)
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
    }
}
