<div align="center">

# KeymapOverlay

**A macOS companion for ZMK keyboards that renders your actual firmware keymap — and lights up as you type.**

[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

![Layer cycling](assets/layers.gif)

*The overlay reads `charybdis.keymap` straight from the firmware repo — four layers, drawn exactly as bound. No layout data is duplicated in the app.*

## Why

Learning a split keyboard with layers and home-row mods means constantly
wondering *"what was on layer 2 under J again?"* — and breaking flow to
check a static image. KeymapOverlay sits in the corner of your screen
showing **the keymap your firmware actually runs**, flips layers when your
fingers do, and keeps score while you practice.

## Features

### Renders your firmware keymap directly

The app parses the ZMK `.keymap` devicetree file itself (custom parser,
no duplicated layout tables). When you edit and save the keymap, the
overlay updates on the spot.

| Base | Sym/Fn |
|---|---|
| ![Base layer](assets/layer-0.png) | ![Symbol layer](assets/layer-1.png) |

| Nav/Mouse | Snipe |
|---|---|
| ![Nav layer](assets/layer-2.png) | ![Snipe layer](assets/layer-3.png) |

*Home-row mod hold-taps, macros, layer-taps, bluetooth keys — all decoded
into readable labels (`A/⌥`, `🔒`, `↵/L2`).*

### Live keys, real layer state

- Pressed keys glow in real time (Accessibility-powered event tap).
- Hold a layer key and the overlay switches layers **as the firmware sees
  it** — via small sentinel macros you bind in the keymap (F16/F17/F18
  held while the layer is active; macOS never uses these keys).

### Typing statistics

`⌘⌃S` opens the stats panel:

![Stats panel](assets/stats.png)

- ⚡ live WPM and today's keystroke count
- 📅 7-day typing history
- 🏆 most-used keys ranking
- ✋ finger load distribution — spot an unbalanced layout before your
  hands do
- ⏱️ time spent per layer

Stats persist in `~/Library/Application Support/KeymapOverlay/`.

### Heatmap

Toggle 🔥 and keys tint by all-time usage — see which keys earn their
spot on your layout:

![Heatmap](assets/heatmap.png)

### Everything else

- USB/Bluetooth connection status, with per-half battery
  (`L 87% · R 74%` — reads every battery entry macOS exposes for the
  device, including the split peripheral's proxied battery)
- Dark/light mode aware, draggable, position remembered
- `⌘⌃K` to hide/show
- Share your keymap as an image:
  `KeymapOverlay.app --export-assets ~/Desktop` writes one PNG per layer
  plus an animated GIF. Add `--demo` to bake in realistic stats — the
  images on this page were generated that way. No screen-recording
  permission needed (views are rendered offscreen).

## Getting started

```bash
git clone https://github.com/midagedev/keymap-overlay
cd keymap-overlay
./build.sh
open build/KeymapOverlay.app
```

Grant **Accessibility** once (System Settings → Privacy & Security →
Accessibility). `build.sh` signs with your local Apple Development
identity when available, so rebuilds keep the permission.

Point it at your keymap:

```bash
defaults write com.midagedev.KeymapOverlay keymapPath /path/to/your.keymap
```

(Defaults to a sibling `zmk-config-charybdis` checkout; ships with a
[Charybdis 4x6 reference keymap](https://github.com/midagedev/zmk-config-charybdis)
featuring home-row mods, a nav/mouse layer, and a snipe layer.)

## Layer sentinels (optional, for live layer display)

A layer hold is invisible to the host by default. To make it visible, bind
layer keys to macros that hold an inert key while active:

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
// then: &l1lt bindings = <&l1_signal>, <&kp>;  (tap = space, hold = layer 1)
```

macOS virtual keycodes: F16 = 106, F17 = 64, F18 = 79.
**Avoid F13/F14 — macOS maps F14 to brightness-down.**

## Layout presets

Physical geometry (grid + thumb cluster) is data, not code:
`presets/charybdis-4x6.json`. Adding another board is a JSON file away —
PRs welcome (Corne, Sweep, Kyria…).

## Limitations

- Parser targets the common ZMK keymap subset (`&kp`, `&mo`, `&lt`, `&mt`,
  custom hold-taps, macros, `&bt`, `&mkp`, `&trans`), not full devicetree.
- Typing stats count every keyboard on the machine (host-wide).
- macOS 12+ only.

## Roadmap

- [ ] QMK `keymap.json` import (parser is isolated in `ZMKKeymap.swift`)
- [ ] GUI layout editor + community preset gallery
- [ ] HRM misfire insights from timing data
- [ ] Menu bar app and onboarding flow

## License

[MIT](LICENSE)
