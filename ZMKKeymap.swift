import Foundation

// Parses a ZMK `.keymap` (devicetree) file into layer grids the overlay renders.
// Pragmatic string-scanning parser for the common ZMK keymap subset
// (kp / hold-taps / macros / bt / mkp / trans), not full devicetree.

struct KeyCell {
    var main: String = "·"
    var sub: String?
    var code: Int?
    var mb: Int?
    var dim: Bool = true
    var accent: Bool = false
    var needsCtrl: Bool = false
}

struct KeymapLayer {
    let name: String
    let displayName: String
    var cells: [KeyCell]
}

struct Binding {
    var ref: String
    var params: [String]
    var cells: Int
}

final class ZMKKeymapParser {
    private var behaviorCells: [String: Int] = [:]
    private var behaviorHoldRef: [String: String] = [:]
    private var macroLayer: [String: Int] = [:]
    private var macroSymbols: [String: String] = [
        "lock_screen": "🔒",
        "shot_clip": "📸",
        "l1_signal": "L1",
        "l2_signal": "L2",
        "snipe_signal": "SNIPE",
    ]

    private static let knownCells = [
        "kp": 1, "mkp": 1, "mo": 1, "lt": 2, "mt": 2, "to": 1, "tog": 1,
        "bt": 1, "trans": 0, "none": 0, "bootloader": 0, "sys_reset": 0,
        "studio_unlock": 0, "caps_word": 0, "bl": 1, "out": 1, "ext_power": 1,
        "key_repeat": 0,
    ]

    func parse(_ text: String) -> [KeymapLayer] {
        let src = stripComments(text)
        parseBehaviors(src)
        parseMacros(src)
        return parseLayers(src)
    }

    // MARK: - Extraction helpers

