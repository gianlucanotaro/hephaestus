<p align="center">
  <img src="assets/logo.svg" width="160" alt="Hephaestus logo">
</p>

<h1 align="center">Hephaestus</h1>

<p align="center">
  A FancyZones-style window manager for macOS.<br>
  Splits every screen into zones and snaps windows into them.
</p>

Hephaestus lives in your menu bar. By default each screen is divided into three zones: **left**, a **16:9 center**, and **right**. Drag a window to a zone, or use a hotkey, and it snaps into place. It's built for ultrawide monitors, where a maximized window is far too big.

> **Status:** early and in active development. See the [open issues](../../issues) for the roadmap toward FancyZones parity.

## Features

- Zones on **every connected screen**; narrow screens fall back to a 25/50/25 split
- **Drag to snap** with a live overlay: Hold Shift, click another mouse button to toggle, or always show zones while dragging
- **Multi-zone snapping**: drop near the edge between two zones, hold a modifier (Control by default), or middle-click to span several zones
- Overlay options: show zones on all screens or only the one under the cursor, system or custom colors (follows light/dark mode), opacity, zone numbers
- **Global hotkeys** (no extra permissions beyond Accessibility)
- Configurable center aspect ratio and gap between zones

## Requirements

- macOS 13 or later
- Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

## Build and run

```bash
git clone https://github.com/gianlucanotaro/hephaestus.git
cd hephaestus
./setup-signing.sh      # once: creates a local "Hephaestus Dev" signing certificate
./build.sh              # builds build/Hephaestus.app
open build/Hephaestus.app
```

Hephaestus is a menu bar app (no Dock icon). Quit it from its menu, or with `pkill -x Hephaestus`.

### Accessibility permission

Moving other apps' windows needs the Accessibility permission. On first launch, grant it in **System Settings → Privacy & Security → Accessibility**.

Run `./setup-signing.sh` once before your first build. Without it the app is ad-hoc signed, the signature changes on every rebuild, and macOS forgets the permission each time. The script creates a self-signed certificate in your login keychain and asks for your login password to trust it.

## Usage

| Action | Default |
| --- | --- |
| Snap the frontmost window to the left / center / right zone | ⌃⌥← / ⌃⌥↑ / ⌃⌥→ |
| Preview the zones | ⌃⌥Z |
| Snap by dragging | Hold Shift while dragging a window (configurable) |
| Span several zones | Drop near the edge between two zones, hold ⌃ while dragging, or middle-click |

The menu bar menu also offers per-zone snap commands, **Show Zones**, and **Settings…**.

## Settings

Open **Settings…** from the menu bar icon.

- Center aspect ratio and gap
- Drag activation mode and the multi-zone modifier (Control, Option, or Command)
- Show zones on all screens while dragging
- Overlay colors (system or custom), opacity, and zone numbers

## How it works

- **AppKit** for the menu bar item and click-through overlay windows; **SwiftUI** only for the settings window
- **Carbon `RegisterEventHotKey`** for global hotkeys
- **Accessibility API (`AXUIElement`)** to move and resize other apps' windows
- A global mouse monitor detects window drags (window moved, not resized)

Only public APIs are used.

## Known limitations

macOS sees one display per physical screen, so the menu bar, Dock, and Spaces are shared across zones, and a fullscreen window takes over the whole display. That's inherent to the zones approach.

## Development

```bash
swift build        # quick compile check
./build.sh         # release build into build/Hephaestus.app
./assets/make-icns.sh   # regenerate the app icon from assets/logo.svg (needs librsvg)
```

Sources are in `Sources/Hephaestus/`. See `CLAUDE.md` for conventions and gotchas.
