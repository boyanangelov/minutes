# Call Recorder

A tiny macOS menu bar app that records calls — Zoom, Google Meet, Teams, Slack huddles, anything —
by capturing **all system audio** (the other participants) plus **your microphone**, and saving one
mixed `.m4a` per call to `~/Recordings`.

Requires macOS 14.4+. No dependencies, no Xcode project — just `swiftc`.

## Build & run

```sh
./build.sh            # builds build/Call Recorder.app
./build.sh --install  # also copies it to /Applications
open "build/Call Recorder.app"
```

Always launch the `.app` (not the bare binary) — macOS reads the permission prompts from the bundle.

## Use

Click the waveform icon in the menu bar → **Start Recording** (⌘R while the menu is open).
The icon turns red with a timer; the menu shows live levels for *Call* and *Mic*.
**Stop Recording** mixes and saves `~/Recordings/Call YYYY-MM-DD HH-mm-ss.m4a`.

- **Recent Recordings** / **Open Recordings Folder** — quick access.
- **Also Keep Separate Mic/System Tracks** — keeps the raw `.caf` tracks next to the mix.
- Quitting while recording finishes and saves the recording first.

## Transcription (on-device)

After each recording, a transcript `Call … .txt` is saved next to the `.m4a`, labelled by speaker:

```
[00:00:03] Them: Hi team, thanks for joining. Let's start with the roadmap update.
[00:00:09] Me: Sounds good, I'll share my screen.
```

- Engine: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`brew install whisper-cpp`), Metal-accelerated on M1.
- Model: **Whisper `tiny`, q5_1-quantised (~31 MB)**, the smallest Whisper model, multilingual.
  Plus the Silero VAD model (<1 MB), which skips silence so Whisper doesn't hallucinate text in it.
  Both are downloaded on first use to `~/Library/Application Support/CallRecorder/`.
- Mic and call audio are transcribed separately, giving the "Me" / "Them" labels. Toggle it in the menu.
- Speed: a few seconds per minute of audio on M1. Nothing leaves your Mac.
- Language is auto-detected per track (from the first 30 s), so a call that switches languages midway
  gets forced into the first one. Tiny is the least accurate Whisper: fine for gist and search, rough on names
  and non-English. For better quality, drop `ggml-base-q5_1.bin` (~57 MB) or `ggml-small-q5_1.bin`
  (~190 MB) into the folder above and change `modelName` in `Transcriber.swift`.
- On laptop speakers (no headphones) the mic hears the call too, so some "Them" lines may also appear as "Me".

## Permissions

First recording triggers two prompts:

1. **Microphone** — your voice.
2. **System Audio Recording** (Privacy & Security → *Screen & System Audio Recording*) — the call.
   Without it the tap silently records nothing; the menu shows a warning if no call audio is seen after 15 s.

The app is ad-hoc signed, so after rebuilding macOS may treat it as a new app. If permissions get stuck:

```sh
tccutil reset Microphone local.callrecorder.app
tccutil reset AudioCapture local.callrecorder.app
```

## How it works

- `SystemAudioCapture` — global Core Audio process tap (`CATapDescription`) inside a private
  aggregate device; audio keeps playing normally. Written to CAF while recording.
- `MicCapture` — `AVAudioEngine` input node, written to its own CAF (handles Bluetooth headsets
  that drop to 16/24 kHz in call mode).
- `Mixer` — on stop, resamples both to 48 kHz, aligns them by their first-buffer host timestamps,
  sums, and encodes stereo AAC 128 kbps.
- In-progress files live in `~/Recordings/.in-progress/`; if mixing fails, the raw tracks are kept there.

### Bluetooth headsets

When any app opens a Bluetooth headset's mic, the headset drops into call mode (e.g. 44.1 kHz → 16 kHz)
and the output device is reconfigured. The app opens the mic first so this settles before tapping,
and rebuilds the tap if the output device or its sample rate changes, or the stream stalls. Any gap is
padded with silence so the two tracks stay aligned. The menu bar shows ⚠︎ if the call side never
produced audio or the mic goes silent for more than 15 s.

## Diagnostics

```sh
open -W --stderr /tmp/cr.log "build/Call Recorder.app" --args --selftest 10   # record 10 s, log, quit
```

Logs the tap/mic formats, IOProc buffer layout, tap restarts, peak levels and the saved file's duration.

## Known limitations

- The mic follows the system default input. Switching input mid-call restarts it, and the short gap is padded with silence to keep alignment.
- Tested only with a Bluetooth headset so far. Built-in mic/speakers should work but haven't been verified.
- No auto-detection of calls: you start and stop recording yourself.
- Quitting while a transcript is being generated cancels it (the recording itself is already saved).

Recording laws vary: let call participants know you're recording.
