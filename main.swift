import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// Vein: a macOS companion overlay for ZMK keyboards.
// Renders the physical layout and live key/layer state from the firmware's
// own `.keymap` file (see ZMKKeymap.swift), records usage statistics
// (StatsEngine.swift), and runs a 1-bit miner in the split while you type.

let U: CGFloat = 30
let S: CGFloat = 27
let R: CGFloat = 5
let GAP: CGFloat = 3 * U

func xFor(_ c: Int) -> CGFloat { CGFloat(c) * U + 2 + (c >= 6 ? GAP : 0) }
func tx4(_ i: Int) -> CGFloat { xFor(5) + CGFloat(i) * U }
func tx5(_ i: Int) -> CGFloat { tx4(i) + U / 2 }

let stats = StatsEngine.shared

struct LayoutPreset {
    let id: String
    let name: String
    let thumbA: [Int]
    let thumbB: [Int]
    let thumbBPos: [Int]

    static func load() -> LayoutPreset {
        let fallback = LayoutPreset(id: "charybdis-4x6", name: "Charybdis 4x6",
                                    thumbA: [48, 49, 50, 51, 52], thumbB: [53, 54, 55],
                                    thumbBPos: [0, 1, 3])
        guard let url = Bundle.main.url(forResource: "charybdis-4x6", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let name = json["name"] as? String,
              let a = json["thumbRowA"] as? [Int],
              let b = json["thumbRowB"] as? [Int],
              let bp = json["thumbRowBPositions"] as? [Int] else { return fallback }
        return LayoutPreset(id: id, name: name, thumbA: a, thumbB: b, thumbBPos: bp)
    }
}

struct Palette {
    let keyFill: NSColor
    let keyFillDim: NSColor
    let text: NSColor
    let textSub: NSColor
    let accent: NSColor
    let held: NSColor
    let heldText: NSColor
    let bevel: NSColor

    static func current() -> Palette {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            return Palette(keyFill: NSColor(white: 0.18, alpha: 1),
                           keyFillDim: NSColor(white: 0.10, alpha: 1),
                           text: .white,
                           textSub: NSColor.white.withAlphaComponent(0.55),
                           accent: NSColor(white: 0.78, alpha: 1),
                           held: NSColor(white: 0.82, alpha: 0.95),
                           heldText: .black,
                           bevel: NSColor.white.withAlphaComponent(0.08))
        }
        return Palette(keyFill: NSColor(white: 1.0, alpha: 1),
                       keyFillDim: NSColor(white: 0.87, alpha: 1),
                       text: .black,
                       textSub: NSColor.black.withAlphaComponent(0.55),
                       accent: NSColor(white: 0.25, alpha: 1),
                       held: NSColor(white: 0.78, alpha: 1),
                       heldText: .black,
                       bevel: NSColor.white.withAlphaComponent(0.40))
    }
}

final class KeymapStore {
    private(set) var layers: [KeymapLayer] = []
    private(set) var combos: [ComboSpec] = []
    private(set) var keymapURL: URL?
    private(set) var lastError: String?
    var preset = LayoutPreset.load()
    var onReload: (() -> Void)?

    // Sentinel keycodes reported by layer-hold macros in the keymap
    // (F16/F17/F18 by default in the reference keymap).
    var sentinels: [Int: Int] = [106: 1, 64: 2, 79: 3]

    func defaultKeymapPath() -> URL? {
        if let p = UserDefaults.standard.string(forKey: "keymapPath") {
            return URL(fileURLWithPath: p)
        }
        // Candidate locations, most preferred first. #filePath only works
        // for source-tree builds; the app bundle sits two levels under the
        // repo when built with ./build.sh, so also probe relative to the
        // executable and the user's common config locations.
        var candidates: [URL] = []
        let sourceSibling = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("zmk-config-charybdis/config/charybdis.keymap")
        candidates.append(sourceSibling)
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("zmk-config-charybdis/config/charybdis.keymap"))
        }
        candidates.append(URL(fileURLWithPath: NSString(string: "~/repo-mid/zmk-config-charybdis/config/charybdis.keymap").expandingTildeInPath))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func load(from url: URL? = nil) {
        let target = url ?? defaultKeymapPath()
        keymapURL = target
        lastError = nil
        guard let target, let text = try? String(contentsOf: target, encoding: .utf8) else {
            lastError = "키맵 파일을 읽을 수 없음"
            layers = []
            onReload?()
            return
        }
        let doc = ZMKKeymapParser().parseDoc(text)
        layers = doc.layers
        combos = doc.combos
        watch(target)
        onReload?()
    }

    private var watchSource: DispatchSourceFileSystemObject?
    private func watch(_ url: URL) {
        watchSource?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.load(from: url) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchSource = src
    }
}

final class KeyboardView: NSView {
    var store: KeymapStore!
    var heatmap = false
    var learningMode = false
    var combos: [ComboSpec] = []
    var layerIndex = 0 {
        didSet {
            needsDisplay = true
            if layerIndex != oldValue {
                NotificationCenter.default.post(name: Notification.Name("overlayLayerChanged"), object: nil)
            }
        }
    }
    var heldCodes: Set<Int> = []
    var heldCtrl = false
    var heldMouse: Set<Int> = []
    /// Export / demo: light keys by the label they show, not by raw keycode.
    /// Nav/Sym mains (`←`, `{`) do not share codes with the QWERTY tap.
    var heldMains: Set<String> = []
    var autoSwitch = true
    var lastFn = 1
    var layerHold = 0
    var lastFlags: CGEventFlags = []
    /// Last time a layer sentinel went down. Discrete (trackball) scroll
    /// may keep Nav up briefly; trackpad pixel-scroll never should.
    var lastLayerEngage = Date.distantPast

    /// Auto-hide: seconds since last key activity; the panel fades out
    /// after the threshold (mirrors OverKeys' behavior).
    var autoHideSeconds = 8
    var lastActivity = Date()
    var autoHideEnabled = true

