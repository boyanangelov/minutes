import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, starting, recording, processing }

    private var state = State.idle
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var levelItem: NSMenuItem!
    private var systemWarningItem: NSMenuItem!
    private var micWarningItem: NSMenuItem!
    private var lastItem: NSMenuItem!
    private var recentItem: NSMenuItem!
    private var keepTracksItem: NSMenuItem!
    private var transcribeItem: NSMenuItem!
    private var transcribingItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let transcriber = Transcriber()

    private var system: SystemAudioCapture?
    private var mic: MicCapture?
    private var micDenied = false
    private var startDate = Date()
    private var timer: Timer?
    private var sessionName = ""
    private var tempDir: URL!
    private var lastRecording: URL?
    private var pendingTerminate = false
    private var selfTestSeconds: Double?

    private var transcribeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "transcribe") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "transcribe") }
    }

    private var keepTracks: Bool {
        get { UserDefaults.standard.bool(forKey: "keepSeparateTracks") }
        set { UserDefaults.standard.set(newValue, forKey: "keepSeparateTracks") }
    }

    static let recordingsFolder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        statusItem.menu = menu
        updateUI()

        // `--selftest N`: record N seconds, log diagnostics, quit. Used to verify the capture path.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            selfTestSeconds = secs
            NSLog("Minutes: selftest %.0fs starting", secs)
            DispatchQueue.main.asyncAfter(deadline: .now() + secs + 60) {
                NSLog("Minutes: selftest watchdog fired, exiting")
                exit(2)
            }
            requestMicThenStart()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .idle:
            return .terminateNow
        case .recording:
            pendingTerminate = true
            stopRecording()
            return .terminateLater
        case .starting, .processing:
            pendingTerminate = true // handled once start/save finishes
            return .terminateLater
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        toggleItem.target = self
        menu.addItem(toggleItem)

        levelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        levelItem.isEnabled = false
        menu.addItem(levelItem)

        systemWarningItem = NSMenuItem(title: "⚠︎ No call audio yet — check System Audio permission…",
                                       action: #selector(openSystemAudioSettings), keyEquivalent: "")
        systemWarningItem.target = self
        menu.addItem(systemWarningItem)

        micWarningItem = NSMenuItem(title: "⚠︎ Microphone not recorded — grant access…",
                                    action: #selector(openMicSettings), keyEquivalent: "")
        micWarningItem.target = self
        menu.addItem(micWarningItem)

        transcribingItem = NSMenuItem(title: "Transcribing…", action: nil, keyEquivalent: "")
        transcribingItem.isEnabled = false
        menu.addItem(transcribingItem)

        menu.addItem(.separator())

        lastItem = NSMenuItem(title: "", action: #selector(revealLast), keyEquivalent: "")
        lastItem.target = self
        menu.addItem(lastItem)

        recentItem = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu()
        menu.addItem(recentItem)

        let open = NSMenuItem(title: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        keepTracksItem = NSMenuItem(title: "Also Keep Separate Mic/System Tracks",
                                    action: #selector(toggleKeepTracks), keyEquivalent: "")
        keepTracksItem.target = self
        menu.addItem(keepTracksItem)

        transcribeItem = NSMenuItem(title: "Transcribe Recordings (Whisper tiny, on-device)",
                                    action: #selector(toggleTranscribe), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Minutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildRecent()
        updateUI()
    }

    private func rebuildRecent() {
        let sub = recentItem.submenu!
        sub.removeAllItems()
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.recordingsFolder,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let recent = files
            .filter { $0.pathExtension == "m4a" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(8)
        if recent.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for url in recent {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            sub.addItem(item)
        }
    }

    private func updateUI() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "waveform.circle"
        case .recording: symbol = "record.circle.fill"
        case .starting, .processing: symbol = "hourglass.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Minutes")
        let elapsed = Date().timeIntervalSince(startDate)
        let systemProblem = system == nil || (elapsed > 15 && (system?.level.maxSeen ?? 0) == 0)
        let micSilentFor = mic?.level.secondsSinceSignal ?? .infinity
        let micProblem = micDenied || mic == nil || (elapsed > 15 && micSilentFor > 15)

        if state == .recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = image?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.title = (systemProblem || micProblem ? " ⚠︎ " : " ") + formatElapsed(elapsed)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            image?.isTemplate = true
            button.image = image
            button.title = state == .processing ? " Saving…" : state == .starting ? " Starting…" : ""
        }

        switch state {
        case .idle:
            toggleItem.title = "Start Recording"
            toggleItem.isEnabled = true
        case .recording:
            toggleItem.title = "Stop Recording"
            toggleItem.isEnabled = true
        case .starting:
            toggleItem.title = "Starting…"
            toggleItem.isEnabled = false
        case .processing:
            toggleItem.title = "Saving recording…"
            toggleItem.isEnabled = false
        }

        if state == .recording {
            let sysPeak = system?.level.takePeak() ?? 0
            let micPeak = mic?.level.takePeak() ?? 0
            levelItem.title = "Call  \(bars(sysPeak))    Mic  \(micDenied || mic == nil ? "off" : bars(micPeak))"
            levelItem.isHidden = false
            systemWarningItem.title = system == nil
                ? "⚠︎ Call audio capture failed to start — check permission…"
                : "⚠︎ No call audio yet — check System Audio permission…"
            systemWarningItem.isHidden = !systemProblem
            micWarningItem.title = (micDenied || mic == nil)
                ? "⚠︎ Microphone not recorded — grant access…"
                : "⚠︎ Microphone is silent — check input device…"
            micWarningItem.isHidden = !micProblem
        } else {
            levelItem.isHidden = true
            systemWarningItem.isHidden = true
            micWarningItem.isHidden = true
        }

        if let lastRecording {
            lastItem.title = "Show Last: \(lastRecording.deletingPathExtension().lastPathComponent)"
            lastItem.isHidden = false
        } else {
            lastItem.isHidden = true
        }
        keepTracksItem.state = keepTracks ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
        if Transcriber.whisperPath == nil {
            transcribeItem.title = "Transcription needs whisper.cpp: brew install whisper-cpp"
            transcribeItem.isEnabled = false
            transcribeItem.state = .off
        } else {
            transcribeItem.title = "Transcribe Recordings (Whisper tiny, on-device)"
            transcribeItem.isEnabled = true
            transcribeItem.state = transcribeEnabled ? .on : .off
        }
        transcribingItem.isHidden = transcriber.pending == 0
        transcribingItem.title = transcriber.pending > 1 ? "Transcribing \(transcriber.pending) recordings…" : "Transcribing…"
    }

    private func bars(_ peak: Float) -> String {
        // Map peak (dBFS -60…0) onto 8 blocks.
        let db = peak > 0 ? 20 * log10(peak) : -100
        let n = max(0, min(8, Int(((db + 60) / 60) * 8)))
        return String(repeating: "▮", count: n) + String(repeating: "▯", count: 8 - n)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        switch state {
        case .idle: requestMicThenStart()
        case .recording: stopRecording()
        case .starting, .processing: break
        }
    }

    private func requestMicThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micDenied = false
            startRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.micDenied = !granted
                    self.startRecording()
                }
            }
        default:
            micDenied = true
            startRecording()
        }
    }

    private func startRecording() {
        guard state == .idle else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        sessionName = "Minutes \(formatter.string(from: Date()))"
        tempDir = Self.recordingsFolder.appendingPathComponent(".in-progress/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        state = .starting
        updateUI()
        let dir = tempDir!
        let useMic = !micDenied

        // Creating the tap and opening the mic can take seconds (Bluetooth headsets switch
        // into call mode), so do it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            func startMic() -> MicCapture? {
                guard useMic else { return nil }
                let m = MicCapture()
                do { try m.start(writingTo: dir.appendingPathComponent("mic.caf")); return m } catch {
                    NSLog("Minutes: mic capture failed: \(error)")
                    return nil
                }
            }
            func startSystem() -> SystemAudioCapture? {
                let sys = SystemAudioCapture()
                do { try sys.start(writingTo: dir.appendingPathComponent("system.caf")); return sys } catch {
                    NSLog("Minutes: system capture failed: \(error)")
                    return nil
                }
            }
            // Mic first: opening a Bluetooth headset's mic switches it into call mode, which
            // reconfigures the output device. Let that settle before tapping system audio.
            // (`--tap-first` reverses this to exercise the tap-rebuild path in tests.)
            var m: MicCapture?
            var sys: SystemAudioCapture?
            if CommandLine.arguments.contains("--tap-first") {
                sys = startSystem(); m = startMic()
            } else {
                m = startMic(); sys = startSystem()
            }
            DispatchQueue.main.async { self.didStart(system: sys, mic: m) }
        }
    }

    private func didStart(system sys: SystemAudioCapture?, mic m: MicCapture?) {
        system = sys
        mic = m
        if sys == nil && m == nil {
            state = .idle
            updateUI()
            try? FileManager.default.removeItem(at: tempDir)
            if pendingTerminate { NSApp.reply(toApplicationShouldTerminate: true); return }
            showError("Couldn't start recording",
                      "Neither system audio nor the microphone could be captured. Check System Settings → Privacy & Security → Screen & System Audio Recording and Microphone.")
            return
        }

        state = .recording
        startDate = Date()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateUI() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateUI()

        if pendingTerminate {
            stopRecording()
        } else if let secs = selfTestSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.stopRecording() }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        timer?.invalidate()
        timer = nil
        state = .processing
        updateUI()

        let sys = system, m = mic
        system = nil
        mic = nil
        let dir = tempDir!
        let name = sessionName
        let keep = keepTracks
        let transcribe = transcribeEnabled && Transcriber.whisperPath != nil

        DispatchQueue.global(qos: .userInitiated).async {
            sys?.stop()
            m?.stop()

            var micDelay = 0.0
            if let sh = sys?.firstHostTime, let mh = m?.firstHostTime, sh != 0, mh != 0 {
                micDelay = AVAudioTime.seconds(forHostTime: mh) - AVAudioTime.seconds(forHostTime: sh)
            }
            let sysURL = sys != nil ? dir.appendingPathComponent("system.caf") : nil
            let micURL = m != nil ? dir.appendingPathComponent("mic.caf") : nil
            let dest = Self.uniqueURL(name: name, ext: "m4a")

            let sysPeak = sys?.level.maxSeen ?? -1
            let micPeak = m?.level.maxSeen ?? -1
            NSLog("Minutes: stopped. system max peak %.4f (tap restarts: %d), mic max peak %.4f, mic delay %.3fs",
                  sysPeak, sys?.restarts ?? 0, micPeak, micDelay)

            var result: Result<URL, Error>
            var job: Transcriber.Job?
            do {
                try Mixer.mix(system: sysURL, mic: micURL, micDelay: micDelay, to: dest)
                let fm = FileManager.default

                if transcribe {
                    // Per-track 16 kHz WAVs on the mix's timeline, so the transcript can say who spoke.
                    var tracks: [Transcriber.Track] = []
                    if let sysURL, sysPeak > 0 {
                        let wav = dir.appendingPathComponent("them.wav")
                        do {
                            try Mixer.exportSpeechWAV(source: sysURL, leadingSeconds: max(0, -micDelay), to: wav)
                            tracks.append(.init(label: "Them", wav: wav))
                        } catch { NSLog("Minutes: export call track for transcription failed: \(error)") }
                    }
                    if let micURL, micPeak > 0 {
                        let wav = dir.appendingPathComponent("me.wav")
                        do {
                            try Mixer.exportSpeechWAV(source: micURL, leadingSeconds: max(0, micDelay), to: wav)
                            tracks.append(.init(label: "Me", wav: wav))
                        } catch { NSLog("Minutes: export mic track for transcription failed: \(error)") }
                    }
                    if !tracks.isEmpty {
                        job = .init(title: name, tracks: tracks,
                                    output: dest.deletingPathExtension().appendingPathExtension("txt"), workDir: dir)
                    }
                }

                if keep {
                    if let sysURL { try? fm.moveItem(at: sysURL, to: Self.uniqueURL(name: "\(name) - call audio", ext: "caf")) }
                    if let micURL { try? fm.moveItem(at: micURL, to: Self.uniqueURL(name: "\(name) - mic", ext: "caf")) }
                }
                if job == nil {
                    try? fm.removeItem(at: dir)
                } else {
                    // The transcriber deletes the work dir when done; drop the big CAFs now.
                    if let sysURL { try? fm.removeItem(at: sysURL) }
                    if let micURL { try? fm.removeItem(at: micURL) }
                }
                result = .success(dest)
            } catch {
                // Keep the raw tracks so nothing is lost.
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.state = .idle
                let selfTest = self.selfTestSeconds != nil
                switch result {
                case .success(let url):
                    self.lastRecording = url
                    if let f = try? AVAudioFile(forReading: url) {
                        NSLog("Minutes: saved %@ (%.2fs)", url.path, Double(f.length) / f.fileFormat.sampleRate)
                    }
                    if !selfTest && (sys == nil || sysPeak == 0) {
                        self.showError("Call audio was not captured",
                                       "The recording was saved, but the call side (system audio) is silent. Make sure Minutes is allowed under System Settings → Privacy & Security → Screen & System Audio Recording.")
                    }
                case .failure(let error):
                    NSLog("Minutes: save failed: \(error)")
                    if !selfTest {
                        self.showError("Couldn't save the mixed recording",
                                       "\(error)\n\nThe raw tracks were kept in:\n\(dir.path)")
                    }
                }
                if let job {
                    let started = Date()
                    self.transcriber.enqueue(job) { r in
                        switch r {
                        case .success(let txt):
                            NSLog("Minutes: transcript saved %@ (%.1fs)", txt.path, Date().timeIntervalSince(started))
                        case .failure(let error):
                            NSLog("Minutes: transcription failed: \(error)")
                        }
                        self.updateUI()
                        if selfTest && self.transcriber.pending == 0 {
                            NSLog("Minutes: selftest done")
                            NSApp.terminate(nil)
                        }
                    }
                }
                self.updateUI()
                if selfTest {
                    if job == nil {
                        NSLog("Minutes: selftest done")
                        NSApp.terminate(nil)
                    }
                    return
                }
                if self.pendingTerminate {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    private static func uniqueURL(name: String, ext: String) -> URL {
        var url = recordingsFolder.appendingPathComponent(name).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsFolder.appendingPathComponent("\(name) (\(i))").appendingPathExtension(ext)
            i += 1
        }
        return url
    }

    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    @objc private func revealLast() {
        if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            NSAlert(error: error).runModal()
        }
        updateUI()
    }

    @objc private func toggleTranscribe() {
        transcribeEnabled.toggle()
        updateUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.cancelAll()
    }

    @objc private func toggleKeepTracks() {
        keepTracks.toggle()
        updateUI()
    }

    @objc private func openSystemAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
