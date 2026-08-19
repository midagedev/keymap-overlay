import Cocoa

// Cuphead-style miner in the split gap, plus letter chips that pop from
// the drill tip. Falls back to a 1-bit sprite if the painted frames are
// missing. Menu-bar icon is a monochrome silhouette.

enum CompanionMood {
    case sleep, idle, dig
}

enum StrikeKind {
    case tap
    case hrm
    case layer
}

struct LevelInfo {
    let level: Int
    let title: String
    let xpInto: Int
    let xpNeed: Int
}

struct VeinGlyph {
    var ch: Character
    var tx: Int
    var wy: Int
    var angle: CGFloat
}

struct GlyphMote {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var life: CGFloat
    var ch: Character
    var pixel: CGFloat
    var angle: CGFloat
    var spin: CGFloat
}

final class Companion {
    static let shared = Companion()

    private(set) var frameIndex = 0
    private(set) var mood: CompanionMood = .sleep
    private var lastKey = Date.distantPast
    private var lastTick = Date()
    private var timer: Timer?
    private var motes: [GlyphMote] = []
    private var minerRect = NSRect.zero
    private var lastShaft = NSRect.zero
    private var depth: CGFloat = 0
    private var veins: [VeinGlyph] = []
    private var shake: CGFloat = 0
    private var pulse: CGFloat = 0
    private var bobPhase: CGFloat = 0
    private var bobKick: CGFloat = 0
    static let craterDepth: CGFloat = 14
    static let tile: CGFloat = 5
    var shaftTarget: NSPoint = .zero
    var onFrame: (() -> Void)?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func noteKey() {
        lastKey = Date()
        mood = .dig
        depth += 1.6
        let count = ArtBank.ready ? ArtBank.count(.dig) : SpriteBank.frames(for: .dig).count
        if count > 0 { frameIndex = (frameIndex + 1) % count }
        bobKick = max(bobKick, 3.5)
        bobPhase += .pi
        onFrame?()
    }

    func strike(_ kind: StrikeKind, token: String = "·") {
        switch kind {
        case .tap:
            spawn(token)
        case .hrm:
            noteKey()
            depth += 1.4
            shake = max(shake, 3)
            pulse = 1
            bobKick = 4.5
            burst(token, count: 3, speed: 1.25)
            plant(firstChar(token))
        case .layer:
            noteKey()
            depth += 2.8
            shake = 5
            pulse = 1
            bobKick = 6
            burst(token, count: 6, speed: 1.55)
            plant(firstChar(token))
            plant(firstChar(token))
        }
    }

    func spawn(_ raw: String) {
        noteKey()
        burst(raw, count: 1, speed: 1)
        plant(firstChar(raw))
    }

    /// Offscreen export: freeze a dig pose so README frames look lived-in.
    func poseForExport(frame: Int, letters: [String] = []) {
        layout(in: lastShaft.width > 0 ? lastShaft : NSRect(x: 0, y: 0, width: 90, height: 120))
        mood = .dig
        let n = ArtBank.ready ? ArtBank.count(.dig) : 4
        frameIndex = n > 0 ? frame % n : 0
        bobKick = 3.2
        bobPhase = CGFloat(frame) * (.pi / 2)
        pulse = frame % 2 == 0 ? 0.7 : 0.25
        for s in letters { plant(firstChar(s)) }
    }

    private func firstChar(_ raw: String) -> Character {
        if let first = raw.first, first == "·" || first.isASCII { return first }
        return "·"
    }

    private func burst(_ raw: String, count: Int, speed: CGFloat) {
        let ch = firstChar(raw)
        for _ in 0..<count {
            if motes.count >= 22 { motes.removeFirst() }
            motes.append(GlyphMote(
                x: shaftTarget.x + CGFloat.random(in: -5...5),
                y: shaftTarget.y + CGFloat.random(in: -2...2),
                vx: CGFloat.random(in: -55...55) * speed,
                vy: CGFloat.random(in: 70...140) * speed,
                life: 1,
                ch: ch,
                pixel: CGFloat.random(in: 0.8...1.35),
                angle: CGFloat.random(in: -0.9...0.9),
                spin: CGFloat.random(in: -6...6)
            ))
        }
    }

