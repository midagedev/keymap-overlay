import Cocoa

// Compact 3-tone sparkline. values are 0...1, oldest first.

final class SparklineView: NSView {
    var values: [CGFloat] = [] { didSet { needsDisplay = true } }
    var lineHeight: CGFloat = 14
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        let n = max(values.count, 1)
        let slot = bounds.width / CGFloat(n)
        let ink = NSColor.labelColor
        for (i, v) in values.enumerated() {
            let h = max(v > 0 ? 1 : 0, floor(bounds.height * v))
            guard h > 0 else { continue }
            ink.withAlphaComponent(0.22 + v * 0.55).setFill()
            NSRect(x: floor(CGFloat(i) * slot), y: 0, width: max(1, floor(slot - 0.4)), height: h).fill()
        }
    }
}

final class StatsHUD: NSView {
    private let hero = NSTextField(labelWithString: "")
    private let liveCap = NSTextField(labelWithString: "최근 60초")
    let liveSpark = SparklineView()
    private let hourCap = NSTextField(labelWithString: "오늘 시간대")
    let hourSpark = SparklineView()
    private let weekCap = NSTextField(labelWithString: "최근 7일")
    let weekSpark = SparklineView()
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        liveSpark.lineHeight = 28
        hourSpark.lineHeight = 22
        weekSpark.lineHeight = 18
        hero.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        hero.textColor = .labelColor
        hero.maximumNumberOfLines = 4
        detail.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        for cap in [liveCap, hourCap, weekCap] {
            cap.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            cap.textColor = .tertiaryLabelColor
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        [hero, liveCap, liveSpark, hourCap, hourSpark, weekCap, weekSpark, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview($0)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            liveSpark.heightAnchor.constraint(equalToConstant: 28),
            hourSpark.heightAnchor.constraint(equalToConstant: 22),
            weekSpark.heightAnchor.constraint(equalToConstant: 18),
            liveSpark.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hourSpark.widthAnchor.constraint(equalTo: stack.widthAnchor),
            weekSpark.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let lv = stats.levelInfo()
        var heroLines = [
            "Vein  ·  L\(lv.level) \(lv.title)  \(lv.xpInto)/\(lv.xpNeed)",
            "\(stats.wpm) WPM  ·  최고 \(stats.sessionPeakWPM)  ·  오늘 \(stats.todayKeys)키"
        ]
        if stats.streak > 0 { heroLines.append("연속 \(stats.streak)일  ·  콤보 \(stats.maxComboToday)") }
        hero.stringValue = heroLines.joined(separator: "\n")
        liveSpark.values = stats.rateSpark(60)
        hourSpark.values = stats.hourSpark()
        weekSpark.values = stats.weekSpark()

        var lines: [String] = []
        lines.append("클릭 \(stats.todayClicks)  ·  스크롤 \(stats.todayScrolls)  ·  누적 \(stats.totalKeys)")
        lines.append("")
        lines.append("자주 쓰는 키")
        let topMax = stats.topKeys(8).first?.count ?? 1
        for (code, count) in stats.topKeys(8) {
            let label = StatsEngine.labelFor(code).padding(toLength: 6, withPad: " ", startingAt: 0)
            let bar = String(repeating: "▓", count: max(1, count * 12 / max(topMax, 1)))
            lines.append("\(label) \(bar) \(count)")
        }
        lines.append("")
        lines.append("손가락")
        let fingerTotal = max(stats.fingerCounts.map(\.count).reduce(0, +), 1)
        for (finger, count) in stats.fingerCounts {
            let pct = count * 100 / fingerTotal
            let bar = String(repeating: "▓", count: pct / 5)
            lines.append("\(finger.padding(toLength: 5, withPad: " ", startingAt: 0)) \(bar) \(pct)%")
        }
        let layerSecs = stats.todayLayerSeconds
        if !layerSecs.isEmpty {
            lines.append("")
            lines.append("레이어")
            let names = ["Base", "Sym", "Nav", "Snipe", "L4", "L5", "L6", "L7"]
            for (layer, secs) in layerSecs.sorted(by: { $0.key < $1.key }) {
                let name = layer < names.count ? names[layer] : "L\(layer)"
                lines.append("\(name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(secs / 60)분")
            }
        }
        detail.stringValue = lines.joined(separator: "\n")
    }
}
