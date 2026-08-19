import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// KeymapOverlay: a macOS companion overlay for ZMK keyboards.
// Renders the physical layout and live key/layer state from the firmware's
// own `.keymap` file (see ZMKKeymap.swift), records usage statistics
// (StatsEngine.swift), and highlights keys as they are pressed.

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

    static func current() -> Palette {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            return Palette(keyFill: NSColor(white: 0.18, alpha: 1),
                           keyFillDim: NSColor(white: 0.10, alpha: 1),
                           text: .white,
                           textSub: NSColor.white.withAlphaComponent(0.55),
                           accent: NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1),
                           held: NSColor.systemYellow.withAlphaComponent(0.9),
                           heldText: .black)
        }
        return Palette(keyFill: NSColor(white: 1.0, alpha: 1),
                       keyFillDim: NSColor(white: 0.87, alpha: 1),
                       text: .black,
                       textSub: NSColor.black.withAlphaComponent(0.55),
                       accent: NSColor.systemBlue,
                       held: NSColor.systemYellow,
                       heldText: .black)
    }
}

final class KeymapStore {
    private(set) var layers: [KeymapLayer] = []
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
        let sibling = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("zmk-config-charybdis/config/charybdis.keymap")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
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
        layers = ZMKKeymapParser().parse(text)
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
    var autoSwitch = true
    var lastFn = 1
    var layerHold = 0
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
        if let b = kd.mb { return heldMouse.contains(b) }
        guard let code = kd.code else { return false }
        return heldCodes.contains(code) && (!kd.needsCtrl || heldCtrl)
    }

    private func heatmapFill(base: NSColor, code: Int?) -> NSColor {
        guard heatmap, let code, stats.maxKeyCount > 0 else { return base }
        let maxN = Double(stats.maxKeyCount)
        let n = Double(stats.keyCount(code))
        guard n > 0 else { return base }
        let t = min(1.0, log(n + 1) / log(maxN + 1))
        return NSColor(calibratedRed: 0.55 + 0.45 * t, green: 0.85 * (1 - t) + 0.1, blue: 0.2, alpha: 0.35 + 0.4 * t)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Palette.current()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        for (rect, kd) in cells() {
            let held = isHeld(kd)
            let path = NSBezierPath(roundedRect: rect, xRadius: R, yRadius: R)
            if held {
                p.held.setFill()
            } else {
                heatmapFill(base: kd.dim ? p.keyFillDim : p.keyFill, code: kd.code).setFill()
            }
            path.fill()
            if kd.accent && !held {
                p.accent.setStroke()
                path.lineWidth = 1.4
                path.stroke()
            }
            let alpha: CGFloat = kd.dim ? 0.35 : 1.0
            let mainColor = held ? p.heldText : p.text.withAlphaComponent(alpha)
            let mainFont = NSFont.systemFont(ofSize: kd.main.count > 3 ? 8.5 : 12, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: mainFont, .foregroundColor: mainColor, .paragraphStyle: para]
            let mainRect = kd.sub == nil ? rect.insetBy(dx: 1, dy: 1)
                : NSRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: rect.height - 12)
            NSAttributedString(string: kd.main, attributes: attrs).draw(in: mainRect)
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
    }
}

struct SystemStatus {
    var transport: String = "연결 없음"
    var battery: String?