    private func plant(_ ch: Character) {
        guard ch != "·", lastShaft.width > 0 else { return }
        let tile = Companion.tile
        let scroll = Int(floor(depth / tile))
        let holeHalf = max(6, minerRect.width / 2)
        let side: CGFloat = Bool.random() ? -1 : 1
        let x = lastShaft.midX + side * (holeHalf + CGFloat.random(in: 6...16))
        let y = shaftTarget.y + CGFloat.random(in: 4...36)
        let tx = Int(floor(x / tile))
        let ty = Int(floor(y / tile))
        if veins.count >= 30 { veins.removeFirst() }
        veins.append(VeinGlyph(ch: ch, tx: tx, wy: ty - scroll,
                               angle: CGFloat.random(in: -0.5...0.5)))
    }

    func menuImage() -> NSImage {
        let size = NSSize(width: 14, height: 16)
        if let src = ArtBank.frame(mood: mood, index: frameIndex) {
            return Self.templateIcon(from: src, size: size)
        }
        return SpriteBank.image(mood: mood, frame: frameIndex, pointSize: size, template: true)
    }

    private static func templateIcon(from src: NSImage, size: NSSize) -> NSImage {
        let scale: CGFloat = 2
        let pw = max(1, Int(size.width * scale))
        let ph = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return src
        }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        src.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return src }
        let img = NSImage(cgImage: cg, size: size)
        img.isTemplate = true
        return img
    }

    /// Places the miner in the gap and sets `shaftTarget` to the drill tip.
    func layout(in shaft: NSRect) {
        let w: CGFloat
        let h: CGFloat
        let tipX: CGFloat
        let tipFromBottom: CGFloat
        if ArtBank.ready {
            let avail = floor((shaft.width - 8) / CGFloat(ArtBank.gridW))
            let preferred = max(1, floor(ArtBank.displayWidth / CGFloat(ArtBank.gridW)))
            let scale = max(1, min(preferred, avail > 0 ? avail : preferred))
            w = CGFloat(ArtBank.gridW) * scale
            h = CGFloat(ArtBank.gridH) * scale
            tipX = ArtBank.tipX
            tipFromBottom = 1 - ArtBank.tipY
        } else {
            let px = SpriteBank.overlayPixel
            w = CGFloat(SpriteBank.width) * px
            h = CGFloat(SpriteBank.height) * px
            tipX = 0.5
            tipFromBottom = 0
        }
        let x = floor(shaft.midX - w / 2)
        // Stand in a crater just above the dirt floor, not mid-shaft.
        let crater = Companion.craterDepth
        let tipY = floor(shaft.minY + crater + 3)
        let minY = floor(tipY - tipFromBottom * h)
        minerRect = NSRect(x: x, y: minY, width: w, height: h)
        lastShaft = shaft
        shaftTarget = NSPoint(x: floor(x + w * tipX), y: tipY)
    }

    func drawScene(in shaft: NSRect, ink: NSColor) {
        layout(in: shaft)
        drawShaft(in: shaft, ink: ink)
        let bob = floor(sin(bobPhase) * bobKick)
        let body = minerRect.offsetBy(dx: 0, dy: bob)
        if ArtBank.ready, let img = ArtBank.frame(mood: mood, index: frameIndex) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSGraphicsContext.current?.shouldAntialias = false
            img.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            SpriteBank.draw(mood: mood, frame: frameIndex, in: body, ink: ink.withAlphaComponent(1))
        }
        if pulse > 0.05 {
            NSGraphicsContext.current?.shouldAntialias = false
            let r = 7 + (1 - pulse) * 16
            let ring = NSBezierPath(ovalIn: NSRect(x: shaftTarget.x - r, y: shaftTarget.y - r * 0.55,
                                                   width: r * 2, height: r * 1.1))
            ink.withAlphaComponent(0.18 + pulse * 0.35).setStroke()
            ring.lineWidth = pulse > 0.6 ? 2 : 1
            ring.stroke()
        }
    }

    func drawMotes(ink: NSColor) {
        for mote in motes {
            let a = 0.40 + max(0, mote.life) * 0.50
            LCDFont.draw(mote.ch, at: NSPoint(x: mote.x, y: mote.y),
                         pixel: mote.pixel, color: ink.withAlphaComponent(a),
                         angle: mote.angle)
        }
    }

    private func drawShaft(in shaft: NSRect, ink: NSColor) {
        NSGraphicsContext.current?.shouldAntialias = false
        let tile = Companion.tile
        let feetY = shaftTarget.y
        let floorY = shaft.minY
        let holeHalf: CGFloat = max(6, minerRect.width / 2)
        let scroll = Int(floor(depth / tile))
        let jolt: CGFloat = shake > 0.4 ? (Int(depth) & 1 == 0 ? 1 : -1) * min(2, shake) : 0

        let x0 = Int(floor(shaft.minX / tile))
        let x1 = Int(ceil(shaft.maxX / tile))
        let y0 = Int(floor(shaft.minY / tile))
        let y1 = Int(ceil(shaft.maxY / tile))
        for ty in y0..<y1 {
            for tx in x0..<x1 {
                let cell = NSRect(x: CGFloat(tx) * tile + jolt, y: CGFloat(ty) * tile, width: tile, height: tile)
                    .intersection(shaft)
                if cell.isNull || cell.width < 0.5 || cell.height < 0.5 { continue }
                if Self.inPit(cell.midX, cell.midY, midX: shaft.midX, floorY: floorY,
                              feetY: feetY, holeHalf: holeHalf) {
                    continue
                }
                let kind = Self.block(tx, ty - scroll)
                Self.fillBlock(cell, kind: kind, ink: ink)
            }
        }

        // Crater lip — packed dirt under the drill.
        ink.withAlphaComponent(0.42).setFill()
        let lipW: CGFloat = holeHalf * 2 - 4
        NSRect(x: floor(shaft.midX - lipW / 2), y: floor(floorY), width: ceil(lipW), height: 2).fill()
        NSRect(x: floor(shaft.midX - 5), y: floor(floorY + 2), width: 10, height: 1).fill()

        for v in veins {
            let ty = v.wy + scroll
            let mid = NSPoint(x: (CGFloat(v.tx) + 0.5) * tile,
                              y: (CGFloat(ty) + 0.5) * tile)
            if !shaft.contains(mid) { continue }
            if Self.inPit(mid.x, mid.y, midX: shaft.midX, floorY: floorY,
                          feetY: feetY, holeHalf: holeHalf) { continue }
            LCDFont.draw(v.ch, at: mid, pixel: 1, color: ink.withAlphaComponent(0.62),
                         angle: v.angle)
        }
    }

    /// U-shaped crater: wide at the feet, a shallow bowl down to the floor.
    private static func inPit(_ x: CGFloat, _ y: CGFloat, midX: CGFloat, floorY: CGFloat,
                              feetY: CGFloat, holeHalf: CGFloat) -> Bool {
        if y > feetY + 4 { return abs(x - midX) < holeHalf }
        if y < floorY { return false }
        let span = max(6, feetY - floorY)
        let t = max(0, min(1, (y - floorY) / span))
        let half = 3 + (holeHalf - 3) * t * t
        return abs(x - midX) < half
    }

    private static func block(_ tx: Int, _ ty: Int) -> Int {
        var x = tx &* 374_761_393 &+ ty &* 668_265_263
        x = (x ^ (x >> 13)) &* 1_274_126_177
        return (x >> 16) & 7
    }

    private static func fillBlock(_ cell: NSRect, kind: Int, ink: NSColor) {
        let r = NSRect(x: floor(cell.minX), y: floor(cell.minY),
                       width: ceil(cell.width), height: ceil(cell.height))
        switch kind {
        case 6, 7:
            // Stone / cobble
            ink.withAlphaComponent(0.48).setFill()
            r.fill()
            ink.withAlphaComponent(0.22).setFill()
            NSRect(x: r.minX, y: r.minY, width: 2, height: 2).fill()
            NSRect(x: r.maxX - 2, y: r.maxY - 2, width: 2, height: 1).fill()
        case 0, 1:
            ink.withAlphaComponent(0.16).setFill()
            r.fill()
        case 2, 3:
            ink.withAlphaComponent(0.26).setFill()
            r.fill()
        default:
            ink.withAlphaComponent(0.34).setFill()
            r.fill()
            if kind == 5 {
                ink.withAlphaComponent(0.18).setFill()
                NSRect(x: r.minX + 1, y: r.minY + 1, width: 2, height: 2).fill()
            }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let idleFor = now.timeIntervalSince(lastKey)
        var dirty = false
        // Dig only while keys are coming in. A short tail lets the last
        // strike read, then it snaps to idle — no free-running jackhammer.
        let next: CompanionMood
        if idleFor < 0.22 {
            next = .dig
        } else if idleFor < 10 {
            next = .idle
        } else {
            next = .sleep
        }
        if next != mood {
            mood = next
            if next != .dig { frameIndex = 0 }
            dirty = true
        }
        if shake > 0.05 {
            shake *= 0.72
            dirty = true
        } else { shake = 0 }
        if pulse > 0.05 {
            pulse *= 0.78
            dirty = true
        } else { pulse = 0 }
        if mood == .dig || bobKick > 0.15 {
            bobPhase += CGFloat(dt) * (mood == .dig ? 52 : 28)
            if mood != .dig { bobKick *= 0.84 }
            dirty = true
        } else {
            bobKick = 0
        }
        if !motes.isEmpty {
            for i in motes.indices {
                motes[i].x += motes[i].vx * CGFloat(dt)
                motes[i].y += motes[i].vy * CGFloat(dt)
                motes[i].vx *= 0.97
                motes[i].vy -= 420 * CGFloat(dt)
                motes[i].angle += motes[i].spin * CGFloat(dt)
                motes[i].life -= CGFloat(dt) / 0.70
            }
            motes.removeAll { $0.life <= 0 }
            dirty = true
        }
        if dirty { onFrame?() }
    }
}

