# MultiDock — visual and settings parity with the macOS Dock

Status: implemented; snapshot matches the system Dock, hands-on checks pending

## Outcome
MultiDock looks and behaves like the system Dock (target ≥95% visual parity)
and exposes the system Dock's settings that make sense for an extra dock.

## Reference (measured from the user's system Dock, tilesize 97)
- Tiles touch (no spacing); app squircle ≈ 78% of the tile.
- Plate padding ≈ 8 pt; plate ≈ tile + 16; corner radius ≈ 27% of height;
  ≈ 5 pt gap to the screen edge.
- Separator slot ≈ half a tile, line ≈ 86% of tile height.
- Running dot ≈ 4 pt, grey, centred in the bottom padding.
- Sections: pinned apps | running + recent apps | folders/files + Trash.

## Scope
- Restyle geometry, separators, dots, label, press-darkening, launch bounce
  until launched, hidden-app dimming.
- Trash tile (open, drop to move to Trash, empty with confirmation).
- Recent apps section (3, like macOS).
- Folder stacks shown as a grid panel or list, with sort options.
- Drag the separator to resize; lock contents; auto-hide delay and speed.
- Import apps/size/magnification from the system Dock.
- macOS-style context menus (window list with Accessibility, Options,
  Force Quit with ⌥).

## Non-goals
Window-minimise settings (genie/scale, minimise into app icon, double-click
title bar): they act on windows, which only the system Dock owns.

## Acceptance
Builds clean; idle CPU stays ~0%; snapshot layout matches the reference ratios.
