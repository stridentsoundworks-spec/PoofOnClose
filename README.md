# PoofOnClose

A macOS menu bar utility that plays a cartoon cloud-burst animation whenever a window closes — inspired by the classic Mac OS X "poof" that disappeared in macOS Sierra.

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/architecture-arm64-lightgrey" alt="Apple Silicon">
</p>

---

## Features

- **4 visual themes** — Classic Cloud ☁️, Comic POW 💥, Sparkle ✨, Ripple 🌊
- **Dynamic poof size** — scales proportionally to the closed window's area
- **Two position modes** — poof at your cursor or at the centre of the closed window
- **Overlapping sounds** — rapid window closes each play their own synthesised "whomp"
- **Custom sound support** — drop a `poof.aiff` into `src/` to replace the generated sound
- **Per-app skip/allow lists** — manage which apps trigger poofs via a built-in UI
- **Volume control** — inline slider in the menu bar
- **Launch at Login** — via `SMAppService` (macOS 13+, requires signed build)
- **Zero dependencies** — single Swift file, no SPM packages, no Xcode project required
- **Fully thread-safe** — all window tracking state runs on a dedicated serial queue

---

## Requirements

| | |
|---|---|
| **macOS** | 13.0 Ventura or later |
| **Architecture** | Apple Silicon (arm64) |
| **Xcode CLI Tools** | Required for `swiftc` |

> Intel Mac? Change `ARCH` in `build.sh` from `arm64-apple-macos13.0` to `x86_64-apple-macos13.0`.

---

## Quick Start

```bash
git clone https://github.com/stridentsoundworks-spec/PoofOnClose.git
cd PoofOnClose
./build.sh
open build/PoofOnClose.app
```

The app runs as a menu bar accessory (no Dock icon). Look for the **☁️ cloud icon** in your menu bar.

> **No special permissions required.** PoofOnClose uses `CGWindowListCopyWindowInfo` for window tracking — it does not need Accessibility permission.

---

## Building

```bash
./build.sh
```

The script will:
1. Compile `src/main.swift` with `xcrun swiftc` against the current macOS SDK
2. Assemble the `.app` bundle under `build/PoofOnClose.app`
3. Optionally code-sign if `SIGNING_IDENTITY` is set in `build.sh`

### Code Signing (optional)

Open `build.sh` and set your Developer ID:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

> **Note:** Launch at Login (`SMAppService`) requires a signed build installed in `/Applications`. It will not work with an unsigned ad hoc build.

### Custom Sound

Drop a file named `poof.aiff` into `src/` before running `build.sh`. It will be bundled into `Contents/Resources/` and used instead of the synthesised sound.

### Installing

```bash
cp -r build/PoofOnClose.app /Applications/
```

---

## Usage

Click the **☁️** icon in the menu bar to access all settings:

| Menu Item | Description |
|---|---|
| **Theme** | Switch between Cloud, POW, Sparkle, and Ripple animations |
| **Poof Position** | Spawn at cursor or at the closed window's centre |
| **Volume** | Inline slider, 0–100% |
| **Manage Apps…** | Skip List (never poof) and Allow List (override built-in exclusions) |
| **Launch at Login** | Persists across reboots (signed builds only, macOS 13+) |
| **Test Poof** | Preview the current theme at your cursor |

---

## How It Works

PoofOnClose polls `CGWindowListCopyWindowInfo` every 50 ms on a dedicated serial queue. When a window disappears:

1. It enters a **60 ms grace period** — if it reappears (minimise animation, Space switch) the poof is cancelled
2. Cooldowns suppress false triggers during **Space switches** (1 s) and **app switches** (0.5 s)
3. A **minimise heuristic** checks whether the app is still running with no on-screen windows — if so, the poof is suppressed for multi-window apps
4. If the window is genuinely gone, `CAEmitterLayer` fires the animation on the main thread

All shared state (`knownWindows`, `pendingPoofs`, `recentlyPoofed`) is protected by a single private serial `DispatchQueue`. `NSWorkspace` notification handlers are bounced onto this queue before touching any state.

---

## Known Limitations

- **Minimise detection is heuristic** — single-window apps that minimise may occasionally trigger a poof. The grace period and cooldowns make this rare in practice.
- **Launch at Login** requires a Developer ID-signed build installed in `/Applications` — this is an Apple platform requirement, not a PoofOnClose limitation.
- **Intel Mac** builds require changing the `-target` in `build.sh` manually.

---

## Project Structure

```
PoofOnClose/
├── src/
│   ├── main.swift       # Entire app — ~1100 lines of Swift
│   └── Info.plist       # Bundle metadata
├── build.sh             # Compile + assemble script
└── README.md
```

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributors

- **Theodore Harvey** — design, development, and maintenance
- **Weave** ([Perplexity Computer](https://perplexity.ai)) — security audit, CI/CD hardening, and collaborative development

---

## Acknowledgements

Inspired by the original macOS "poof" drag-to-trash animation that shipped from Mac OS X 10.0 through macOS Sierra (10.12).
