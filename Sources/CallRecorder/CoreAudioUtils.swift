import AVFoundation
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func caCheck(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

func caAddress(_ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() throws -> AudioDeviceID {
    var addr = caAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try caCheck(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                "read default output device")
    return device
}

func defaultOutputDeviceUID() throws -> String {
    let device = try defaultOutputDevice()

    var uidAddr = caAddress(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try caCheck(AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uid), "read output device UID")
    guard let uid else { throw CoreAudioError(what: "read output device UID", status: -1) }
    return uid.takeRetainedValue() as String
}

/// Thread-safe peak meter. `current` decays between UI reads; `maxSeen` tracks the loudest sample ever.
final class LevelMeter {
    private let lock = NSLock()
    private var peak: Float = 0
    private var everMax: Float = 0

    func update(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        var p: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let ch = data[c]
            var i = 0
            while i < frames * stride {
                let v = abs(ch[i])
                if v > p { p = v }
                i += stride
            }
        }
        lock.lock()
        if p > peak { peak = p }
        if p > everMax { everMax = p }
        if p > 0 { lastSignal = Date() }
        lock.unlock()
    }

    private var lastSignal: Date?

    /// Seconds since a non-zero sample was seen (nil = never). A live mic is never exactly 0.
    var secondsSinceSignal: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastSignal.map { Date().timeIntervalSince($0) }
    }

    /// Returns the peak since the last call and resets it.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak
        peak = 0
        return p
    }

    var maxSeen: Float {
        lock.lock(); defer { lock.unlock() }
        return everMax
    }
}
