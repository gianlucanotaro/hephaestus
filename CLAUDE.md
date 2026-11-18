# CLAUDE.md — Hephaestus

macOS menu bar app, a FancyZones-style window manager for Mac. Splits every screen into window zones (default: left / 16:9 center / right) and snaps windows into them.

## Build & Run

No Xcode; only Command Line Tools are installed, so `xcodebuild` is unavailable. Use SwiftPM.

```bash
./build.sh                    # swift build -c release → build/Hephaestus.app (signed with "Hephaestus Dev" if present, else ad-hoc)
open build/Hephaestus.app     # LSUIElement app: menu bar icon only, no Dock icon
swift build                   # quick compile check
pkill -x Hephaestus           # stop it
```

Run `./setup-signing.sh` once to create a local "Hephaestus Dev" certificate; `build.sh` then signs with it. Without it the build is ad-hoc signed, the signature changes every rebuild, and macOS forgets the Accessibility grant (System Settings → Privacy & Security).

## Stack

- Swift 6.2 toolchain, `swift-tools-version:5.9` (Swift 5 language mode), macOS 13+
- AppKit for the app shell, status item, and overlays; SwiftUI only for the settings window (hosted in `NSHostingController`)
- Carbon `RegisterEventHotKey` for global hotkeys (no extra permissions)
- Accessibility API (`AXUIElement`) for moving/resizing other apps' windows

## Layout

`Sources/Hephaestus/`
- `main.swift` — `AppDelegate`: status item, menu, hotkey registration, settings window
- `ZoneLayout.swift` — `Zone` enum, `Prefs` (UserDefaults), and `ZoneLayout` geometry. Zones are computed for every connected screen; narrow screens fall back to a 25/50/25 split. Keep `ZoneLayout.zones(in:centerAspect:gap:)` pure so it stays testable
- `WindowMover.swift` — snaps the frontmost window to a zone via AX
- `HotKeys.swift` — Carbon hotkey wrapper (default ⌃⌥←/↑/→ snap, ⌃⌥Z preview)
- `Overlay.swift` — click-through zone outline windows
- `SettingsView.swift` — aspect ratio, gap (`@AppStorage` keys defined in `Prefs`)

## Conventions & Gotchas

- **Two coordinate spaces.** AppKit (`NSScreen`) is bottom-left origin; Accessibility is top-left origin relative to the primary screen. Zones are computed in AppKit space (overlays use them directly); convert with `ZoneLayout.toAX` only when calling AX. Mixing them up puts windows on the wrong side/height.
- Zones are computed from `screen.visibleFrame` (excludes menu bar/Dock), so the "16:9" center is 16:9 of the usable height.
- AX resize is done size → position → size because some apps clamp size based on the screen they currently sit on.
- Menu-triggered snaps are delayed 0.15s so the previously active app becomes frontmost again.
- Settings are `UserDefaults` keys in `Prefs`; add new ones there with a registered default.
- macOS sees one display, so menu bar/Dock/Spaces are shared across zones and fullscreen takes over the whole display. That is a known limitation of the zones approach.

## Roadmap

1. Drag-to-snap to zone edges
2. "Tile everything into zones" command
3. Experimental true virtual displays: private `CGVirtualDisplay` + ScreenCaptureKit mirroring. Not App Store safe, may break across macOS releases, needs Screen Recording permission. Keep it behind an experimental toggle

## Rules for Claude

- **Git workflow (overrides the workspace "never commit or push" rule for this repo):** work happens on feature branches named `feat/<issue-number>-<slug>`, one PR per GitHub issue, using `gh`. Claude may commit, push feature branches and open PRs. Claude must **never merge a PR, push to `main`, force-push, or rewrite history**; the developer merges. Every PR body links its issue with `Closes #N`.
- Commit messages and PR descriptions end with the attribution lines from the session's system reminder.
- Do not add third-party Swift packages without flagging it first.
- Run `swift build` after changes and fix all warnings before finishing.
- Prefer public APIs; flag any private API use explicitly before adding it.
