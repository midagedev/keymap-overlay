<div align="center">

# Vein

**A macOS overlay that reads your ZMK `.keymap` and lights up as you type.**

A 3-tone miner lives in the split. Letters lodge in the dirt. Quiet enough for an office.

[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

![Vein digging](assets/vein.gif)

*The overlay parses `charybdis.keymap` from the firmware repo — four layers, drawn as bound. Type, and the miner digs; letters stay in the walls.*

## Why

Learning a split board with layers and home-row mods means constantly
wondering *what was on layer 2 under J* — and breaking flow to check a
static image. Vein sits in the corner, shows **the keymap your firmware
actually runs**, flips layers when your fingers do, and keeps a quiet
score while you practice.

## Features

### Firmware keymap, not a copy

The app parses the ZMK `.keymap` devicetree itself. Save the file, the
overlay reloads. No YAML export, no duplicated layout tables.

| Base | Sym/Fn |
|---|---|
| ![Base layer](assets/layer-0.png) | ![Symbol layer](assets/layer-1.png) |

| Nav/Mouse | Snipe |
|---|---|
| ![Nav layer](assets/layer-2.png) | ![Snipe layer](assets/layer-3.png) |

Home-row hold-taps, macros, layer-taps, bluetooth keys — decoded into
labels (`A/⌥`, `🔒`, `↵/L2`).

### Live keys, real layer state

- Pressed keys highlight through an Accessibility event tap.
- Hold a layer key and the overlay follows the firmware — via small
  sentinel macros (F16 / F17 / F18). macOS never uses those keys.
- MacBook trackpad scroll does **not** open Nav. Discrete wheel ticks
  from the board’s trackball still can, and only right after a layer hold.

### The miner

A 3-tone sprite stands in the split gap, inside a Minecraft-like dirt
shaft. Digging is tied to keystrokes — not a free-running loop.

- Type on the base layer: one chip, a short bob.
- Hold a layer, *then* type: a harder strike, more dirt, letters embed
  in the walls.
- Home-row mods get their own pulse. Layer keys alone do not dig.
- After 8 seconds idle the **whole window** fades to 12% opacity.

The same miner runs in the menu bar (smaller). Left-click toggles the
overlay; right-click is the menu.

### Statistics

`⌘⌃S` — or **기록** in the menu bar — opens the stats panel:

![Stats](assets/stats.png)

- live WPM, session peak, today’s count
- sparkline of the last 60 seconds (also on the overlay)
- today by hour, last 7 days
- most-used keys, finger load, time per layer
- a quiet level / streak (keys in, not fireworks)

Stats live in `~/Library/Application Support/KeymapOverlay/`.

### Heatmap

![Heatmap](assets/heatmap.png)

Toggle from the menu bar. Keys tint by all-time use.

### Also

- Combos drawn as connected dots (from the keymap)
- Learning mode: column tint by finger
- Shift-reactive labels on the base layer (`1` → `!`)
- USB / Bluetooth status and per-half battery
- Dark / light, draggable, position remembered
- `⌘⌃K` hide / show
- Share as images:  
  `KeymapOverlay.app --export-assets ~/Desktop --demo`

## Getting started

```bash
git clone https://github.com/midagedev/vein
cd vein
./build.sh
open build/KeymapOverlay.app
```

Grant **Accessibility** once (System Settings → Privacy & Security →
Accessibility). `build.sh` signs with your local Apple Development
identity when it can, so rebuilds keep the grant.

```bash
defaults write com.midagedev.KeymapOverlay keymapPath /path/to/your.keymap
```

Defaults to a sibling `zmk-config-charybdis` checkout. Ships with a
[Charybdis 4x6](https://github.com/midagedev/zmk-config-charybdis)
reference (home-row mods, nav/mouse, snipe).

## Layer sentinels (optional)

A layer hold is invisible to the host. To show it live, bind layer keys
to macros that hold an inert key:

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
// then: &l1lt bindings = <&l1_signal>, <&kp>;
```

macOS virtual keycodes: F16 = 106, F17 = 64, F18 = 79.
**Avoid F13/F14 — F14 is brightness-down.**

## Layout presets

Physical geometry is data: `presets/charybdis-4x6.json`. Another board
is a JSON file (Corne, Sweep, Kyria…). PRs welcome.

## Limitations

- Parser covers the common ZMK subset (`&kp`, `&mo`, `&lt`, `&mt`,
  custom hold-taps, macros, `&bt`, `&mkp`, `&trans`), not full
  devicetree.
- Typing stats count every keyboard on the machine.
- macOS 12+ only.

## Roadmap

- [ ] QMK `keymap.json` import
- [ ] More board presets
- [ ] HRM misfire insights from timing
- [x] Menu bar sprite + menu
- [ ] Onboarding

## License

[MIT](LICENSE)