    func noteActivity() {
        lastActivity = Date()
        guard let panel, panel.alphaValue < 0.99 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        })
    }

    func fadeOutIfIdle() {
        guard autoHideEnabled, let panel, panel.isVisible else { return }
        if Date().timeIntervalSince(lastActivity) > Double(autoHideSeconds), panel.alphaValue > 0.99 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6
                panel.animator().alphaValue = 0.12
            })
        }
    }

    weak var panel: NSPanel?
    var sentinels: [Int: Int] = [:]

    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    var contentHeight: CGFloat { 6 * U + 4 }
    var contentWidth: CGFloat { 12 * U + GAP + 4 }

    private func cells() -> [(NSRect, KeyCell)] {
        guard store.layers.indices.contains(layerIndex) else { return [] }
        let layer = store.layers[layerIndex]
        let preset = store.preset
        var out: [(NSRect, KeyCell)] = []
        let yoff: CGFloat = 2
        for ri in 0..<4 {
            for ci in 0..<12 {
                let idx = ri * 12 + ci
                guard idx < layer.cells.count else { continue }
                let r = NSRect(x: xFor(ci), y: CGFloat(5 - ri) * U + yoff, width: S, height: S)
                out.append((r, layer.cells[idx]))
            }
        }
        for (slot, idx) in preset.thumbA.enumerated() {
            guard idx < layer.cells.count else { continue }
            let r = NSRect(x: tx4(slot), y: U + yoff, width: S, height: S)
            out.append((r, layer.cells[idx]))
        }
        for (slot, idx) in preset.thumbB.enumerated() {
            guard idx < layer.cells.count, slot < preset.thumbBPos.count else { continue }
            let r = NSRect(x: tx5(preset.thumbBPos[slot]), y: yoff + 4, width: S, height: S)
            out.append((r, layer.cells[idx]))
        }
        return out
    }

    private func isHeld(_ kd: KeyCell) -> Bool {
        if heldMains.contains(kd.main) { return true }
        if let b = kd.mb { return heldMouse.contains(b) }
        guard let code = kd.code else { return false }
        return heldCodes.contains(code) && (!kd.needsCtrl || heldCtrl)
    }

    /// Shift-reactive labels: pressing Shift swaps in the shifted symbol
    /// (1 → !, ; → :) so the overlay reads like the keycaps do.
    private static let shiftTable: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "`": "~", "-": "_", "=": "+", "[": "{", "]": "}",
        "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]

    private func displayLabel(_ kd: KeyCell) -> String {
        guard heldShift, layerIndex == 0, let shifted = Self.shiftTable[kd.main] else { return kd.main }
        return shifted
    }

    /// Learning mode: tints keys by the finger that should press them,
    /// following the standard ergonomic finger assignment.
    private static let fingerColors: [(range: Range<Int>, color: NSColor, name: String)] = [
        (0..<1, NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.45, alpha: 0.45), "새끼"),
        (1..<2, NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.40, alpha: 0.45), "약지"),
        (2..<3, NSColor(calibratedRed: 0.92, green: 0.92, blue: 0.45, alpha: 0.45), "중지"),
        (3..<6, NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.50, alpha: 0.45), "검지"),
        (6..<9, NSColor(calibratedRed: 0.50, green: 0.80, blue: 0.90, alpha: 0.45), "검지"),
        (9..<10, NSColor(calibratedRed: 0.70, green: 0.55, blue: 0.95, alpha: 0.45), "중지"),
        (10..<11, NSColor(calibratedRed: 0.80, green: 0.45, blue: 0.85, alpha: 0.45), "약지"),
        (11..<12, NSColor(calibratedRed: 0.92, green: 0.45, blue: 0.55, alpha: 0.45), "새끼"),
    ]

    private func learningFill(column: Int, base: NSColor) -> NSColor {
        guard learningMode, column >= 0, column < 12 else { return base }
        for (range, color, _) in Self.fingerColors where range.contains(column) {
            return color
        }
        return base
    }

    private var heldShift = false

    func setShift(_ on: Bool) {
        guard on != heldShift else { return }
        heldShift = on
        needsDisplay = true
    }

    /// Export helper: light keys on the current layer by their main label.
    func highlightMains(_ names: [String]) {
        heldMains = Set(names.filter { !$0.isEmpty })
        var keys = Set<Int>()
        var mice = Set<Int>()
        if store.layers.indices.contains(layerIndex) {
            for c in store.layers[layerIndex].cells {
                guard heldMains.contains(c.main) else { continue }
                if let code = c.code { keys.insert(code) }
                if let b = c.mb { mice.insert(b) }
            }
        }
        heldCodes = keys
        heldMouse = mice
    }

    private func rectForComboDot(position: Int, cells: [(NSRect, KeyCell)]) -> NSPoint? {
        // Flat position → screen cell: grid rows 0-3 then thumbs.
        if position < 48 {
            let ri = position / 12, ci = position % 12
            for (r, _) in cells where r.maxY > CGFloat(5 - ri) * U && r.maxY <= CGFloat(6 - ri) * U + 2
                && abs(r.minX - xFor(ci)) < 2 {
                return NSPoint(x: r.midX, y: r.midY)
            }
            return nil
        }
        let slot = position - 48
        guard slot < 5 else { return nil }
        for (r, _) in cells where abs(r.minX - tx4(slot)) < 2 && r.maxY <= U + 4 { return NSPoint(x: r.midX, y: r.midY) }
        return nil
    }

    private func heatmapFill(base: NSColor, code: Int?) -> NSColor {
        guard heatmap, let code, stats.maxKeyCount > 0 else { return base }
        let maxN = Double(stats.maxKeyCount)
        let n = Double(stats.keyCount(code))
        guard n > 0 else { return base }
        let t = CGFloat(min(1.0, log(n + 1) / log(maxN + 1)))
        // Opaque mix — a translucent fill over a clear view reads as mud.
        let warm = NSColor(calibratedRed: 0.93, green: 0.64, blue: 0.18, alpha: 1)
        let hot = NSColor(calibratedRed: 0.84, green: 0.20, blue: 0.14, alpha: 1)
        if t < 0.45 { return Self.mix(base, warm, t / 0.45) }
        return Self.mix(warm, hot, (t - 0.45) / 0.55)
    }

    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let t = max(0, min(1, t))
        let ac = a.usingColorSpace(.deviceRGB) ?? a
        let bc = b.usingColorSpace(.deviceRGB) ?? b
        return NSColor(calibratedRed: ac.redComponent * (1 - t) + bc.redComponent * t,
                       green: ac.greenComponent * (1 - t) + bc.greenComponent * t,
                       blue: ac.blueComponent * (1 - t) + bc.blueComponent * t,
                       alpha: 1)
    }

    func shaftRect() -> NSRect {
        let left = xFor(5) + S + 6
        let right = xFor(6) - 6
        // Sit on the bottom letter row — never drop into the thumb cluster.
        let floorY = 2 * U + 4
        let top = contentHeight - 8
        return NSRect(x: left, y: floorY, width: max(8, right - left), height: max(8, top - floorY))
    }

    func emitGlyph(code: Int) {
        Companion.shared.layout(in: shaftRect())
        // Layer sentinels only flip the map — digging starts when a real
        // key is pressed while that layer is already held.
        if sentinels[code] != nil { return }
        let token: String
        if let (_, kd) = cells().first(where: { $0.1.code == code }) {
            token = Self.token(for: kd, code: code, label: displayLabel(kd))
        } else {
            token = "·"
        }
        if layerHold != 0 || layerIndex != 0 {
            Companion.shared.strike(.layer, token: token)
        } else {
            Companion.shared.strike(.tap, token: token)
        }
    }

    func strikeHomeRow() {
        Companion.shared.layout(in: shaftRect())
        Companion.shared.strike(.hrm, token: "M")
    }

    private static let dedicatedMods: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62]

    func noteFlags(_ flags: CGEventFlags) {
        let newly = (flags.contains(.maskAlternate) && !lastFlags.contains(.maskAlternate))
            || (flags.contains(.maskControl) && !lastFlags.contains(.maskControl))
            || (flags.contains(.maskCommand) && !lastFlags.contains(.maskCommand))
            || (flags.contains(.maskShift) && !lastFlags.contains(.maskShift))
        lastFlags = flags
        let dedicatedHeld = !heldCodes.isDisjoint(with: Self.dedicatedMods)
        if newly && !dedicatedHeld {
            strikeHomeRow()
        }
    }

    private static func token(for kd: KeyCell, code: Int, label: String) -> String {
        if label.count == 1 { return label }
        if code == 49 { return "·" }
        if let c = label.first, c.isASCII && (c.isLetter || c.isNumber) { return String(c) }
        return "·"
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Palette.current()
        Companion.shared.drawScene(in: shaftRect(), ink: p.text)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let allCells = cells()
        for (rect, kd) in allCells {
            let held = isHeld(kd)
            let path = NSBezierPath(roundedRect: rect, xRadius: R, yRadius: R)
            if held {
                p.held.setFill()
            } else {
                heatmapFill(base: kd.dim ? p.keyFillDim : p.keyFill, code: kd.code).setFill()
            }
            path.fill()
            if held, kd.sub != nil {
                p.accent.setStroke()
                path.lineWidth = 2
                path.stroke()
            } else if !held {
                p.bevel.setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
            if learningMode {
                // Column tinted by the finger that should press it.
                let col = Int(round((rect.minX - 2 - (rect.minX > xFor(6) - U / 2 ? GAP : 0)) / U))
                learningFill(column: col, base: .clear).setFill()
                path.fill()
            }
            if kd.accent && !held {
                p.accent.setStroke()
                path.lineWidth = 1.4
                path.stroke()
            }
            let alpha: CGFloat = kd.dim ? 0.35 : 1.0
            let mainColor = held ? p.heldText : p.text.withAlphaComponent(alpha)
            let label = displayLabel(kd)
            let mainFont = NSFont.systemFont(ofSize: label.count > 3 ? 8.5 : 12, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: mainFont, .foregroundColor: mainColor, .paragraphStyle: para]
            let mainRect = kd.sub == nil ? rect.insetBy(dx: 1, dy: 1)
                : NSRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: rect.height - 12)
            NSAttributedString(string: label, attributes: attrs).draw(in: mainRect)
            if let s = kd.sub {
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
                    .foregroundColor: held ? p.heldText : p.textSub.withAlphaComponent(kd.dim ? 0.4 : 1.0),
                    .paragraphStyle: para
                ]
                NSAttributedString(string: s, attributes: subAttrs)
                    .draw(in: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 10))
            }
        }

        // Combos: dashed ring around each member key plus a shared label.
        for combo in combos where !combo.positions.isEmpty {
            var points: [NSPoint] = []
            for pos in combo.positions {
                if let pt = rectForComboDot(position: pos, cells: allCells) { points.append(pt) }
            }
            guard points.count == combo.positions.count else { continue }
            for (i, pt) in points.enumerated() {
                let ring = NSBezierPath(ovalIn: NSRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
                p.accent.setFill()
                ring.fill()
                if i == 0, points.count > 1 {
                    let line = NSBezierPath()
                    line.move(to: points[0])
                    line.line(to: points[1])
                    line.setLineDash([2, 2], count: 2, phase: 0)
                    line.lineWidth = 1
                    p.accent.setStroke()
                    line.stroke()
                }
            }
            if let first = points.first {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                    .foregroundColor: p.accent
                ]
                NSAttributedString(string: combo.label, attributes: attrs)
                    .draw(at: NSPoint(x: first.x + 6, y: first.y + 4))
            }
        }
        Companion.shared.drawMotes(ink: p.text.withAlphaComponent(0.80))
    }
}

