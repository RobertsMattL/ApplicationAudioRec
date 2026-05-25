# ApplicationAudioRec

A macOS menu-bar app that records a single application's audio straight to MP3 —
no virtual audio device required.

It uses **ScreenCaptureKit** to capture per-app system audio and pipes the raw
PCM into **ffmpeg** (`libmp3lame`) for real-time MP3 encoding.

## Requirements

- macOS 13 or later (built/tested on macOS 26)
- Xcode command-line tools / Swift 5.9+
- `ffmpeg` on the system: `brew install ffmpeg`

## Build & run

```sh
./build.sh
open "ApplicationAudioRec.app"
```

A 🎙 icon appears in the menu bar (the app has no Dock icon or window).

### First launch — grant permission

The first time you hit **Start Recording**, macOS asks for **Screen Recording**
permission (ScreenCaptureKit captures audio under this permission). Approve it,
then **quit and reopen the app** — macOS only applies the grant on next launch.

If you miss the prompt: System Settings → Privacy & Security → Screen Recording
→ enable *ApplicationAudioRec*.

## Usage

Click the menu-bar icon:

- **Start / Stop Recording** — toggles capture. While recording the icon shows a
  live `🔴 m:ss` timer; on stop it briefly shows ✅.
- **Source** — pick which running app to record. No source is selected by
  default; choose one before recording.
- **Quality** — MP3 bitrate: 128 / 192 / 256 / 320 kbps (default 320).
- **Open Player…** — opens the built-in playback window (see below).
- **Open Recordings Folder** — recordings are saved to
  `~/Music/ApplicationAudioRec/` as `<App> <timestamp>.mp3`.

Start playback in the chosen app *before or after* hitting Start — only that
app's audio is captured, so notification sounds and other apps are excluded.

## Built-in player

**Open Player…** brings up a window listing every MP3 in the recordings folder
(newest first, with length). It plays them back with `AVAudioPlayer`:

- Double-click a row, or select one and press play, to start it.
- Transport controls: previous / play-pause / next (auto-advances at end of
  track; *previous* restarts the current track if you're more than 3s in).
- A seek slider with elapsed / total time, plus a volume slider.
- **Refresh** rescans the folder; **Show in Finder** reveals the current file.

## How it works

| Piece | Role |
|-------|------|
| `AudioRecorder.swift` | Builds a per-app `SCContentFilter`, runs an `SCStream` with `capturesAudio`, converts each CoreMedia buffer to interleaved Float32, and writes it to `ffmpeg`'s stdin. |
| `AppDelegate.swift` | Menu-bar UI, settings persistence, timer, permission/error alerts. |
| `PlayerWindowController.swift` | The playback window: track list, transport, seek/volume sliders. |
| `App.swift` | Bootstraps an `.accessory` (menu-bar-only) `NSApplication`. |
| `build.sh` | Compiles via SwiftPM and wraps the binary in a signed `.app`. |

## Notes & limitations

- **Re-granting permission after a rebuild:** ad-hoc-signed dev builds change
  identity when the binary changes, so macOS may ask for Screen Recording
  permission again after `./build.sh`. A real Developer ID signature avoids this.
- ffmpeg is located at `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`
  (a Finder-launched app doesn't inherit your shell `PATH`).
- Output is fixed at 48 kHz stereo, matching the capture configuration.
