# Changelog

All notable changes to PoofOnClose are documented here.

## [2.1.0] — 2026-03-22

### Fixed
- **Thread safety** — all `WindowTracker` state now lives exclusively behind a private serial `stateQueue`. Timer and `NSWorkspace` notification callbacks no longer race.
- **Mutation during iteration** — `pendingPoofs` dictionary is no longer mutated during its own iteration (collect → mutate two-pass).
- **Observer cleanup** — block-based `NSWorkspace` observers now store their tokens and are removed correctly in `stop()`. The previous `removeObserver(self)` was a no-op.
- **AppKit on main thread** — `NSRunningApplication(processIdentifier:)` is now called via `DispatchQueue.main.sync` rather than from the background `stateQueue`.
- **Multi-monitor coordinates** — poof position in `.window` mode now correctly identifies the display containing the closed window instead of always using `NSScreen.main`.
- **Launch at Login** — macOS 12 fallback (`SMLoginItemSetEnabled`) removed; it was incorrectly using the main bundle ID. Feature now gated to macOS 13+ with proper `SMAppService` and error surfacing on failure.
- **Preference update ordering** — Launch at Login preference and UI state are only updated after `SMAppService` registration succeeds.
- **Misleading Accessibility prompt** — removed. PoofOnClose uses `CGWindowListCopyWindowInfo` and does not require Accessibility permission.
- **Info.plist** — removed erroneous `SMPrivilegedExecutables` and `NSAccessibilityUsageDescription` keys.
- **Sound overlap** — `AVAudioPlayer` pool replaces the single shared instance; rapid window closes now stack sounds correctly.
- **Ripple layer cleanup** — all effect layers (including the three ripple rings) are tracked and removed consistently on window close.
- **`testPoof` coordinate space** — test action now uses `NSEvent.mouseLocation` (AppKit coordinates) correctly, avoiding the CG→AppKit conversion that produced wrong results.
- **Dead code** — removed unused `_ = targetScreen.visibleFrame` line.
- **Force cast** — `cfBounds as! CFDictionary` replaced with safe `as? NSDictionary` chain.
- **`@unknown default`** — `NSBezierPath.cgPath` switch now uses `@unknown default` for forward compatibility.
- **Build script** — uses `xcrun swiftc` with explicit `-sdk` and `-target arm64-apple-macos13.0` for reproducible builds.

## [2.0.0] — 2026-03-22

### Added
- **4 visual themes** — Classic Cloud, Comic POW, Sparkle, Ripple
- **Dynamic poof size** — scales 140–320 px based on closed window area
- **Poof position modes** — At Cursor or At Window centre
- **Per-app skip/allow lists** — App Manager window with UserDefaults persistence
- **Volume control** — inline menu bar slider
- **Improved sound synthesis** — swept low-pass filtered noise ("whomp")
- **Custom sound** — bundle `poof.aiff` in `src/` to override synthesised sound
- **Launch at Login** — `SMAppService` on macOS 13+
- **`UserDefaults`-backed preferences** — all settings persist across restarts
- **`stop()` / lifecycle** — timer cancellation and observer removal

## [1.0.0] — Initial release

- Classic cartoon cloud burst animation on window close
- Synthesised poof sound
- Grace period and Space/app-switch cooldowns to suppress false positives
- Built-in skip list for system and utility apps
- Menu bar icon with Test Poof and Quit