enum ArtBank {
    private static var didLoad = false
    private static var dig: [NSImage] = []
    private static var idle: [NSImage] = []
    static var menu: NSImage?
    static var tipX: CGFloat = 0.54
    static var tipY: CGFloat = 0.94
    static var displayWidth: CGFloat = 20
    static var gridW = 20
    static var gridH = 28

    static var ready: Bool {
        load()
        return !dig.isEmpty
    }

    static func count(_ mood: CompanionMood) -> Int {
        load()
        switch mood {
        case .dig: return max(dig.count, 1)
        case .idle, .sleep: return max(idle.count, 1)
        }
    }

    static func frame(mood: CompanionMood, index: Int) -> NSImage? {
        load()
        switch mood {
        case .dig:
            guard !dig.isEmpty else { return idle.first }
            return dig[index % dig.count]
        case .idle, .sleep:
            guard !idle.isEmpty else { return dig.first }
            return idle[index % idle.count]
        }
    }

    static func load() {
        if didLoad { return }
        didLoad = true
        let fm = FileManager.default
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("fx") {
            dirs.append(bundled)
        }
        dirs.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("assets/fx"))
        guard let dir = dirs.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("miner.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = obj["tipX"] as? Double { tipX = CGFloat(v) }
            if let v = obj["tipY"] as? Double { tipY = CGFloat(v) }
            if let v = obj["displayWidth"] as? Double { displayWidth = CGFloat(v) }
            if let v = obj["width"] as? Double { gridW = max(1, Int(v)) }
            if let v = obj["height"] as? Double { gridH = max(1, Int(v)) }
        }
        var i = 0
        while true {
            let url = dir.appendingPathComponent("miner-dig-\(i).png")
            guard let img = NSImage(contentsOf: url) else { break }
            img.isTemplate = false
            img.size = NSSize(width: gridW, height: gridH)
            dig.append(img)
            i += 1
        }
        if let idleImg = NSImage(contentsOf: dir.appendingPathComponent("miner-idle-0.png")) {
            idleImg.size = NSSize(width: gridW, height: gridH)
            idle = [idleImg]
        }
        if let menuImg = NSImage(contentsOf: dir.appendingPathComponent("miner-menu.png")) {
            menuImg.isTemplate = true
            menu = menuImg
        }
    }
}

