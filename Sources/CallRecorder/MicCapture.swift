import AVFoundation
import Foundation

/// Records the default input device (your side of the call) to an uncompressed CAF file.
/// Kept separate from the system tap so mic sample-rate quirks (e.g. Bluetooth headsets
/// dropping to 16/24 kHz in call mode) don't interfere; the two are mixed on stop.
/// Survives input device changes mid-call (e.g. AirPods connecting) by restarting the engine
/// and converting to the format the file was opened with.
final class MicCapture {
    let level = LevelMeter()
    private(set) var firstHostTime: UInt64 = 0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var framesWritten: Int64 = 0 // in fileFormat frames

    func start(writingTo url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(what: "no microphone input available", status: -1)
        }
        NSLog("CallRecorder: mic format %@", format.description)
        fileFormat = format
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        do {
            try installAndStart()
        } catch {
            file = nil
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterDeviceChange() }
    }

    private func installAndStart() throws {
        guard let fileFormat else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(what: "no microphone input available", status: -1)
        }
        converter = format == fileFormat ? nil : AVAudioConverter(from: format, to: fileFormat)
        if converter != nil { NSLog("CallRecorder: mic now %@, converting to %@", format.description, fileFormat.description) }

        // The tap block runs on a non-realtime thread, so writing synchronously is fine.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if self.firstHostTime == 0, when.isHostTimeValid { self.firstHostTime = when.hostTime }
            self.level.update(buffer)
            guard let out = self.convertIfNeeded(buffer), let file = self.file else { return }
            do {
                // Pad gaps (device switches) with silence so we stay aligned with the call track.
                if when.isHostTimeValid, self.firstHostTime != 0 {
                    let elapsed = AVAudioTime.seconds(forHostTime: when.hostTime) - AVAudioTime.seconds(forHostTime: self.firstHostTime)
                    let gap = Int64(elapsed * fileFormat.sampleRate) - self.framesWritten
                    if gap > Int64(fileFormat.sampleRate * 0.2) {
                        NSLog("CallRecorder: padding %.2fs of silence in mic", Double(gap) / fileFormat.sampleRate)
                        try self.writeSilence(frames: gap, to: file, format: fileFormat)
                    }
                }
                try file.write(from: out)
                self.framesWritten += Int64(out.frameLength)
            } catch {
                NSLog("CallRecorder: mic write failed: \(error)")
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let fileFormat else { return buffer }
        let ratio = fileFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { NSLog("CallRecorder: mic convert failed: \(error)") }
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

    private func restartAfterDeviceChange() {
        guard file != nil else { return }
        NSLog("CallRecorder: input device changed, restarting mic capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try installAndStart() } catch { NSLog("CallRecorder: mic restart failed: \(error)") }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // finalises the CAF
    }
}