    static func probe() -> SystemStatus {
        var st = SystemStatus()
        if let out = run("/usr/sbin/system_profiler", ["SPBluetoothDataType"]) {
            var inDevice = false
            var battery: String?
            for line in out.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Charybdis:") { inDevice = true; continue }
                if trimmed.hasSuffix(":") { inDevice = false }
                if inDevice, let r = trimmed.range(of: "Battery Level:") {
                    battery = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if battery != nil { st.transport = "BT" }
            st.battery = battery
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
    var statsText: NSTextField!
    var kbView: KeyboardView!
    var statusDot: NSView!
    var statusLabel: NSTextField!
    var layerButtons: [NSButton] = []
    var heatButton: NSButton!
    var tap: CFMachPort?
    var axTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var statsHotKeyRef: EventHotKeyRef?
    var autoButton: NSButton?
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
        installHotkeys()
        tryInstallTap()
        axTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.tryInstallTap()
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            stats.tickLayer(self?.kbView.layerHold ?? self?.kbView.layerIndex ?? 0)
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in stats.save() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
            self?.refreshStatsText()
        }
        refreshStatus()
        refreshStatsText()
    }

    func applicationWillTerminate(_ n: Notification) {
        stats.save()
    }

    /// Renders each layer to PNG plus an animated GIF cycling through them.
    /// Used for README assets and for sharing one's keymap as an image.
    func exportAssets(to dirPath: String) {
        let dir = URL(fileURLWithPath: dirPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.load()
        let kb = KeyboardView(frame: NSRect(x: 0, y: 0, width: kbSize.width, height: kbSize.height))
        kb.store = store
        let pad: CGFloat = 16
        let size = NSSize(width: kbSize.width + pad * 2, height: kbSize.height + pad * 2 + 18)

        var frames: [NSImage] = []
        for (i, layer) in store.layers.enumerated() {
            kb.layerIndex = i
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                             pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
            let title = "\(store.preset.name) — \(layer.displayName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75)
            ]
            NSAttributedString(string: title, attributes: attrs)
                .draw(at: NSPoint(x: pad, y: size.height - 14))
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: pad, y: pad)
            kb.frame = NSRect(origin: .zero, size: kbSize)
            kb.draw(kb.bounds)
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = dir.appendingPathComponent("layer-\(i).png")
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
            frames.append(NSImage(cgImage: rep.cgImage!, size: rep.size))
        }

        guard frames.count > 1 else { return }
        let gifData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(gifData, "com.compuserve.gif" as CFString,
                                                       frames.count, nil) {
            let props = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
            CGImageDestinationSetProperties(dest, props)
            for f in frames {
                let frameProps = [kCGImagePropertyGIFDictionary as String:
                                    [kCGImagePropertyGIFDelayTime as String: 0.9]] as CFDictionary
                if let cg = f.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    CGImageDestinationAddImage(dest, cg, frameProps)
                }
            }
            if CGImageDestinationFinalize(dest) {
                let url = dir.appendingPathComponent("layers.gif")
                try? (gifData as Data).write(to: url)
                print("wrote \(url.path)")
            }
        }
    }

    private var kbSize: NSSize {
        NSSize(width: 12 * U + GAP + 4, height: 6 * U + 4)
    }

    private func rebuildUI() {
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: kbView.frame.width + 20,
                                                       height: kbView.frame.height + 62))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12

        let title = NSStackView()
        title.orientation = .horizontal
        title.spacing = 6
        layerButtons = []
        for (i, layer) in store.layers.enumerated() {
            let b = NSButton(title: layer.displayName, target: self, action: #selector(pickLayer(_:)))
            b.tag = i
            b.bezelStyle = .texturedRounded
            b.controlSize = .mini
            b.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            layerButtons.append(b)
            title.addArrangedSubview(b)
        }
        let autoButton = NSButton(checkboxWithTitle: "AUTO", target: self, action: #selector(toggleAuto(_:)))
        autoButton.controlSize = .mini
        autoButton.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        autoButton.state = .on
        self.autoButton = autoButton
        title.addArrangedSubview(autoButton)
        heatButton = NSButton(title: "🔥", target: self, action: #selector(toggleHeatmap(_:)))
        heatButton.bezelStyle = .texturedRounded
        heatButton.controlSize = .mini
        title.addArrangedSubview(heatButton)
        let statsButton = NSButton(title: "📊", target: self, action: #selector(toggleStatsPanel(_:)))
        statsButton.bezelStyle = .texturedRounded
        statsButton.controlSize = .mini
        title.addArrangedSubview(statsButton)
        statusDot = NSView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = (tap != nil ? NSColor.systemGreen : NSColor.systemRed).cgColor
        statusDot.layer?.cornerRadius = 4.5
        title.addArrangedSubview(statusDot)
        let hint = NSTextField(labelWithString: "⌘⌃K")
        hint.font = NSFont.systemFont(ofSize: 9)
        hint.textColor = .secondaryLabelColor
        title.addArrangedSubview(hint)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        kbView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        [title, kbView, statusLabel].forEach { stack.addArrangedSubview($0) }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])

        let oldFrame = panel.frame
        panel.contentView = content
        panel.setFrame(oldFrame, display: true)
        if kbView.layerIndex >= store.layers.count { kbView.layerIndex = 0 }
        styleLayerButtons()
        refreshStatus()
    }

    private func buildStatsPanel() {
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12

        let header = NSStackView()
        header.orientation = .horizontal
        let title = NSTextField(labelWithString: "통계")
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

        statsText = NSTextField(labelWithString: "")
        statsText.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        statsText.translatesAutoresizingMaskIntoConstraints = false
        [header, statsText].forEach { stack.addArrangedSubview($0) }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])

        statsPanel = NSPanel(contentRect: content.frame,
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        statsPanel.contentView = content
        statsPanel.title = "KeymapOverlay 통계"
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

    @objc func toggleHeatmap(_ sender: NSButton) {
        kbView.heatmap.toggle()
        kbView.needsDisplay = true
    }

    @objc func pickLayer(_ sender: NSButton) {
        kbView.layerIndex = sender.tag
    }

    @objc func toggleAuto(_ sender: NSButton) {
        kbView.autoSwitch = sender.state == .on
    }

    @objc func layerChanged() {
        styleLayerButtons()
    }

    private func styleLayerButtons() {
        let p = Palette.current()
        for b in layerButtons {
            let on = b.tag == kbView.layerIndex
            b.contentTintColor = on ? NSColor.systemYellow : p.text
            b.font = NSFont.systemFont(ofSize: 10, weight: on ? .bold : .medium)
        }
    }

    func windowDidMove(_ n: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin")
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func refreshStatus() {
        statusLabel?.stringValue = "⚡ \(stats.wpm) WPM · 🔑 \(stats.todayKeys)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let st = SystemStatus.probe()
            DispatchQueue.main.async {
                guard let self else { return }
                var text = "\(self.store.preset.name) · \(st.transport)"
                if let b = st.battery { text += " · 배터리 \(b)" }
                let fileName = self.store.keymapURL?.lastPathComponent ?? (self.store.lastError ?? "키맵 없음")
                self.statusLabel?.stringValue = "⚡ \(stats.wpm) WPM · 🔑 \(stats.todayKeys) · " + text + " · " + fileName
            }
        }
    }

    private func refreshStatsText() {
        guard statsPanel.isVisible, let st = statsText else { return }
        var lines: [String] = []
        lines.append("오늘: \(stats.todayKeys)키 · 클릭 \(stats.todayClicks) · 스크롤 \(stats.todayScrolls)")
        lines.append("현재 \(stats.wpm) WPM · 누적 \(stats.totalKeys)키")
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
        st.stringValue = lines.joined(separator: "\n")
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
                        if !autorepeat { stats.recordKey(code: code) }
                        if let l = view.sentinels[code] {
                            view.layerHold = l
                            view.lastFn = l
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
                case .scrollWheel:
                    stats.recordScroll()
                    if view.autoSwitch && view.layerIndex == 0 { view.layerIndex = view.lastFn }
                case .flagsChanged:
                    view.heldCtrl = event.flags.contains(.maskControl)
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