enum SpriteBank {
    static let width = 12
    static let height = 16
    static let overlayPixel: CGFloat = 2

    static func frames(for mood: CompanionMood) -> [[String]] {
        switch mood {
        case .dig: return dig
        case .idle: return idle
        case .sleep: return sleep
        }
    }

    static func draw(mood: CompanionMood, frame: Int, in rect: NSRect, ink: NSColor) {
        let rows = frames(for: mood)
        guard !rows.isEmpty else { return }
        let grid = rows[frame % rows.count]
        let px = max(1, floor(min(rect.width / CGFloat(width), rect.height / CGFloat(height))))
        let totalW = px * CGFloat(width)
        let totalH = px * CGFloat(height)
        let ox = floor(rect.minX + (rect.width - totalW) / 2)
        let oy = floor(rect.minY + (rect.height - totalH) / 2)
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none
        ink.setFill()
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                NSRect(x: ox + CGFloat(x) * px,
                       y: oy + CGFloat(height - 1 - y) * px,
                       width: px, height: px).fill()
            }
        }
    }

    static func image(mood: CompanionMood, frame: Int, pointSize: NSSize, template: Bool) -> NSImage {
        let scale: CGFloat = 2
        let pw = max(1, Int(pointSize.width * scale))
        let ph = max(1, Int(pointSize.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: pointSize)
        }
        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        draw(mood: mood, frame: frame, in: NSRect(origin: .zero, size: pointSize),
             ink: template ? .white : NSColor.labelColor)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return NSImage(size: pointSize) }
        let img = NSImage(cgImage: cg, size: pointSize)
        img.isTemplate = template
        return img
    }

    // Front-facing 12x16: hat / body / legs, then a 2-wide drill under the
    // feet. Last rows are the bit — that tip is the ground.
    private static let body: [String] = [
        ".....##.....",
        "....####....",
        "....#..#....",
        ".....##.....",
        "....####....",
        "...##..##...",
        "...#.##.#...",
        "....#..#....",
        "....#..#....",
        "....#..#....",
        ".....##.....",
        ".....##.....",
    ]

    private static let idle: [[String]] = [
        body + [".....##.....", "......#.....", "............", "............"],
        body + [".....##.....", "......#.....", "......#.....", "............"],
    ]

    private static let sleep: [[String]] = [
        [
            "............",
            ".....##.....",
            "....####....",
            "....#..#....",
            ".....##.....",
            "....####....",
            "...##..##...",
            "....####....",
            "....#..#....",
            "............",
            ".......##...",
            "......#.#...",
            ".......##...",
            "............",
            "............",
            "............",
        ],
        [
            "............",
            ".....##.....",
            "....####....",
            "....#..#....",
            ".....##.....",
            "....####....",
            "...##..##...",
            "....####....",
            "....#..#....",
            "............",
            "........##..",
            ".......#.#..",
            "........##..",
            "............",
            "............",
            "............",
        ],
    ]

    private static let dig: [[String]] = [
        body + [".....##.....", "......#.....", "............", "............"],
        body + [".....##.....", ".....##.....", "......#.....", "............"],
        body + [".....##.....", ".....##.....", ".....##.....", "......#....."],
        body + [".....##.....", ".....##.....", "......#.....", "............"],
    ]
}