    private func labelBefore(_ src: String, _ index: String.Index) -> String? {
        let windowStart = src.index(index, offsetBy: -200, limitedBy: src.startIndex) ?? src.startIndex
        let window = String(src[windowStart..<index])
        guard let colon = window.lastIndex(of: ":") else { return nil }
        let before = window[..<colon]
        let word = before.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).last
            .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))) }
        guard let word, !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return word
    }

    private func valueAfter(_ src: String, _ key: String, from: String.Index, span: Int = 300) -> String? {
        let end = src.index(from, offsetBy: span, limitedBy: src.endIndex) ?? src.endIndex
        let region = String(src[from..<end])
        guard let r = region.range(of: key) else { return nil }
        let rest = region[r.upperBound...].drop { $0 == " " || $0 == "=" }
        let val = rest.prefix { $0 != ";" && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return val.isEmpty ? nil : String(val)
    }

    private func parseBehaviors(_ src: String) {
        var searchStart = src.startIndex
        while let r = src.range(of: "zmk,behavior-hold-tap", range: searchStart..<src.endIndex) {
            let label = labelBefore(src, r.lowerBound) ?? ""
            if let cellsStr = valueAfter(src, "binding-cells", from: r.upperBound),
               let cells = Int(cellsStr.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))) {
                behaviorCells[label] = cells
                if let b = valueAfter(src, "bindings", from: r.upperBound) {
                    let refs = b.split(separator: ",")
                        .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
                        .map(String.init)
                        .filter { $0.hasPrefix("<&") }
                    if let first = refs.first {
                        behaviorHoldRef[label] = first.trimmingCharacters(in: CharacterSet(charactersIn: "<>&"))
                    }
                }
            }
            searchStart = r.upperBound
        }
    }

    private func parseMacros(_ src: String) {
        var searchStart = src.startIndex
        while let r = src.range(of: "zmk,behavior-macro", range: searchStart..<src.endIndex) {
            let label = labelBefore(src, r.lowerBound) ?? ""
            let end = src.index(r.upperBound, offsetBy: 600, limitedBy: src.endIndex) ?? src.endIndex
            let region = String(src[r.upperBound..<end])
            if let bRange = region.range(of: "bindings") {
                let body = String(region[bRange.upperBound...].prefix { $0 != ";" })
                if let moRange = body.range(of: "&mo") {
                    let num = body[moRange.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
                    if let layer = Int(num) { macroLayer[label] = layer }
                }
            }
            searchStart = r.upperBound
        }
    }

    private func parseLayers(_ src: String) -> [KeymapLayer] {
        var layers: [KeymapLayer] = []
        let keymapStart = src.range(of: "zmk,keymap")?.upperBound ?? src.startIndex
        var searchStart = keymapStart
        while let r = src.range(of: "bindings", range: searchStart..<src.endIndex) {
            guard let open = src[r.upperBound...].firstIndex(of: "<"),
                  let close = src[open...].firstIndex(of: ">") else { break }
            let body = String(src[src.index(after: open)..<close])
            let bindings = tokenize(body)
            guard !bindings.isEmpty else {
                searchStart = close
                continue
            }
            var cells = bindings.map { cell(for: $0) }
            if layers.isEmpty {
                for i in cells.indices { cells[i].dim = false }
            }
            let nodeStart = src.index(r.lowerBound, offsetBy: -300, limitedBy: src.startIndex) ?? src.startIndex
            let header = String(src[nodeStart..<r.lowerBound])
            let displayName = header.range(of: "display-name")
                .map { h in
                    let rest = header[h.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" }
                    return String(rest.prefix { $0 != "\"" })
                }
            let name = labelBefore(src, r.lowerBound) ?? "layer\(layers.count)"
            layers.append(KeymapLayer(name: name,
                                      displayName: displayName ?? name,
                                      cells: cells))
            searchStart = close
        }
        if let base = layers.first {
            for li in layers.indices {
                guard li > 0 else { continue }
                for i in layers[li].cells.indices where i < base.cells.count {
                    let c = layers[li].cells[i]
                    let b = base.cells[i]
                    layers[li].cells[i].accent = (c.main != b.main || c.sub != b.sub) && !c.dim
                }
            }
        }
        return layers
    }

    // MARK: - Binding → cell

    private func tokenize(_ s: String) -> [Binding] {
        var out: [Binding] = []
        var pending: Binding?
        for tok in s.split(whereSeparator: { $0.isWhitespace }) {
            if tok.hasPrefix("&") {
                if let p = pending { out.append(p) }
                let ref = String(tok.dropFirst())
                let cells = Self.knownCells[ref] ?? behaviorCells[ref] ?? (macroLayer[ref] != nil ? 0 : 0)
                pending = Binding(ref: ref, params: [], cells: cells)
            } else if pending != nil {
                pending?.params.append(String(tok))
                if let p = pending, p.params.count >= p.cells {
                    out.append(p)
                    pending = nil
                }
            }
        }
        if let p = pending { out.append(p) }
        return out
    }

    private func cell(for b: Binding) -> KeyCell {
        switch b.ref {
        case "kp":
            var c = KeyCell()
            decorate(&c, key: b.params.first ?? "?")
            return c
        case "trans", "none":
            return KeyCell()
        case "mo":
            return KeyCell(main: "L\(b.params.first ?? "?")", dim: false, accent: true)
        case "lt":
            return KeyCell(main: keyLabel(b.params.last ?? ""), sub: "L\(b.params.first ?? "")",
                           code: keyCode(b.params.last ?? ""), dim: false)
        case "mt":
            return KeyCell(main: keyLabel(b.params.last ?? ""), sub: modSymbol(b.params.first ?? ""),
                           code: keyCode(b.params.last ?? ""), dim: false)
        case "bt":
            return btCell(b.params.first ?? "")
        case "mkp":
            return mkpCell(b.params.first ?? "")
        case "bootloader":
            return KeyCell(main: "FLASH", dim: false, accent: true)
        case "sys_reset":
            return KeyCell(main: "RESET", dim: false, accent: true)
        case "to", "tog":
            return KeyCell(main: "L\(b.params.first ?? "")", dim: false, accent: true)
        default:
            return customCell(b)
        }
    }

    private func customCell(_ b: Binding) -> KeyCell {
        if let layer = macroLayer[b.ref] {
            let sym = macroSymbols[b.ref] ?? b.ref.uppercased()
            return KeyCell(main: sym, sub: "L\(layer)", dim: false, accent: true)
        }
        if behaviorCells[b.ref] != nil {
            let holdRef = behaviorHoldRef[b.ref] ?? ""
            var sub: String?
            if let layer = macroLayer[holdRef] {
                sub = "L\(layer)"
            } else if holdRef == "mo" {
                sub = "L\(b.params.first ?? "?")"
            } else if holdRef == "kp" {
                sub = modSymbol(b.params.first ?? "")
            }
            let tap = b.params.last ?? ""
            return KeyCell(main: keyLabel(tap), sub: sub,
                           code: keyCode(tap), dim: false)
        }
        if let sym = macroSymbols[b.ref] {
            return KeyCell(main: sym, dim: false, accent: true)
        }
        return KeyCell(main: String(b.ref.prefix(6).uppercased()), dim: false, accent: true)
    }

    private func btCell(_ cmd: String) -> KeyCell {
        switch cmd {
        case "BT_CLR": return KeyCell(main: "BT", sub: "CLR", dim: false, accent: true)
        case "BT_PRV": return KeyCell(main: "◀", sub: "BT", dim: false, accent: true)
        case "BT_NXT": return KeyCell(main: "▶", sub: "BT", dim: false, accent: true)
        default: return KeyCell(main: "BT", sub: cmd, dim: false, accent: true)
        }
    }

    private func mkpCell(_ btn: String) -> KeyCell {
        switch btn {
        case "MB1": return KeyCell(main: "🖱L", mb: 0, dim: false, accent: true)
        case "MB2": return KeyCell(main: "🖱R", mb: 1, dim: false, accent: true)
        case "MB3": return KeyCell(main: "🖱M", mb: 2, dim: false, accent: true)
        default: return KeyCell(main: "🖱", dim: false, accent: true)
        }
    }

    /// Handles modifier wrappers like LC(LG(Q)) and plain key names.
    private func decorate(_ c: inout KeyCell, key raw: String) {
        var key = raw
        var mods = ""
        var needsCtrl = false
        let wrappers = ["LC(", "LG(", "LS(", "LA(", "RC(", "RG(", "RS(", "RA("]
        var wrapped = true
        while wrapped {
            wrapped = false
            for w in wrappers where key.hasPrefix(w) && key.hasSuffix(")") {
                let inner = String(key.dropFirst(w.count).dropLast())
                if inner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "(" || $0 == ")" }) {
                    switch w {
                    case "LC(", "RC(": mods += "⌃"; needsCtrl = true
                    case "LG(", "RG(": mods += "⌘"
                    case "LS(", "RS(": mods += "⇧"
                    default: mods += "⌥"
                    }
                    key = inner
                    wrapped = true
                }
            }
        }
        c.main = keyLabel(key)
        c.code = keyCode(key)
        c.sub = mods.isEmpty ? nil : mods
        c.dim = false
        c.needsCtrl = needsCtrl
    }

    // MARK: - Tables

    private static let keyTable: [String: (String, Int?)] = [
        "A": ("A", 0), "B": ("B", 11), "C": ("C", 8), "D": ("D", 2), "E": ("E", 14),
        "F": ("F", 3), "G": ("G", 5), "H": ("H", 4), "I": ("I", 34), "J": ("J", 38),
        "K": ("K", 40), "L": ("L", 37), "M": ("M", 46), "N": ("N", 45), "O": ("O", 31),
        "P": ("P", 35), "Q": ("Q", 12), "R": ("R", 15), "S": ("S", 1), "T": ("T", 17),
        "U": ("U", 32), "V": ("V", 9), "W": ("W", 13), "X": ("X", 7), "Y": ("Y", 16),
        "Z": ("Z", 6), "NUMBER_4": ("4", 21),
        "N1": ("1", 18), "N2": ("2", 19), "N3": ("3", 20), "N4": ("4", 21), "N5": ("5", 23),
        "N6": ("6", 22), "N7": ("7", 26), "N8": ("8", 28), "N9": ("9", 25), "N0": ("0", 29),
        "ESC": ("ESC", 53), "TAB": ("TAB", 48), "CAPSLOCK": ("CAPS", 57), "SPACE": ("SPC", 49),
        "BSPC": ("⌫", 51), "ENTER": ("↵", 36), "BACKSLASH": ("\\", 42), "SEMI": (";", 41),
        "APOS": ("'", 39), "COMMA": (",", 43), "DOT": (".", 47), "SLASH": ("/", 44),
        "EQUAL": ("=", 24), "MINUS": ("-", 27), "GRAVE": ("`", 50),
        "LEFT_BRACKET": ("[", 33), "RIGHT_BRACKET": ("]", 30),
        "LEFT_PAREN": ("(", 33), "RIGHT_PAREN": (")", 30),
        "LPAR": ("(", 33), "RPAR": (")", 30),
        "LEFT_BRACE": ("{", 33), "RIGHT_BRACE": ("}", 30),
        "LSHIFT": ("⇧", 56), "LCTRL": ("⌃", 59), "LALT": ("⌥", 58), "LGUI": ("⌘", 55),
        "RSHIFT": ("⇧", 60), "RCTRL": ("⌃", 62), "RALT": ("⌥", 61), "RGUI": ("⌘", 54),
        "LEFT_ARROW": ("←", 123), "RIGHT_ARROW": ("→", 124), "UP_ARROW": ("↑", 126),
        "DOWN_ARROW": ("↓", 125), "DEL": ("DEL", 117), "DELETE": ("DEL", 117),
        "HOME": ("HOME", 115), "END": ("END", 119), "PG_UP": ("PG↑", 116), "PG_DN": ("PG↓", 121),
        "K_MUTE": ("🔇", 74), "K_VOLUME_UP": ("🔊", 72), "K_VOLUME_DOWN": ("🔉", 73),
        "C_BRI_DN": ("▾", 107), "C_BRI_UP": ("▴", 113),
        "C_BRI_MIN": ("◐", nil), "C_BRI_MAX": ("◑", nil),
        "C_PLAY_PAUSE": ("⏯", nil), "C_PREV": ("⏮", nil), "C_NEXT": ("⏭", nil),
    ]

    private func keyLabel(_ name: String) -> String {
        Self.keyTable[name]?.0 ?? String(name.prefix(4))
    }

    static func labelForCode(_ code: Int) -> String {
        struct Reverse {
            static let table: [Int: String] = {
                var t: [Int: String] = [:]
                for (name, v) in ZMKKeymapParser.keyTable {
                    if let c = v.1, t[c] == nil { t[c] = v.0 }
                }
                t[49] = "SPACE"
                return t
            }()
        }
        return Reverse.table[code] ?? "code \(code)"
    }

    private func keyCode(_ name: String) -> Int? {
        Self.keyTable[name]?.1
    }

    private func modSymbol(_ name: String) -> String {
        switch name {
        case "LALT", "RALT": return "⌥"
        case "LCTRL", "RCTRL": return "⌃"
        case "LSHIFT", "RSHIFT": return "⇧"
        case "LGUI", "RGUI": return "⌘"
        default: return String(name.prefix(3))
        }
    }

    private func stripComments(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("/*") {
                if let end = s.range(of: "*/", range: i..<s.endIndex) {
                    i = end.upperBound
                    continue
                }
            }
            if s[i...].hasPrefix("//") {
                if let end = s.range(of: "\n", range: i..<s.endIndex) {
                    i = end.upperBound
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}