struct SystemStatus {
    var transport: String = "연결 없음"
    var batteries: [String] = []

    var batteryText: String {
        switch batteries.count {
        case 0: return ""
        case 1: return "· 🔋 \(batteries[0])"
        default: return "· 🔋 L \(batteries[0]) · R \(batteries[1])"
        }
    }

    static func probe() -> SystemStatus {
        var st = SystemStatus()
        if let out = run("/usr/sbin/system_profiler", ["SPBluetoothDataType"]) {
            // Scope the Charybdis block by indentation so every Battery
            // Level line inside it is collected (central + proxied peripheral).
            var inCharybdis = false
            var baseIndent = Int.max
            var batteries: [String] = []
            for line in out.split(separator: "\n").map(String.init) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let indent = line.prefix { $0 == " " }.count
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Charybdis:") {
                    inCharybdis = true
                    baseIndent = indent
                    continue
                }
                guard inCharybdis else { continue }
                if indent <= baseIndent {
                    inCharybdis = false
                    continue
                }
                if let r = trimmed.range(of: "Battery Level:") {
                    batteries.append(String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
            }
            if !batteries.isEmpty { st.transport = "BT" }
            st.batteries = batteries
        }
        if let out = run("/usr/sbin/system_profiler", ["SPUSBDataType"]),
           out.contains("ZMK") || out.contains("Charybdis") {
            st.transport = "USB"
        }
        return st
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var statsPanel: NSPanel!
    var statsHUD: StatsHUD!
    var kbView: KeyboardView!
    var statusDot: NSView!
    var statusLabel: NSTextField!
    var layerButtons: [NSButton] = []

    var tap: CFMachPort?
    var axTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var statsHotKeyRef: EventHotKeyRef?
    var autoButton: NSButton?
    var liveSpark: SparklineView?
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu!
    let store = KeymapStore()

    func applicationDidFinishLaunching(_ n: Notification) {
        let kb = KeyboardView(frame: NSRect(x: 0, y: 0, width: 12 * U + GAP + 4, height: 6 * U + 4))
        kb.store = store
        kbView = kb
        store.onReload = { [weak self] in self?.rebuildUI() }

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: kb.frame.width + 20, height: kb.frame.height + 62),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin"),
           let pt = NSPointFromString(saved) as NSPoint?, pt.x > 0 {
            panel.setFrameOrigin(pt)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 12, y: f.maxY - panel.frame.height - 12))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(layerChanged),
                                               name: Notification.Name("overlayLayerChanged"), object: nil)
        panel.orderFrontRegardless()

        buildStatsPanel()
        store.load()
        kbView.sentinels = store.sentinels
        kbView.combos = store.combos
        kbView.panel = panel
        installStatusItem()
        Companion.shared.onFrame = { [weak self] in
            self?.kbView?.needsDisplay = true
            self?.liveSpark?.values = stats.rateSpark(60)
            self?.statusItem?.button?.image = Companion.shared.menuImage()
        }
        installHotkeys()
        tryInstallTap()
        axTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.tryInstallTap()
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            stats.tickLayer(self?.kbView.layerHold ?? self?.kbView.layerIndex ?? 0)
            self?.kbView.fadeOutIfIdle()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in stats.save() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatusFast()
            self?.refreshStatsText()
        }
        Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.probeStatusSlow()
        }
        refreshStatusFast()
        probeStatusSlow()
        refreshStatsText()
    }

    func applicationWillTerminate(_ n: Notification) {
        stats.save()
    }

    /// Renders README / share images offscreen. `--demo` seeds stats and
    /// a lived-in miner (letters in the dirt, dig pose).
    func exportAssets(to dirPath: String) {
        let dir = URL(fileURLWithPath: dirPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.load()
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        if demo { stats.seedDemo() }
        let kb = KeyboardView(frame: NSRect(x: 0, y: 0, width: kbSize.width, height: kbSize.height))
        kb.store = store
        Companion.shared.layout(in: kb.shaftRect())
        if demo {
            Companion.shared.poseForExport(frame: 2, letters: ["E", "T", "A", "N", "O", "S", "R", "I"])
        }
        let pad: CGFloat = 16
        let size = NSSize(width: kbSize.width + pad * 2, height: kbSize.height + pad * 2 + 28)
        // Signature holds so stills read as the layer, not an empty grid.
        let signatures: [[String]] = [
            ["A", "S", "D", "F"],
            ["{", "}", "[", "]"],
            ["←", "↓", "↑", "→"],
            [],
        ]

        var tour: [NSImage] = []
        for (i, layer) in store.layers.enumerated() {
            kb.layerIndex = i
            kb.highlightMains(i < signatures.count ? signatures[i] : [])
            Companion.shared.resetForExport()
            Companion.shared.layout(in: kb.shaftRect())
            Companion.shared.poseForExport(frame: i, letters: ["E", "T", "A", "N", "S", "R"])
            if i < 3 {
                Companion.shared.strike(.hrm, token: "E")
                Companion.shared.stepExport(dt: 0.05)
            }
            let title = i == 3 ? "Vein  ·  Snipe · ball ×¼" : "Vein  ·  \(layer.displayName)"
            guard let rep = renderLayer(kb, size: size, pad: pad, title: title) else { continue }
            writePNG(rep, to: dir.appendingPathComponent("layer-\(i).png"))
            // Snipe is all transparent — keep the PNG, leave it out of the tour.
            if i < 3 {
                tour.append(NSImage(cgImage: rep.cgImage!, size: rep.size))
            }
        }
        kb.highlightMains([])

        if demo {
            kb.heatmap = true
            kb.layerIndex = 0
            Companion.shared.resetForExport()
            Companion.shared.layout(in: kb.shaftRect())
            Companion.shared.poseForExport(frame: 1, letters: ["E", "T", "A", "N", "S", "R"])
            if let rep = renderLayer(kb, size: size, pad: pad, title: "Vein  ·  Heatmap") {
                writePNG(rep, to: dir.appendingPathComponent("heatmap.png"))
            }
            kb.heatmap = false
            if let rep = renderStatsHUD(size: NSSize(width: size.width, height: 600)) {
                writePNG(rep, to: dir.appendingPathComponent("stats.png"))
            }
            writeGIF(renderHeroGIF(kb, size: size, pad: pad), delay: 0.07,
                     to: dir.appendingPathComponent("vein.gif"))
        }

        writeGIF(tour, delay: 1.1, to: dir.appendingPathComponent("layers.gif"))
    }

    /// Scripted typing: home-row holds, chips flying, then Sym / Nav.
    private func renderHeroGIF(_ kb: KeyboardView, size: NSSize, pad: CGFloat) -> [NSImage] {
        struct Beat {
            let layer: Int
            let mains: [String]
            let kind: StrikeKind?
            let token: String
            let title: String
            let linger: Int
        }
        func beat(_ layer: Int, _ mains: [String], _ kind: StrikeKind, _ token: String,
                  _ title: String, linger: Int = 2) -> Beat {
            Beat(layer: layer, mains: mains, kind: kind, token: token, title: title, linger: linger)
        }
        // Every captured frame keeps at least one key down. Snipe is all
        // transparent — skip it. Home-row mods stay held across a word,
        // then Sym / Nav fire the heavy layer bursts.
        let script: [Beat] = [
            beat(0, ["A"], .hrm, "A", "Base"),
            beat(0, ["A", "E"], .tap, "E", "Base"),
            beat(0, ["A", "T"], .tap, "T", "Base"),
            beat(0, ["A", "S"], .hrm, "S", "Base"),
            beat(0, ["A", "S", "D"], .hrm, "D", "Base"),
            beat(0, ["A", "S", "D", "F"], .hrm, "F", "Base"),
            beat(0, ["A", "S", "R"], .tap, "R", "Base"),
            beat(0, ["F", "N"], .hrm, "N", "Base"),
            beat(0, ["F", "C"], .hrm, "C", "Base"),
            beat(0, ["F", "V"], .hrm, "V", "Base"),
            beat(0, ["SPC"], .tap, "S", "Base"),
            beat(1, ["{"], .layer, "{", "Sym", linger: 3),
            beat(1, ["{", "}"], .layer, "}", "Sym", linger: 3),
            beat(1, ["[", "]"], .layer, "[", "Sym", linger: 3),
            beat(1, ["(", ")"], .layer, "(", "Sym", linger: 3),
            beat(1, ["F1", "F2", "F3"], .layer, "F", "Sym"),
            beat(2, ["←"], .layer, "←", "Nav", linger: 3),
            beat(2, ["←", "↓"], .layer, "↓", "Nav", linger: 3),
            beat(2, ["←", "↓", "↑", "→"], .layer, "↑", "Nav", linger: 3),
            beat(2, ["🖱L", "←"], .layer, "M", "Nav"),
            beat(0, ["E", "T"], .tap, "E", "Base"),
            beat(0, ["T", "N"], .tap, "T", "Base"),
            beat(0, ["A", "S", "T"], .hrm, "A", "Base"),
        ]
        var out: [NSImage] = []
        kb.heatmap = false
        Companion.shared.resetForExport()
        Companion.shared.layout(in: kb.shaftRect())
        Companion.shared.poseForExport(frame: 1, letters: ["E", "T", "A", "N", "S", "R"])
        Companion.shared.strike(.hrm, token: "A")
        Companion.shared.stepExport(dt: 0.05)
        for beat in script {
            kb.layerIndex = beat.layer
            kb.highlightMains(beat.mains)
            kb.setShift(false)
            if let kind = beat.kind {
                Companion.shared.strike(kind, token: beat.token)
            }
            for _ in 0..<beat.linger {
                if let rep = renderLayer(kb, size: size, pad: pad, title: "Vein  ·  \(beat.title)") {
                    out.append(NSImage(cgImage: rep.cgImage!, size: rep.size))
                }
                Companion.shared.stepExport(dt: 0.07)
            }
        }
        kb.highlightMains([])
        return out
    }

    private func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
    }

    private func writeGIF(_ frames: [NSImage], delay: Double, to url: URL) {
        guard frames.count > 1 else { return }
        let gifData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(gifData, "com.compuserve.gif" as CFString,
                                                          frames.count, nil) else { return }
        let props = [kCGImagePropertyGIFDictionary as String:
                        [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, props)
        for f in frames {
            let frameProps = [kCGImagePropertyGIFDictionary as String:
                                [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary
            if let cg = f.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                CGImageDestinationAddImage(dest, cg, frameProps)
            }
        }
        if CGImageDestinationFinalize(dest) {
            try? (gifData as Data).write(to: url)
            print("wrote \(url.path)")
        }
    }

    private func renderLayer(_ kb: KeyboardView, size: NSSize, pad: CGFloat, title: String) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(at: NSPoint(x: pad, y: size.height - 14))
        let lv = stats.levelInfo()
        let status = "\(stats.wpm) WPM · \(stats.todayKeys) · L\(lv.level) \(lv.title) · BT L87 R74"
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        NSAttributedString(string: status, attributes: statusAttrs)
            .draw(at: NSPoint(x: pad, y: 3))
        NSGraphicsContext.saveGraphicsState()
        let sparkShift = NSAffineTransform()
        sparkShift.translateX(by: pad, yBy: 16)
        sparkShift.concat()
        let spark = SparklineView(frame: NSRect(x: 0, y: 0, width: size.width - pad * 2, height: 10))
        spark.ink = .white
        spark.values = stats.rateSpark(60)
        spark.draw(spark.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.translateBy(x: pad, y: pad + 14)
        kb.frame = NSRect(origin: .zero, size: kbSize)
        if let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance { kb.draw(kb.bounds) }
        } else {
            kb.draw(kb.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func renderStatsHUD(size: NSSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()

        let ink = NSColor.white
        let left: CGFloat = 20
        let width = size.width - 40
        var y = size.height - 26
        let lv = stats.levelInfo()

        func text(_ s: String, font: NSFont, alpha: CGFloat, at p: NSPoint) {
            NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: ink.withAlphaComponent(alpha)
            ]).draw(at: p)
        }
        func caption(_ s: String) {
            y -= 14
            text(s, font: NSFont.systemFont(ofSize: 9, weight: .medium), alpha: 0.42, at: NSPoint(x: left, y: y))
            y -= 3
        }
        func spark(_ values: [CGFloat], h: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: left, yBy: y - h)
            t.concat()
            let v = SparklineView(frame: NSRect(x: 0, y: 0, width: width, height: h))
            v.ink = ink
            v.values = values
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
            y -= h + 12
        }
        func bars(_ rows: [(String, CGFloat, String)]) {
            let labelW: CGFloat = 64
            let valW: CGFloat = 48
            let barX = left + labelW + 6
            let barW = width - labelW - valW - 10
            let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let valFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let valPara = NSMutableParagraphStyle()
            valPara.alignment = .right
            for (label, t, trailing) in rows {
                y -= 14
                text(label, font: labelFont, alpha: 0.78, at: NSPoint(x: left, y: y))
                let track = NSRect(x: barX, y: y + 2, width: barW, height: 7)
                ink.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                let fillW = max(2, floor(barW * max(0, min(1, t))))
                ink.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: y + 2, width: fillW, height: 7),
                             xRadius: 2, yRadius: 2).fill()
                let val = NSAttributedString(string: trailing, attributes: [
                    .font: valFont,
                    .foregroundColor: ink.withAlphaComponent(0.55),
                    .paragraphStyle: valPara
                ])
                val.draw(in: NSRect(x: barX + barW + 6, y: y, width: valW, height: 13))
            }
            y -= 10
        }

        text("Vein", font: NSFont.systemFont(ofSize: 15, weight: .bold), alpha: 1,
             at: NSPoint(x: left, y: y))
        y -= 18
        text("L\(lv.level) \(lv.title)  ·  \(stats.wpm) WPM  ·  오늘 \(stats.todayKeys)키",
             font: NSFont.systemFont(ofSize: 11, weight: .medium), alpha: 0.72,
             at: NSPoint(x: left, y: y))
        y -= 8

        caption("최근 60초")
        spark(stats.rateSpark(60), h: 26)
        caption("오늘 시간대")
        spark(stats.hourSpark(), h: 20)
        caption("최근 7일")
        spark(stats.weekSpark(), h: 16)

        caption("자주 쓰는 키")
        let top = stats.topKeys(8)
        let topMax = CGFloat(max(top.first?.count ?? 1, 1))
        bars(top.map { (StatsEngine.labelFor($0.code), CGFloat($0.count) / topMax, "\($0.count)") })

        caption("손가락")
        let fingers = stats.fingerCounts
        let fingerTotal = max(fingers.map(\.count).reduce(0, +), 1)
        bars(fingers.map { f in
            let pct = f.count * 100 / fingerTotal
            return (f.finger, CGFloat(pct) / 100, "\(pct)%")
        })

        let layerSecs = stats.todayLayerSeconds
        if !layerSecs.isEmpty {
            caption("레이어")
            let names = ["Base", "Sym", "Nav", "Snipe"]
            let peak = CGFloat(max(layerSecs.values.max() ?? 1, 1))
            let rows = layerSecs.sorted { $0.key < $1.key }.map { layer, secs -> (String, CGFloat, String) in
                let name = layer < names.count ? names[layer] : "L\(layer)"
                return (name, CGFloat(secs) / peak, "\(secs / 60)분")
            }
            bars(rows)
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private var kbSize: NSSize {
        NSSize(width: 12 * U + GAP + 4, height: 6 * U + 4)
    }

    private func rebuildUI() {
        let kbW = kbView.contentWidth
        let kbH = kbView.contentHeight
        let pad: CGFloat = 6
        let topH: CGFloat = 20
        let sparkH: CGFloat = 14
        let botH: CGFloat = 28
        let winW = kbW + pad * 2
        let winH = topH + kbH + sparkH + botH + pad * 2 + 4

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10

        let title = NSStackView()
        title.orientation = .horizontal
        title.spacing = 3
        layerButtons = []
        for (i, layer) in store.layers.enumerated() {
            let b = NSButton(title: layer.displayName, target: self, action: #selector(pickLayer(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.controlSize = .mini
            b.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            layerButtons.append(b)
            title.addArrangedSubview(b)
        }
        let autoButton = NSButton(checkboxWithTitle: "AUTO", target: self, action: #selector(toggleAuto(_:)))
        autoButton.controlSize = .mini
        autoButton.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        autoButton.state = kbView.autoSwitch ? .on : .off
        self.autoButton = autoButton
        title.addArrangedSubview(autoButton)
        statusDot = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = (tap != nil ? NSColor.systemGreen : NSColor.systemRed).cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7)
        ])
        title.addArrangedSubview(statusDot)

        if liveSpark == nil { liveSpark = SparklineView() }
        liveSpark!.lineHeight = sparkH
        liveSpark!.values = stats.rateSpark(60)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.preferredMaxLayoutWidth = kbW
        if let cell = statusLabel.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.usesSingleLineMode = false
        }

        kbView.frame = NSRect(x: 0, y: 0, width: kbW, height: kbH)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        kbView.translatesAutoresizingMaskIntoConstraints = false
        liveSpark!.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        [title, kbView, liveSpark!, statusLabel].forEach { stack.addArrangedSubview($0) }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            kbView.widthAnchor.constraint(equalToConstant: kbW),
            kbView.heightAnchor.constraint(equalToConstant: kbH),
            liveSpark!.widthAnchor.constraint(equalToConstant: kbW),
            liveSpark!.heightAnchor.constraint(equalToConstant: sparkH),
            statusLabel.widthAnchor.constraint(equalToConstant: kbW)
        ])

        let origin = panel.frame.origin
        panel.contentView = content
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: winW, height: winH)), display: true)
        if kbView.layerIndex >= store.layers.count { kbView.layerIndex = 0 }
        styleLayerButtons()
        refreshStatusFast()
    }

    private func buildStatsPanel() {
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 540))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12

        let header = NSStackView()
        header.orientation = .horizontal
        let title = NSTextField(labelWithString: "Vein")
        title.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        header.addArrangedSubview(title)
        let spacer = NSView()
        header.addArrangedSubview(spacer)
        let reset = NSButton(title: "초기화", target: self, action: #selector(resetStats(_:)))
        reset.controlSize = .mini
        header.addArrangedSubview(reset)
        let close = NSButton(title: "닫기", target: self, action: #selector(toggleStatsPanel(_:)))
        close.controlSize = .mini
        header.addArrangedSubview(close)

        statsHUD = StatsHUD(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        statsHUD.translatesAutoresizingMaskIntoConstraints = false
        [header, statsHUD].forEach { stack.addArrangedSubview($0) }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            statsHUD.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        statsPanel = NSPanel(contentRect: content.frame,
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        statsPanel.contentView = content
        statsPanel.title = "Vein"
        statsPanel.isFloatingPanel = true
        statsPanel.level = .floating
        statsPanel.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            statsPanel.setFrameOrigin(NSPoint(x: f.maxX - statsPanel.frame.width - 12,
                                              y: f.maxY - panel.frame.height - 24))
        }
    }

    @objc func toggleStatsPanel(_ sender: Any?) {
        if statsPanel.isVisible { statsPanel.orderOut(nil) } else { statsPanel.orderFrontRegardless() }
    }

    @objc func resetStats(_ sender: Any?) {
        // Full reset is destructive on purpose; easiest via removing the store file.
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KeymapOverlay/stats.json") {
            try? FileManager.default.removeItem(at: url)
        }
        exit(0)
    }

    @objc func toggleHeatmap(_ sender: Any?) {
        kbView.heatmap.toggle()
        kbView.needsDisplay = true
    }

    @objc func toggleLearning(_ sender: Any?) {
        kbView.learningMode.toggle()
        kbView.needsDisplay = true
    }

    @objc func toggleAutoHide(_ sender: Any?) {
        kbView.autoHideEnabled.toggle()
        if !kbView.autoHideEnabled { kbView.noteActivity() }
    }

    @objc func pickSkin(_ sender: NSMenuItem) {
        guard ArtBank.skins.indices.contains(sender.tag) else { return }
        Companion.shared.setSkin(ArtBank.skins[sender.tag].id)
        kbView.needsDisplay = true
        statusItem?.button?.image = Companion.shared.menuImage()
    }

    @objc func pickLayer(_ sender: NSButton) {
        kbView.layerIndex = sender.tag
    }

    @objc func toggleAuto(_ sender: Any?) {
        if let b = sender as? NSButton {
            kbView.autoSwitch = b.state == .on
        } else {
            kbView.autoSwitch.toggle()
            autoButton?.state = kbView.autoSwitch ? .on : .off
        }
    }

    @objc func layerChanged() {
        styleLayerButtons()
    }

    private func styleLayerButtons() {
        let p = Palette.current()
        for b in layerButtons {
            let on = b.tag == kbView.layerIndex
            b.contentTintColor = on ? p.accent : p.text.withAlphaComponent(0.55)
            b.font = NSFont.systemFont(ofSize: 10, weight: on ? .bold : .medium)
        }
    }

    func windowDidMove(_ n: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin")
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 16)
        item.button?.image = Companion.shared.menuImage()
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu = NSMenu()
        statusItem = item
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        let overlay = NSMenuItem(title: panel.isVisible ? "오버레이 숨기기" : "오버레이 보이기",
                                 action: #selector(togglePanel), keyEquivalent: "k")
        overlay.keyEquivalentModifierMask = [.command, .control]
        overlay.target = self
        menu.addItem(overlay)
        let rec = NSMenuItem(title: "기록", action: #selector(toggleStatsPanel(_:)), keyEquivalent: "s")
        rec.keyEquivalentModifierMask = [.command, .control]
        rec.target = self
        menu.addItem(rec)
        menu.addItem(.separator())
        menu.addItem(checkItem("AUTO 레이어", on: kbView.autoSwitch, action: #selector(toggleAuto(_:))))
        menu.addItem(checkItem("히트맵", on: kbView.heatmap, action: #selector(toggleHeatmap(_:))))
        menu.addItem(checkItem("학습 모드", on: kbView.learningMode, action: #selector(toggleLearning(_:))))
        menu.addItem(checkItem("자동 숨김", on: kbView.autoHideEnabled, action: #selector(toggleAutoHide(_:))))
        menu.addItem(.separator())
        let skins = NSMenu()
        for (i, skin) in ArtBank.skins.enumerated() {
            let item = NSMenuItem(title: skin.title, action: #selector(pickSkin(_:)), keyEquivalent: "")
            item.tag = i
            item.state = skin.id == Companion.shared.skinId ? .on : .off
            item.target = self
            skins.addItem(item)
        }
        let skinItem = NSMenuItem(title: "캐릭터", action: nil, keyEquivalent: "")
        skinItem.submenu = skins
        menu.addItem(skinItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusMenu = menu
    }

    private func checkItem(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        item.target = self
        return item
    }

    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            refreshStatusMenu()
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: statusItem?.button)
        } else {
            togglePanel()
        }
    }

    private var cachedStatus = SystemStatus()

    /// Composes the status line from cached data only — runs every second and
    /// must never trigger the slow system_profiler probe (that alternation is
    /// what made the label flicker).
    private func refreshStatusFast() {
        let fileName = store.keymapURL?.lastPathComponent ?? (store.lastError ?? "키맵 없음")
        let lv = stats.levelInfo()
        var line1 = "\(stats.wpm) WPM · \(stats.todayKeys) · L\(lv.level) \(lv.title)"
        if stats.liveCombo >= 6 { line1 += " · x\(stats.liveCombo)" }
        if stats.streak > 1 { line1 += " · \(stats.streak)d" }
        let bat = cachedStatus.batteries.joined(separator: "/")
        var line2 = store.preset.name
        if !cachedStatus.transport.isEmpty { line2 += " · \(cachedStatus.transport)" }
        if !bat.isEmpty { line2 += " \(bat)" }
        line2 += " · \(fileName)"
        statusLabel?.stringValue = line1 + "\n" + line2
        liveSpark?.values = stats.rateSpark(60)
        let tip = "Vein  \(stats.wpm) WPM  L\(lv.level) \(lv.title)"
        statusItem?.button?.toolTip = tip
    }

    private func probeStatusSlow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let st = SystemStatus.probe()
            DispatchQueue.main.async {
                self?.cachedStatus = st
                self?.refreshStatusFast()
            }
        }
    }

    private func refreshStatsText() {
        guard statsPanel.isVisible else { return }
        statsHUD?.refresh()
    }

    func statsReport() -> String {
        var lines: [String] = []
        let lv = stats.levelInfo()
        lines.append("L\(lv.level) \(lv.title)  \(lv.xpInto)/\(lv.xpNeed)")
        lines.append("오늘 \(stats.todayKeys)키 · 클릭 \(stats.todayClicks) · 스크롤 \(stats.todayScrolls)")
        lines.append("\(stats.wpm) WPM · 최고 \(stats.sessionPeakWPM) · 누적 \(stats.totalKeys)")
        if stats.streak > 0 { lines.append("연속 \(stats.streak)일") }
        if stats.maxComboToday > 0 { lines.append("오늘 콤보 \(stats.maxComboToday)") }
        lines.append("")
        lines.append("— 최근 7일 —")
        let week = stats.recentDays(7)
        let maxDay = max(week.map(\.keys).max() ?? 1, 1)
        for d in week {
            let bar = String(repeating: "█", count: max(1, d.keys * 12 / maxDay))
            lines.append("\(String(d.day.suffix(5))) \(bar) \(d.keys)")
        }
        lines.append("")
        lines.append("— 자주 쓰는 키 —")
        let topMax = stats.topKeys(8).first?.count ?? 1
        for (code, count) in stats.topKeys(8) {
            let label = StatsEngine.labelFor(code)
            let bar = String(repeating: "▓", count: max(1, count * 14 / max(topMax, 1)))
            lines.append("\(label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(bar) \(count)")
        }
        lines.append("")
        lines.append("— 손가락 분포 —")
        let fingerTotal = max(stats.fingerCounts.map(\.count).reduce(0, +), 1)
        for (finger, count) in stats.fingerCounts {
            let pct = count * 100 / fingerTotal
            let bar = String(repeating: "▓", count: pct / 4)
            lines.append("\(finger.padding(toLength: 5, withPad: " ", startingAt: 0)) \(bar) \(pct)%")
        }
        let layerSecs = stats.todayLayerSeconds
        if !layerSecs.isEmpty {
            lines.append("")
            lines.append("— 레이어 시간(분) —")
            let names = ["Base", "Sym", "Nav", "Snipe", "L4", "L5", "L6", "L7"]
            for (layer, secs) in layerSecs.sorted(by: { $0.key < $1.key }) {
                let name = layer < names.count ? names[layer] : "L\(layer)"
                lines.append("\(name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(secs / 60)분")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func installHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event else { return noErr }
            var hotID = EventHotKeyID()
            var size = MemoryLayout<EventHotKeyID>.size
            GetEventParameter(event, UInt32(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              size, &size, &hotID)
            let which = hotID.id
            NotificationCenter.default.post(name: Notification.Name(which == 2 ? "toggleStats" : "toggleOverlay"),
                                            object: nil)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
        NotificationCenter.default.addObserver(self, selector: #selector(togglePanel),
                                               name: Notification.Name("toggleOverlay"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatsPanel),
                                               name: Notification.Name("toggleStats"), object: nil)
        var ref: EventHotKeyRef?
        var id = EventHotKeyID(signature: OSType(0x43444F56), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        var ref2: EventHotKeyRef?
        let id2 = EventHotKeyID(signature: OSType(0x43444F56), id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | controlKey), id2,
                            GetApplicationEventTarget(), 0, &ref2)
        statsHotKeyRef = ref2
    }

    private func tryInstallTap() {
        if tap != nil { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let weakKb = Unmanaged.passUnretained(kbView)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let view = Unmanaged<KeyboardView>.fromOpaque(refcon).takeUnretainedValue()
            let t = type
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
            DispatchQueue.main.async {
                switch t {
                case .keyDown, .keyUp:
                    if t == .keyDown {
                        view.heldCodes.insert(code)
                        if !autorepeat {
                            stats.recordKey(code: code)
                            view.emitGlyph(code: code)
                        }
                        if let l = view.sentinels[code] {
                            view.layerHold = l
                            view.lastFn = l
                            view.lastLayerEngage = Date()
                            if view.autoSwitch { view.layerIndex = l }
                        }
                        if view.autoSwitch && view.layerHold == 0 && view.sentinels[code] == nil {
                            view.layerIndex = 0
                        }
                    } else {
                        view.heldCodes.remove(code)
                        if let l = view.sentinels[code], view.layerHold == l {
                            view.layerHold = 0
                            if view.autoSwitch { view.layerIndex = 0 }
                        }
                    }
                    view.heldCtrl = event.flags.contains(.maskControl)
                    view.setShift(event.flags.contains(.maskShift))
                    view.noteFlags(event.flags)
                case .scrollWheel:
                    stats.recordScroll()
                    // Trackpad / Magic Mouse send continuous pixel scroll.
                    // The Charybdis ball sends discrete wheel ticks, and only
                    // while a layer is (or just was) held — don't open Nav
                    // for a MacBook two-finger swipe.
                    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                    if !continuous, view.autoSwitch, view.layerIndex == 0,
                       Date().timeIntervalSince(view.lastLayerEngage) < 1.2 {
                        view.layerIndex = view.lastFn
                    }
                case .flagsChanged:
                    view.heldCtrl = event.flags.contains(.maskControl)
                    view.setShift(event.flags.contains(.maskShift))
                    view.noteFlags(event.flags)
                case .leftMouseDown, .leftMouseUp:
                    if t == .leftMouseDown {
                        view.heldMouse.insert(0)
                        stats.recordClick()
                    } else { view.heldMouse.remove(0) }
                case .rightMouseDown, .rightMouseUp:
                    if t == .rightMouseDown { view.heldMouse.insert(1) } else { view.heldMouse.remove(1) }
                case .otherMouseDown, .otherMouseUp:
                    let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                    if t == .otherMouseDown { view.heldMouse.insert(b) } else { view.heldMouse.remove(b) }
                default: break
                }
                view.needsDisplay = true
                view.noteActivity()
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: callback,
                                           userInfo: weakKb.toOpaque()) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0),
                           .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        statusDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
    }
}

let args = ProcessInfo.processInfo.arguments
if let idx = args.firstIndex(of: "--export-assets"), args.count > idx + 1 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let d = AppDelegate()
    d.exportAssets(to: args[idx + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
