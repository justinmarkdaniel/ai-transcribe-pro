# AI Transcribe Pro

> Desktop voice dictation app with a custom dark-glass UI, powered by on-device AI speech recognition. Real-time transcription, global hotkey activation, persistent local history. Fully offline — no APIs, no cloud calls.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Status](https://img.shields.io/badge/status-active-brightgreen)

## Features

- **On-device AI speech recognition** — no API calls, no cloud round-trips, no per-request cost or latency
- **Custom dark-glass UI** — minimal, focused, designed to stay out of the way
- **Global hotkey activation** — start, pause, and resume transcription without leaving your current app
- **Real-time transcription** — text appears as you speak, with auto-scrolling and auto-copy to clipboard
- **Persistent local history** — every session is saved to disk and browsable from the menu bar
- **Pause / resume / stop** — multi-segment recording with the previous transcript preserved across pauses
- **Menu bar app** — runs in the background, no Dock clutter

## Why on-device?

|  | Cloud transcription | AI Transcribe Pro |
|---|---|---|
| **Privacy** | Audio leaves your device | Never leaves your device |
| **Latency** | Network round-trip per chunk | Inference runs locally |
| **Cost** | Per-minute API billing | Free at runtime |
| **Offline** | Doesn't work | Works the same |

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ to build from source
- Microphone and Speech Recognition permissions (prompted on first launch)

## Build

```bash
git clone https://github.com/justinmarkdaniel/ai-transcribe-pro.git
cd ai-transcribe-pro
./build.sh
open "build/AI Transcribe Pro.app"
```

The build script compiles the Swift package, wraps the binary in a proper `.app` bundle so macOS honours the `Info.plist` permission descriptions, and ad-hoc signs it so the system can attach a stable identity for microphone and speech-recognition access.

## Usage

| Action | Default hotkey |
|---|---|
| Start / pause / resume recording | ⌘⇧⌥R |
| Toggle recording (secondary) | ⌥Space |

Both hotkeys are remappable in **Settings**.

When a recording is paused or stopped, the current transcript is auto-copied to your clipboard.

## Architecture

Built with SwiftUI on top of Apple's `Speech` and `AVFoundation` frameworks.

| Module | Responsibility |
|---|---|
| `TranscriptionEngine` | Audio session, speech recognizer, finalization across pause/resume segments |
| `HotKeyManager` | Carbon-event-based global hotkey registration |
| `HistoryStore` / `SettingsStore` | Local persistence on disk |
| `ContentView` | SwiftUI main window |
| `AppDelegate` | Menu bar integration, panel positioning, lifecycle |

## Privacy

Everything runs locally:

- No network requests
- No telemetry
- No analytics
- Audio buffers are released as soon as a session ends; the audio engine is rebuilt per session to fully detach from the mic hardware between recordings

## License

MIT — feel free to fork, modify, and share.
