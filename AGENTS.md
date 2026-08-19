# AGENTS.md

Vein (GitHub `midagedev/vein`; display name Vein; bundle id still
`com.midagedev.KeymapOverlay`) is a single-binary AppKit app (macOS 12+)
that renders a ZMK keyboard's keymap and live typing state, with a 1-bit
miner in the split gap. Companion repo: `midagedev/zmk-config-charybdis`
(the firmware config whose `.keymap` is the default data source on this
machine).

## Build / run

```bash
./build.sh                 # swiftc -O all *.swift -> build/KeymapOverlay.app (display name: Vein)
open build/KeymapOverlay.app
```

- `build.sh` signs with the local Apple Development identity when present —
  this is important: ad-hoc signing invalidates the Accessibility TCC grant
  on every rebuild.
- Asset export (README images, keymap sharing): run the binary directly with
  `--export-assets <dir>`; add `--demo` to seed realistic stats. This runs
  before `NSApplication.run()` (top-level early-exit in main.swift) — do not
  move it into `applicationDidFinishLaunching` (it hung there; see history).
- No unit tests. Verify parser changes with the harnesses preserved under
  `local/harnesses/` (gitignored): `swiftc -parse-as-library` a small `@main`
  file together with `ZMKKeymap.swift` and print parsed layers/combos against
  `../zmk-config-charybdis/config/charybdis.keymap`.

## Architecture

- `main.swift` — app shell: overlay panel (floating NSPanel, click-through
  keyboard view), stats panel, menu-bar status item, CGEventTap for
  key/mouse/scroll highlight, Carbon hotkeys (⌘⌃K overlay, ⌘⌃S stats),
  status probing via `system_profiler`, benchmark-derived features
  (auto-hide, learning mode, shift-reactive labels, combo dots).
- `Companion.swift` — 3-tone miner in the split gap, dirt tiles, letter
  veins, motes. Dig is keyed to keystrokes (not a free-running loop).
- `StatsHUD.swift` — stats panel + sparkline view (60s / hour / 7-day).
- `ZMKKeymap.swift` — pragmatic string-scanning parser for ZMK `.keymap`
  devicetree. Entry points: `parse()` (layers only) and `parseDoc()`
  (layers + combos as `KeymapDoc`). Produces 56 `KeyCell`s per layer
  (main label, sub label, macOS virtual keycode, mouse button, flags).
- `StatsEngine.swift` — usage recording (WPM, per-key, finger load, layer
  time, level/streak/combo), JSON persistence under
  `~/Library/Application Support/KeymapOverlay/`, `seedDemo()` for
  export-only realistic data (never persisted).
- `presets/*.json` — physical geometry (which flat indices are thumbs).

### Gotchas learned the hard way

- **CGEventTapCallBack is a C function pointer** — no captures. Use
  `userInfo` + globals (see `stats` global, `view.sentinels`).
- **macOS virtual keycodes ≠ HID usage IDs.** F16=106, F17=64, F18=79
  (HIToolbox Events.h). F13/F14 are brightness keys on macOS — never use
  as layer sentinels.
- **Accessibility TCC flakiness**: after rebuilds the dot may stay red
  (tap dead). Fix: System Settings → Accessibility → remove ALL
  Vein / KeymapOverlay entries, re-add once. Dev-certificate signing should make
  this a one-time thing; if it recurs check `codesign -dvv` TeamIdentifier.
- **Status flicker**: never compose the status line from a slow probe in
  the fast timer. `refreshStatusFast()` uses `cachedStatus`; only
  `probeStatusSlow()` (45s, background) touches `system_profiler`.
- **Battery parsing**: scope the device block by *indentation* (not blank
  lines / colons) and collect every `Battery Level:` entry — the split
  central proxies the peripheral battery, so there can be two.
- Parser gotchas: hold-tap `bindings` refs come wrapped in `<>` and
  comma-separated across lines (`<&l1_signal>, <&kp>`); devicetree node
  labels sit *before* the colon; `&mo` may be followed by a space before
  the layer number; combo labels need `<&`/`&`/`=` token filtering.
- `store.load()` must run after the panel exists (`rebuildUI()` is the
  reload handler and dereferences the panel).
- Saved panel position can land off-screen after monitor layout changes —
  `defaults delete com.midagedev.KeymapOverlay panelOrigin` resets it.
- `NSImage(bitmapImageRep:)` does not exist in Swift 5 on this toolchain;
  use `NSImage(cgImage: rep.cgImage!, size:)`.

## Conventions

- UI strings Korean, code/comments English.
- Keep the parser subset-focused; full devicetree is out of scope by design.
- When the firmware keymap changes, this app needs no changes — that is the
  product's core promise. Only preset geometry is app-side data.
- `local/` is gitignored machine scratch (harnesses, debug notes). Keep it
  that way; anything generally useful gets promoted into this file or tests.

## Competitors / positioning (2026-08 survey)

- srwi/keypeek (★177, Tauri): live overlay, needs a firmware module; reads
  layout from device via raw HID + ZMK Studio.
- caksoylar/keymap-drawer (★1314): static SVG diagrams, YAML-based.
- conventoangelo/OverKeys (★235, Flutter/Win): layout practice visualizer —
  source of our auto-hide / learning mode / shift-label ideas.
- Our niche: parses the firmware `.keymap` directly (no export steps, live
  file-watch), macOS-native, typing statistics included.
