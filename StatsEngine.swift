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

    func recordKey(code: Int) {
        today.keys += 1
        keyCounts[code, default: 0] += 1
        recentKeys.append(Date())
        pruneRecent()
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

    // MARK: - Queries

    /// Words per minute over the last 60 seconds (5 keystrokes per word).
    var wpm: Int {
        let cutoff = Date().addingTimeInterval(-60)
        recentKeys.removeAll { $0 < cutoff }
        return recentKeys.count / 5
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
        return (0..<(n - 1)).reversed().compactMap { back in
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
