import Foundation

// Records usage statistics: keystrokes, clicks, scrolls, layer time, per-key
// frequency. Persists as JSON under Application Support so history survives
// restarts. All recording happens on the main thread.

final class StatsEngine {
    struct DayStats: Codable {
        var keys = 0
        var clicks = 0
        var scrolls = 0
        var layerSeconds: [Int: Int] = [:]
        var hourKeys: [Int] = Array(repeating: 0, count: 24)

        enum CodingKeys: String, CodingKey {
            case keys, clicks, scrolls, layerSeconds, hourKeys
        }

        init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0,
             layerSeconds: [Int: Int] = [:], hourKeys: [Int] = Array(repeating: 0, count: 24)) {
            self.keys = keys
            self.clicks = clicks
            self.scrolls = scrolls
            self.layerSeconds = layerSeconds
            self.hourKeys = hourKeys
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keys = try c.decodeIfPresent(Int.self, forKey: .keys) ?? 0
            clicks = try c.decodeIfPresent(Int.self, forKey: .clicks) ?? 0
            scrolls = try c.decodeIfPresent(Int.self, forKey: .scrolls) ?? 0
            layerSeconds = try c.decodeIfPresent([Int: Int].self, forKey: .layerSeconds) ?? [:]
            let h = try c.decodeIfPresent([Int].self, forKey: .hourKeys) ?? []
            hourKeys = (0..<24).map { $0 < h.count ? h[$0] : 0 }
        }
    }

    private(set) var days: [String: DayStats] = [:]
    private(set) var keyCounts: [Int: Int] = [:]
    private var recentKeys: [Date] = []
    private var saveURL: URL
    private var dirty = false

    static let shared = StatsEngine()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeymapOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("stats.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let obj = try? JSONDecoder().decode([String: DayStats].self, from: data) else { return }
        days = obj
    }

    func save() {
        guard dirty else { return }
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: saveURL, options: .atomic)
            dirty = false
        }
    }

    // MARK: - Recording

    private var today: DayStats {
        get { days[todayKey()] ?? DayStats() }
        set { days[todayKey()] = newValue; dirty = true }
    }

    private func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var lastComboAt: Date?
    private(set) var combo = 0
    private(set) var maxComboToday = 0
    private(set) var sessionPeakWPM = 0

    func recordKey(code: Int) {
        var d = today
        d.keys += 1
        let hour = Calendar.current.component(.hour, from: Date())
        if d.hourKeys.count != 24 { d.hourKeys = Array(repeating: 0, count: 24) }
        d.hourKeys[hour] += 1
        today = d
        keyCounts[code, default: 0] += 1
        let now = Date()
        recentKeys.append(now)
        if let last = lastComboAt, now.timeIntervalSince(last) < 0.38 {
            combo += 1
        } else {
            combo = 1
        }
        lastComboAt = now
        if combo > maxComboToday { maxComboToday = combo }
        pruneRecent()
    }

    /// Combo decays after a short pause so the HUD can hide the counter.
    var liveCombo: Int {
        guard let last = lastComboAt, Date().timeIntervalSince(last) < 0.48 else { return 0 }
        return combo
    }

    func recordClick() { today.clicks += 1 }
    func recordScroll() { today.scrolls += 1 }

    func tickLayer(_ layer: Int) {
        var d = today
        d.layerSeconds[layer, default: 0] += 1
        today = d
    }

    private func pruneRecent() {
        let cutoff = Date().addingTimeInterval(-120)
        if recentKeys.count > 512 {
            recentKeys.removeAll { $0 < cutoff }
        }
    }

    // MARK: - Demo data (for exported screenshots; in-memory only)

    /// Seeds plausible usage data so exported images show a lived-in
    /// keyboard instead of empty counters. Never persisted.
    func seedDemo() {
        days.removeAll()
        keyCounts.removeAll()
        recentKeys.removeAll()
        combo = 0
        maxComboToday = 48
        sessionPeakWPM = 92

        // QWERTY-plausible frequency profile (macOS virtual keycodes).
        let demo: [(Int, Int)] = [
            (49, 9800), (14, 6400), (0, 5900), (17, 5500), (1, 5400), (2, 5300),
            (18, 4900), (37, 4600), (4, 4500), (15, 4300), (38, 4200), (11, 3800),
            (32, 3600), (16, 3500), (40, 3400), (31, 3200), (36, 2600), (35, 2200),
            (13, 2100), (45, 1800), (46, 1700), (9, 1600), (12, 1300), (43, 1200),
            (39, 1100), (30, 900), (33, 800), (47, 700), (44, 650), (24, 500),
            (27, 420), (51, 3900), (36 + 26, 300), (123, 950), (126, 870),
            (124, 760), (125, 690), (117, 540), (48, 1100), (53, 260),
        ]
        for (c, n) in demo { keyCounts[c] = n }

        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let weekKeys = [12800, 9400, 11100, 13200, 8700, 12400, 10600]
        for (i, keys) in weekKeys.enumerated() {
            let d = cal.date(byAdding: .day, value: -(6 - i), to: Date())!
            var ds = DayStats()
            ds.keys = keys
            ds.clicks = keys / 18
            ds.scrolls = keys / 9
            ds.layerSeconds = [0: 7 * 3600 + 240, 1: 1500, 2: 2600, 3: 420]
            ds.hourKeys = Self.demoHours(keys)
            days[f.string(from: d)] = ds
        }

        let now = Date()
        for _ in 0..<330 { recentKeys.append(now - Double.random(in: 0...60)) }
    }

    private static func demoHours(_ total: Int) -> [Int] {
        let w = [0, 0, 0, 0, 0, 0, 1, 3, 8, 10, 9, 8, 7, 9, 11, 12, 10, 8, 6, 4, 2, 1, 0, 0]
        let s = max(w.reduce(0, +), 1)
        return w.map { $0 * total / s }
    }

    // MARK: - Queries

    /// Words per minute over the last 60 seconds (5 keystrokes per word).
    var wpm: Int {
        let cutoff = Date().addingTimeInterval(-60)
        recentKeys.removeAll { $0 < cutoff }
        let value = recentKeys.count / 5
        if value > sessionPeakWPM { sessionPeakWPM = value }
        return value
    }

    static let levelTitles = [
        "견습", "채굴", "갱도", "광맥", "숙련",
        "베테랑", "마스터", "카리브디스", "베인",
    ]

    func levelInfo() -> LevelInfo {
        let xp = max(totalKeys, 0)
        var level = 0
        var consumed = 0
        while level < 99 {
            let need = 200 * (level + 1)
            if xp < consumed + need {
                let title = level < Self.levelTitles.count ? Self.levelTitles[level] : "베인"
                return LevelInfo(level: level, title: title, xpInto: xp - consumed, xpNeed: need)
            }
            consumed += need
            level += 1
        }
        return LevelInfo(level: 99, title: "베인", xpInto: 1, xpNeed: 1)
    }

    /// Per-second key intensity, oldest first. Values 0...1.
    func rateSpark(_ seconds: Int = 60) -> [CGFloat] {
        var bins = Array(repeating: 0, count: seconds)
        let now = Date()
        for t in recentKeys {
            let ago = Int(now.timeIntervalSince(t))
            if ago >= 0 && ago < seconds { bins[seconds - 1 - ago] += 1 }
        }
        let peak = max(bins.max() ?? 1, 1)
        return bins.map { CGFloat($0) / CGFloat(peak) }
    }

    /// Today's keys by hour, 0...1.
    func hourSpark() -> [CGFloat] {
        var h = today.hourKeys
        if h.count != 24 { h = Array(repeating: 0, count: 24) }
        let peak = max(h.max() ?? 1, 1)
        return h.map { CGFloat($0) / CGFloat(peak) }
    }

    /// Last 7 days, 0...1.
    func weekSpark() -> [CGFloat] {
        let vals = recentDays(7).map(\.keys)
        let peak = max(vals.max() ?? 1, 1)
        return vals.map { CGFloat($0) / CGFloat(peak) }
    }

    /// Consecutive days with at least 50 keys. Today with a thin count
    /// still keeps yesterday's streak alive until the day is over.
    var streak: Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        var offset = 0
        if (days[f.string(from: Date())]?.keys ?? 0) < 50 { offset = 1 }
        var count = 0
        var i = offset
        while i < 400 {
            let d = cal.date(byAdding: .day, value: -i, to: Date())!
            if (days[f.string(from: d)]?.keys ?? 0) < 50 { break }
            count += 1
            i += 1
        }
        return count
    }

    var todayKeys: Int { today.keys }
    var todayClicks: Int { today.clicks }
    var todayScrolls: Int { today.scrolls }
    var todayLayerSeconds: [Int: Int] { today.layerSeconds }

    var totalKeys: Int { days.values.reduce(0) { $0 + $1.keys } }

    var maxKeyCount: Int { keyCounts.values.max() ?? 0 }

    func keyCount(_ code: Int) -> Int { keyCounts[code] ?? 0 }

    /// Top keys sorted by all-time count.
    func topKeys(_ limit: Int = 10) -> [(code: Int, count: Int)] {
        keyCounts.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// Last n days of key counts, oldest first.
    func recentDays(_ n: Int = 7) -> [(day: String, keys: Int)] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        return (0..<n).reversed().compactMap { back in
            let d = cal.date(byAdding: .day, value: -back, to: Date())!
            let key = f.string(from: d)
            return (key, days[key]?.keys ?? 0)
        }
    }

    // MARK: - Finger distribution (approximate QWERTY mapping)

    static let fingerOfCode: [Int: String] = {
        var t: [Int: String] = [:]
        func put(_ names: String, _ finger: String) {
            for n in names.split(separator: " ").map(String.init) {
                if let code = reverseTable[n] { t[code] = finger }
            }
        }
        put("Q A Z TAB CAPSLOCK ESC", "왼 새끼")
        put("W S X", "왼 약지")
        put("E D C", "왼 중지")
        put("R T F G V B", "왼 검지")
        put("Y U H J N M", "오 검지")
        put("I K COMMA", "오 중지")
        put("O L DOT", "오 약지")
        put("P SEMI SLASH APOS MINUS EQUAL BACKSLASH ENTER BSPC", "오 새끼")
        put("SPACE", "엄지")
        return t
    }()

    var fingerCounts: [(finger: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (code, n) in keyCounts {
            let f = Self.fingerOfCode[code] ?? "기타"
            counts[f, default: 0] += n
        }
        let order = ["왼 새끼", "왼 약지", "왼 중지", "왼 검지", "엄지", "오 검지", "오 중지", "오 약지", "오 새끼", "기타"]
        return order.filter { counts[$0] != nil }.map { ($0, counts[$0]!) }
    }

    static func labelFor(_ code: Int) -> String {
        reverseTable.first { $0.value == code }?.key ?? "code \(code)"
    }

    private static let reverseTable: [String: Int] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "ENTER": 36,
        "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "N": 45,
        "M": 46, ".": 47, "TAB": 48, "SPACE": 49, "`": 50, "BSPC": 51, "ESC": 53,
        "CAPSLOCK": 57,
    ]
}
