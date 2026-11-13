import Foundation

/// Local, offline transcription with whisper.cpp (`brew install whisper-cpp`) and the smallest
/// Whisper model, `tiny` quantised to q5_1 (~31 MB, multilingual, Metal-accelerated on Apple Silicon).
/// The mic and call tracks are transcribed separately so lines can be labelled "Me" / "Them".
final class Transcriber {
    struct Track { let label: String; let wav: URL }
    struct Job { let title: String; let tracks: [Track]; let output: URL; let workDir: URL }

    static let modelName = "ggml-tiny-q5_1.bin"
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!

    /// Silero voice-activity detection (<1 MB). Each per-speaker track is mostly silence (the other
    /// side talking), and Whisper hallucinates text on silence; VAD skips it and fixes timestamps.
    static let vadModelName = "ggml-silero-v5.1.2.bin"
    static let vadDownloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CallRecorder", isDirectory: true)
    static var modelURL: URL { supportDir.appendingPathComponent(modelName) }
    static var vadModelURL: URL { supportDir.appendingPathComponent(vadModelName) }

    static var whisperPath: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Number of queued or running jobs. Main thread only.
    private(set) var pending = 0
    private let queue = DispatchQueue(label: "callrecorder.transcribe", qos: .utility)
    private let processLock = NSLock()
    private var current: Process?

    func enqueue(_ job: Job, completion: @escaping (Result<URL, Error>) -> Void) {
        pending += 1
        queue.async {
            let result = Result { try self.run(job) }
            try? FileManager.default.removeItem(at: job.workDir)
            DispatchQueue.main.async {
                self.pending -= 1
                completion(result)
            }
        }
    }

    func cancelAll() {
        processLock.lock(); current?.terminate(); processLock.unlock()
    }

    // MARK: - Work (transcription queue)

    private func run(_ job: Job) throws -> URL {
        guard let whisper = Self.whisperPath else {
            throw CoreAudioError(what: "whisper-cli not found (brew install whisper-cpp)", status: -1)
        }
        try download(Self.modelDownloadURL, to: Self.modelURL)
        try download(Self.vadDownloadURL, to: Self.vadModelURL)

        var segments: [(startMs: Int, label: String, text: String)] = []
        for track in job.tracks {
            let base = track.wav.deletingPathExtension()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: whisper)
            p.arguments = ["-m", Self.modelURL.path, "-f", track.wav.path, "-l", "auto",
                           "--vad", "-vm", Self.vadModelURL.path, "-sns",
                           "-ocsv", "-of", base.path, "-np"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            processLock.lock(); current = p; processLock.unlock()
            p.waitUntilExit()
            processLock.lock(); current = nil; processLock.unlock()
            guard p.terminationStatus == 0 else {
                throw CoreAudioError(what: "whisper-cli (\(track.label))", status: p.terminationStatus)
            }
            let csv = try String(contentsOf: base.appendingPathExtension("csv"), encoding: .utf8)
            segments += Self.parseCSV(csv).map { ($0.startMs, track.label, $0.text) }
        }
        segments.sort { $0.startMs < $1.startMs }

        // Merge consecutive lines from the same speaker into one paragraph.
        var lines: [String] = []
        var cur: (startMs: Int, label: String, text: String)?
        for s in segments {
            if let c = cur, c.label == s.label {
                cur = (c.startMs, c.label, c.text + " " + s.text)
            } else {
                if let c = cur { lines.append(Self.format(c)) }
                cur = s
            }
        }
        if let c = cur { lines.append(Self.format(c)) }

        let header = "\(job.title)\nTranscribed locally with Whisper tiny (whisper.cpp). Speakers: \(job.tracks.map(\.label).joined(separator: ", ")).\n\n"
        let body = lines.isEmpty ? "(no speech detected)\n" : lines.joined(separator: "\n\n") + "\n"
        try (header + body).write(to: job.output, atomically: true, encoding: .utf8)
        return job.output
    }

    private func download(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSLog("CallRecorder: downloading %@", destination.lastPathComponent)

        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        URLSession.shared.downloadTask(with: source) { tmp, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                failure = CoreAudioError(what: "model download", status: -1)
                return
            }
            do { try fm.moveItem(at: tmp, to: destination) } catch { failure = error }
        }.resume()
        done.wait()
        if let failure { throw failure }
    }

    private static func format(_ s: (startMs: Int, label: String, text: String)) -> String {
        let t = s.startMs / 1000
        return String(format: "[%02d:%02d:%02d] ", t / 3600, (t / 60) % 60, t % 60) + "\(s.label): \(s.text)"
    }

    /// Parses whisper-cli's `start,end,"text"` CSV (times in ms), dropping non-speech markers
    /// like `[BLANK_AUDIO]` or `(music)` that Whisper emits for silence.
    static func parseCSV(_ csv: String) -> [(startMs: Int, text: String)] {
        var out: [(Int, String)] = []
        for line in csv.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let start = Int(parts[0]) else { continue }
            var text = String(parts[2]).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
            if text.isEmpty || marker { continue }
            out.append((start, text))
        }
        return out
    }
}
