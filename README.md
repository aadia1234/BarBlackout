<div align="center">
  <img src="BarBlackout/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="BarBlackout Logo" width="96" height="96" />
  <h1>BarBlackout</h1>
  <p><strong>Hide your macOS menu bar on a timer — and automatically while you watch video.</strong></p>
</div>

![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white&style=for-the-badge)
![SwiftUI](https://img.shields.io/badge/SwiftUI-0071E3?logo=swift&logoColor=white&style=for-the-badge)
![AppKit](https://img.shields.io/badge/AppKit-1575F9?logo=apple&logoColor=white&style=for-the-badge)
![Combine](https://img.shields.io/badge/Combine-FF3B30?style=for-the-badge)
![IOKit](https://img.shields.io/badge/IOKit-4A4A4A?style=for-the-badge)
![Core Graphics](https://img.shields.io/badge/Core%20Graphics-6E56CF?style=for-the-badge)
![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white&style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

<!--
  ┌─────────────────────────────────────────────────────────────────────────┐
  │ TODO: Record a <5s looping demo GIF and drop it here. This is the single │
  │ biggest lever for stars. Show: menu bar blacking out → hover-to-reveal → │
  │ the ring icon filling as the timer runs down. Save as docs/demo.gif.     │
  │ Record with QuickTime/Kap, convert to GIF, keep it under ~5 MB.          │
  └─────────────────────────────────────────────────────────────────────────┘
-->
<div align="center">
  <img src="docs/demo.gif" alt="BarBlackout in action" width="720" />
</div>

## The problem this solves

macOS gives you **no public API to know whether the user is watching a video right now.**
The private one that would (`MediaRemote`) was locked down in **macOS 15.4** —
non-entitled processes now get nothing back from it.

BarBlackout works around that. It ANDs two *public* signals for the frontmost app —
it holds a **display-sleep assertion** (which video players take specifically for
visual playback) **and** it is **actively outputting audio** — to infer "video is
playing" reliably enough to auto-hide the menu bar during playback and bring it back
the instant you pause or switch away.

If the reverse-engineering is what you're here for, jump to
[**How it works**](#how-it-works) or read the annotated
[`VideoDetector.swift`](BarBlackout/VideoDetector.swift) — that's the core of the project.

Instead of toggling a system setting, the app draws a borderless black window one level
above the menu bar, so nothing about your Mac's configuration changes and the bar
returns the moment the overlay drops.

## Install

**Homebrew (recommended):**

```bash
brew install --cask aadia1234/tap/barblackout
```

Homebrew clears the download quarantine for you, so the app just opens.

**Direct download:** grab `BarBlackout.dmg` from the
[latest release](https://github.com/aadia1234/BarBlackout/releases/latest), open it,
and drag the app to `/Applications`.

> The build is not (yet) notarized, so on first launch macOS Gatekeeper will warn you.
> **Right-click the app → Open**, then confirm once. You only do this the first time.

**From source:** see [Building](#building) below.

## Features

- ⏱️ **Timed blackouts:** presets at 15m / 30m / 45m / 1h / 2h / 4h, a custom slider
  from 0–24 hours in 15-minute steps, or `∞` to hide indefinitely.
- 🎯 **Context-aware modes:**
  - `always` — blackout regardless of what's on screen.
  - `desktopOnly` — blackout on the desktop, step aside in full screen.
  - `fullScreenOnly` — blackout only inside a full-screen Space.
  - `videoOnly` — blackout only when video is actually playing in full screen.
- 🎥 **Real video detection:** the heuristic above — a frontmost player holding a
  display-sleep assertion *and* outputting audio. Pausing or switching apps releases
  the overlay; a short grace period keeps the bar from strobing during ad breaks and seeking.
- 🖥️ **Full-screen aware:** reads the active Space type from the window server, which
  needs no Accessibility or Screen Recording permission.
- 👆 **Hover to reveal:** the overlay yields when your cursor enters the menu-bar zone,
  including for the app's own status item.
- 🌘 **The icon is the timer:** the status mark is a ring that fills from its right edge
  as the countdown runs — empty while blacked out, a solid disc once the bar is back.
- 🪶 **Stays out of the way:** runs as a background agent (`LSUIElement`), no Dock icon.

## How it works

### Detecting video playback without MediaRemote

No macOS API answers "is the user watching video right now?" directly:

- **MediaRemote** (private) would — but Apple restricted it in macOS 15.4, so
  non-entitled processes get nothing.
- **CoreAudio** reports audio output per process, but audio ≠ video.
- **IOKit's display-sleep assertion** is taken specifically for *visual* playback
  (`AVPlayer.preventsDisplaySleepDuringVideoPlayback`); audio-only players
  deliberately *don't* take it, since music shouldn't keep the screen awake.

So BarBlackout **ANDs two public signals** for the frontmost app: it holds a
display-sleep assertion **and** it is actively outputting audio. The audio gate is
what drops false positives from presentations and screen sharing, which take the same
assertion silently. Known trade-off: a *muted* video doesn't register.

A wrinkle worth reading the code for: **browsers don't play media in their main
process.** Chrome uses renderer helpers (children of the main process); Safari uses
WebKit `WebContent` processes, which aren't children at all — they're reparented and
link back only via "responsible pid." BarBlackout walks the process tree *and* the
responsible-pid chain so audio from a Chrome/Safari tab is correctly attributed to the
frontmost browser. See [`VideoDetector.swift`](BarBlackout/VideoDetector.swift).

### Full-screen detection (private API, handled safely)

Full-screen detection uses the private `CGSCopyManagedDisplaySpaces` /
`_CGSDefaultConnection` entry points, resolved at runtime via `dlsym` so a missing
symbol degrades to "not full screen" rather than crashing. This is deliberate: the
menu-bar reserve does **not** change inside a full-screen Space, and a display-sized
layer-0 window doesn't appear in `CGWindowList` either — so neither public signal
works. The trade-off is that **the app can't ship on the Mac App Store** as written;
it's distributed directly and via Homebrew instead.

## Technology stack

| Layer        | Tools & Frameworks                                                       |
| ------------ | ------------------------------------------------------------------------ |
| **Language** | Swift                                                                     |
| **UI**       | SwiftUI • AppKit • `NSStatusItem` • `NSBezierPath` (status icon drawing)  |
| **State**    | Combine • `ObservableObject` • `UserDefaults`                            |
| **System**   | IOKit power assertions • CoreAudio process API • Core Graphics • SkyLight |
| **Build**    | Xcode • `xcodebuild`                                                      |
| **Platform** | macOS                                                                     |

## Building

```bash
git clone https://github.com/aadia1234/BarBlackout.git
cd BarBlackout
open BarBlackout.xcodeproj
```

Then run the `BarBlackout` scheme. Or from the command line:

```bash
xcodebuild -project BarBlackout.xcodeproj -scheme BarBlackout -configuration Release build
```

## Contributing

Issues and PRs are welcome — bug reports, player-detection edge cases, and feedback on
the heuristic are especially useful.

## License

[MIT](LICENSE) © 2026 Aadi Anand
