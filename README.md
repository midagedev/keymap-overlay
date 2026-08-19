# KeymapOverlay

A macOS companion app for ZMK split keyboards — a small always-on-top
keymap viewer that draws your **actual firmware keymap** and lights up
keys as you type. Built while learning a Charybdis with home-row mods;
if you are memorizing layers, this is the cheat sheet that follows you.

## What it does

- **Renders your `.keymap` directly** — the devicetree keymap file from your
  ZMK config repo is parsed (ZMKKeymap.swift); no duplicated layout data.
  Edit the firmware keymap, the overlay updates live (file watcher).
- **Live key highlight** — pressed keys glow (Accessibility permission).
- **Real layer switching** — pair layer-hold macros in your keymap with
  sentinel keys (F16/F17/F18 held while the layer is active) and the
  overlay flips layers exactly when your fingers do.
- **Usage statistics** — WPM, keystroke counts, 7-day history, most-used
  keys, finger load distribution, per-layer time (⌘⌃S or 📊).
- **Heatmap** — 🔥 tints keys by all-time usage.
- **Connection status** — USB/BT transport and battery (reads
  `system_profiler`; the split central's battery is what macOS exposes).
- Dark/light mode aware, draggable, position persisted, ⌘⌃K toggles.

## Build & run

```bash
./build.sh
open build/KeymapOverlay.app
```

Grant **Accessibility** (System Settings → Privacy & Security) once;
`build.sh` signs with your Apple Development certificate so rebuilds do
not re-trigger permission prompts.

## Pointing it at your keymap

The app looks for a keymap at:

1. the `keymapPath` user default (`defaults write com.midagedev.KeymapOverlay
   keymapPath /path/to/your.keymap`)
2. `../zmk-config-charybdis/config/charybdis.keymap` next to the repo

## Layer sentinels (for live layer display)

A layer hold sends nothing to the host by default. To make the current
layer visible, define macros that hold an inert key while the layer is
active and bind them through hold-taps (see the reference keymap in
[zmk-config-charybdis](https://github.com/midagedev/zmk-config-charybdis)):

```dts
l1_signal: l1_signal {
    compatible = "zmk,behavior-macro";
    #binding-cells = <0>;
    bindings
        = <&macro_press &mo 1 &kp F16>
        , <&macro_pause_for_release>
        , <&macro_release &mo 1 &kp F16>
        ;
};
```

macOS virtual keycodes: F16 = 106, F17 = 64, F18 = 79. (Do not use
F13/F14 — macOS maps F14 to brightness-down.)

## Layout presets

Physical drawing (grid + thumb cluster) lives in `presets/*.json`.
`charybdis-4x6` ships built in; adding another board is a new JSON file.

## Limitations

- Parser covers the common ZMK keymap subset (`&kp`, `&mo`, `&lt`, `&mt`,
  home-row mod hold-taps, macros, `&bt`, `&mkp`, `&trans`), not full
  devicetree.
- Stats count all keyboards, not just the overlay's target device
  (session-wide typing stats).
- Only macOS 12+.

## Roadmap

- [ ] QMK keymap.json import (parser interface is isolated in ZMKKeymap.swift)
- [ ] Layout editor GUI + community preset gallery
- [ ] Typing accuracy heuristics, HRM misfire insights
- [ ] Menu bar app + onboarding flow

## License

MIT
