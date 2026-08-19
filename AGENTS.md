# AGENTS.md

KeymapOverlay is a single-binary AppKit app (macOS 12+) that renders a ZMK
keyboard's keymap and live typing state. Companion repo:
`midagedev/zmk-config-charybdis` (the firmware config whose `.keymap` is the
default data source on this machine).

## Build / run

```bash
./build.sh                 # swiftc -O all *.swift -> build/KeymapOverlay.app
open build/KeymapOverlay.app
```

- `build.sh` signs with the local Apple Development identity when present —
  this is important: ad-hoc signing invalidates the Accessibility TCC grant
  on every rebuild.
- No tests yet. Verify parser changes with the pattern used during
  development: compile `ZMKKeymap.swift` with a small `@main` harness
  (`swiftc -parse-as-library`) and print the parsed layers against
  `../zmk-config-charybdis/config/charybdis.keymap`.

## Architecture

- `main.swift` — app shell: overlay panel (NSPanel, floating, click-through
  keyboard area), stats panel, CGEventTap for key/mouse/scroll highlight,
  Carbon hotkeys (⌘⌃K overlay, ⌘⌃S stats), status probing via
  `system_profiler`.
- `ZMKKeymap.swift` — pragmatic string-scanning parser for ZMK `.keymap`
  devicetree. Produces `[KeymapLayer]` of 56 `KeyCell`s (main label, sub
  label, macOS virtual keycode, mouse button, dim/accent flags).
- `StatsEngine.swift` — usage recording + JSON persistence under
  `~/Library/Application Support/KeymapOverlay/stats.json`.
- `presets/*.json` — physical geometry (which flat indices are thumbs).

### Gotchas learned the hard way

- **CGEventTapCallBack is a C function pointer** — it cannot capture locals.
  Use `userInfo`/globals (see `stats` global and `view.sentinels`).
- **macOS virtual keycodes ≠ HID usage IDs.** F16=106, F17=64, F18=79
  (from HIToolbox Events.h). F13/F14 are brightness keys on macOS.
- Keymap cell ordering matches the ZMK bindings array order: 48 grid keys,
  then thumb row A (5), then thumb row B (3) — positions come from the
  preset JSON, not the firmware.
- The parser's `labelBefore` finds the identifier *before* the colon of a
  devicetree node; behavior `bindings` refs arrive wrapped in `<>` and may
  be comma-separated across lines.
- Layer-hold sentinels: layer keys must use macros that hold F16/F17/F18
  while active (see reference keymap); the app detects keycodes 106/64/79.
- `store.load()` must run *after* the panel exists — `rebuildUI()` is the
  reload handler and dereferences the panel.

## Conventions

- UI strings Korean, code/comments English.
- Keep the parser subset-focused; full devicetree is out of scope by design.
- When the firmware keymap changes, this app needs no changes — that is the
  product's core promise. Only preset geometry is app-side data.
