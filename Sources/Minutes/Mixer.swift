import AVFoundation
import Foundation

/// Mixes the system-audio and mic recordings into one stereo AAC .m4a, aligning their start times.
enum Mixer {
    static let outputRate: Double = 48_000

    /// - Parameter micDelay: seconds the mic recording started after the system recording (may be negative).
    static func mix(system: URL?, mic: URL?, micDelay: Double, to destination: URL) throws {
        let sysLead = micDelay < 0 ? Int(-micDelay * outputRate) : 0
        let micLead = micDelay > 0 ? Int(micDelay * outputRate) : 0
        let sys = system.flatMap { SourceReader(url: $0, sampleRate: outputRate, leadingSilence: sysLead) }
        let mic = mic.flatMap { SourceReader(url: $0, sampleRate: outputRate, leadingSilence: micLead) }
        guard sys != nil || mic != nil else {
            throw CoreAudioError(what: "nothing was recorded", status: -1)
        }

        let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let out = try AVAudioFile(forWriting: destination, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)

        let chunk = 8192
        while true {
            let s = sys?.read(chunk) ?? []
            let m = mic?.read(chunk) ?? []
            let sn = s.first?.count ?? 0
            let mn = m.first?.count ?? 0
            let n = max(sn, mn)
            if n == 0 { break }

            guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            let left = buf.floatChannelData![0]
            let right = buf.floatChannelData![1]
            let micScale: Float = m.isEmpty ? 0 : 1 / Float(m.count)

            for i in 0..<n {
                var l: Float = 0, r: Float = 0
                if i < sn {
                    l = s[0][i]
                    r = s.count > 1 ? s[1][i] : s[0][i]
                }
                if i < mn {
                    var v: Float = 0
                    for ch in m { v += ch[i] }
                    v *= micScale
                    l += v
                    r += v
                }
                left[i] = max(-1, min(1, l))
                right[i] = max(-1, min(1, r))
            }
            try out.write(from: buf)
        }
    }
}

extension Mixer {
    /// Writes a 16 kHz mono 16-bit WAV (what Whisper wants), with `leadingSeconds` of silence so its
    /// timeline matches the mixed recording.
    static func exportSpeechWAV(source: URL, leadingSeconds: Double, to destination: URL) throws {
        let rate = 16_000.0
        guard let reader = SourceReader(url: source, sampleRate: rate, leadingSilence: Int(leadingSeconds * rate)) else {
            throw CoreAudioError(what: "read \(source.lastPathComponent)", status: -1)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let out = try AVAudioFile(forWriting: destination, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        while true {
            let chunk = reader.read(16_384)
            let n = chunk.first?.count ?? 0
            if n == 0 { break }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            let dst = buf.floatChannelData![0]
            let scale = 1 / Float(chunk.count)
            for i in 0..<n {
                var v: Float = 0
                for ch in chunk { v += ch[i] }
                dst[i] = v * scale
            }
            try out.write(from: buf)
        }
    }
}

/// Streams a file, resampled to `sampleRate` (channel count preserved), as per-channel Float arrays.
private final class SourceReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private var leadingSilence: Int
    private var finished = false

    init?(url: URL, sampleRate: Double, leadingSilence: Int) {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        let inFormat = f.processingFormat
        guard let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                    channels: inFormat.channelCount, interleaved: false),
              let c = AVAudioConverter(from: inFormat, to: o) else { return nil }
        file = f
        outFormat = o
        converter = c
        self.leadingSilence = leadingSilence
    }

    /// Returns up to `count` frames per channel; fewer (or none) means end of stream.
    func read(_ count: Int) -> [[Float]] {
        let channels = Int(outFormat.channelCount)
        var result = Array(repeating: [Float](), count: channels)
        var need = count

        if leadingSilence > 0 {
            let s = min(need, leadingSilence)
            for c in 0..<channels { result[c].append(contentsOf: repeatElement(0, count: s)) }
            leadingSilence -= s
            need -= s
        }

        while need > 0 && !finished {
            guard let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(need)) else { break }
            var error: NSError?
            let status = converter.convert(to: buf, error: &error) { [file] inCount, inStatus in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCount) else {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuf, frameCount: inCount) } catch {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }
            let got = Int(buf.frameLength)
            if got > 0, let data = buf.floatChannelData {
                for c in 0..<channels {
                    result[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: got))
                }
            }
            need -= got
            if status == .endOfStream || status == .error || got == 0 {
                if let error { NSLog("Minutes: convert error \(error)") }
                finished = true
            }
        }
        return result
    }
}
