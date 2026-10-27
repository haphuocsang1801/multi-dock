# MultiDock — extra docks per display (ExtraDock-like)

Status: implemented; interactive checks (hover, drag, menus, click-through) pending on real use

## Outcome
A native macOS menu-bar app that shows one or more extra docks, each pinned to a
display and edge the user chooses, so apps can be launched/switched on every
monitor without travelling to the single system Dock.

## Constraints
- Native Swift + AppKit (SwiftUI only for the settings window), macOS 13+.
- Low CPU: event-driven (NSWorkspace notifications, tracking areas), Core
  Animation layers, cached icon bitmaps, no per-frame timers. Only a slow
  (2 s, tolerant) window scan when a dock shows "apps on this display".
- Built with SwiftPM + a script that assembles and ad-hoc signs `MultiDock.app`.

## Scope (v1)
- Many docks; each: display, edge (bottom/left/right/top), icon size,
  magnification + size, auto-hide, running-dot indicators, running-app mode
  (none / apps with windows on this display / all).
- Pinned apps, folders (click = browsable menu), files.
- Drag from Finder to add; drag to reorder; drag out to remove; drag to
  another dock to move; drop files on an app icon to open with it.
- Click: launch or activate; with Accessibility permission, raise the app's
  window that is on this display.
- Context menus (keep/remove, move to other dock, hide, quit, edge, toggles).
- Hover label, launch bounce, settings window, launch at login, JSON config.

## Non-goals
- Replacing/hiding the system Dock, notification badges (private API),
  window previews, trash item.

## Acceptance
- `scripts/build-app.sh` builds without errors.
- App runs, shows a dock on the configured display(s), idles at ~0% CPU.
- Clicks in transparent areas around a dock pass through to windows below.

## Files
`multi-dock/` — `Package.swift`, `Sources/MultiDock/*.swift`,
`Resources/Info.plist`, `scripts/build-app.sh`; usage in `docs/multi-dock.md`.