enum LCDFont {
    static let w = 5
    static let h = 7

    static func draw(_ ch: Character, at center: NSPoint, pixel: CGFloat, color: NSColor, angle: CGFloat = 0) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        let xf = NSAffineTransform()
        xf.translateX(by: floor(center.x) + 0.5, yBy: floor(center.y) + 0.5)
        if angle != 0 { xf.rotate(byRadians: angle) }
        xf.concat()
        color.setFill()
        if ch == "·" {
            NSRect(x: -pixel / 2, y: -pixel / 2, width: pixel, height: pixel).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let key = String(ch).uppercased().first ?? ch
        guard let rows = table[key] else {
            NSRect(x: -pixel / 2, y: -pixel / 2, width: pixel, height: pixel).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let ox = -CGFloat(w) * pixel / 2
        let oy = -CGFloat(h) * pixel / 2
        for (y, row) in rows.enumerated() {
            for (x, bit) in row.enumerated() where bit == "1" {
                NSRect(x: ox + CGFloat(x) * pixel,
                       y: oy + CGFloat(h - 1 - y) * pixel,
                       width: pixel, height: pixel).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let table: [Character: [String]] = [
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01110"],
        "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
        "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
        "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
        "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["01110", "10001", "00001", "00110", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["01110", "10001", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "10001", "01110"],
    ]
}


