import Foundation

public enum Format {
    /// "1:02:03" -> 3723
    public static func parseDuration(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var total = 0
        for part in t.split(separator: ":", omittingEmptySubsequences: false) {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
            total = total * 60 + n
        }
        return total
    }

    public static func duration(_ secs: Int) -> String {
        let s = max(0, secs)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    public static func duration(_ secs: Double) -> String {
        duration(secs.isFinite ? Int(secs) : 0)
    }

    /// Russian plural: plural(5, "видео", "видео", "видео"), plural(n, "день", "дня", "дней").
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = abs(n) % 100, b = a % 10
        if a > 10 && a < 20 { return many }
        if b == 1 { return one }
        if b >= 2 && b <= 4 { return few }
        return many
    }

    /// 1234 -> "1,2 тыс.", 3400000 -> "3,4 млн"
    public static func compact(_ n: Int) -> String {
        func f(_ v: Double, _ suffix: String) -> String {
            let s = v >= 100 ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "")
            return s.replacingOccurrences(of: ".", with: ",") + " " + suffix
        }
        switch n {
        case 1_000_000_000...: return f(Double(n) / 1e9, "млрд")
        case 1_000_000...: return f(Double(n) / 1e6, "млн")
        case 1_000...: return f(Double(n) / 1e3, "тыс.")
        default: return String(n)
        }
    }

    public static func views(_ n: Int) -> String {
        "\(compact(n)) \(plural(n, "просмотр", "просмотра", "просмотров"))"
    }

    public static func now() -> Int { Int(Date().timeIntervalSince1970) }

    /// "3 days ago", "3 дня назад", "Streamed 2 weeks ago", "Трансляция закончилась 2 недели назад" -> seconds ago.
    public static func relativeSeconds(_ s: String) -> Int? {
        let lower = s.lowercased()
        let isAgo = lower.contains("ago") || lower.contains("назад")
        guard isAgo else { return nil }
        let scanner = lower.split(whereSeparator: { !$0.isNumber && !$0.isLetter })
        var number: Int?
        var unit: Int?
        for w in scanner {
            if number == nil, let n = Int(w) { number = n; continue }
            if number != nil, let u = unitSeconds(String(w)) { unit = u; break }
        }
        if number == nil {
            // "a day ago", "день назад"
            for w in scanner { if let u = unitSeconds(String(w)) { return u } }
            return nil
        }
        guard let n = number, let u = unit else { return nil }
        return n * u
    }

    private static func unitSeconds(_ w: String) -> Int? {
        let units: [(String, Int)] = [
            ("second", 1), ("sec", 1), ("секунд", 1), ("сек", 1),
            ("minute", 60), ("min", 60), ("минут", 60), ("мин", 60),
            ("hour", 3600), ("час", 3600), ("ч", 3600),
            ("day", 86400), ("дн", 86400), ("день", 86400), ("дня", 86400),
            ("week", 604800), ("недел", 604800), ("нед", 604800),
            ("month", 2_592_000), ("месяц", 2_592_000), ("мес", 2_592_000),
            ("year", 31_536_000), ("год", 31_536_000), ("лет", 31_536_000), ("года", 31_536_000),
        ]
        for (k, v) in units where w.hasPrefix(k) { return v }
        return nil
    }

    public static func parseRelative(_ s: String) -> Int? {
        relativeSeconds(s).map { now() - $0 }
    }

    /// Russian "3 дня назад" from a unix time.
    public static func relative(from ts: Int, now: Int = Format.now()) -> String {
        let d = max(0, now - ts)
        func ago(_ n: Int, _ a: String, _ b: String, _ c: String) -> String { "\(n) \(plural(n, a, b, c)) назад" }
        switch d {
        case ..<60: return "только что"
        case ..<3600: return ago(d / 60, "минуту", "минуты", "минут")
        case ..<86400: return ago(d / 3600, "час", "часа", "часов")
        case ..<604800: return ago(d / 86400, "день", "дня", "дней")
        case ..<2_592_000: return ago(d / 604800, "неделю", "недели", "недель")
        case ..<31_536_000: return ago(d / 2_592_000, "месяц", "месяца", "месяцев")
        default: return ago(d / 31_536_000, "год", "года", "лет")
        }
    }

    /// "1.2K views", "1,2 тыс. просмотров", "12 345" -> number (approximate for short forms).
    public static func parseCount(_ s: String) -> Int? {
        let lower = s.lowercased().replacingOccurrences(of: "\u{a0}", with: " ")
        var digits = ""
        var seenDigit = false
        for ch in lower {
            if ch.isNumber { digits.append(ch); seenDigit = true }
            else if (ch == "," || ch == ".") && seenDigit { digits.append(".") }
            else if ch == " " && seenDigit { continue }
            else if seenDigit { break }
        }
        // "12.345" with a thousands separator, not a fraction
        let parts = digits.split(separator: ".")
        var value: Double
        if parts.count > 1, parts.dropFirst().allSatisfy({ $0.count == 3 }), !hasSuffixWord(lower) {
            value = Double(parts.joined()) ?? 0
        } else {
            value = Double(digits) ?? 0
        }
        guard seenDigit else { return nil }
        if lower.contains("млрд") || lower.contains("b ") || lower.hasSuffix("b") { value *= 1e9 }
        else if lower.contains("млн") || lower.contains("m ") || lower.hasSuffix("m") { value *= 1e6 }
        else if lower.contains("тыс") || lower.contains("k ") || lower.hasSuffix("k") { value *= 1e3 }
        return Int(value)
    }

    private static func hasSuffixWord(_ s: String) -> Bool {
        s.contains("тыс") || s.contains("млн") || s.contains("млрд") || s.contains("k") || s.contains("m ") || s.contains("b ")
    }

    /// "12:34" or "1:02:03" anywhere in text -> ranges and seconds (timestamps in descriptions and comments).
    public static func timestamps(in text: String) -> [(range: Range<String.Index>, seconds: Int)] {
        var out: [(Range<String.Index>, Int)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isASCII, text[i].isNumber, i == text.startIndex || !(text[text.index(before: i)].isNumber || text[text.index(before: i)] == ":") {
                var j = i
                var colons = 0
                while j < text.endIndex, text[j].isASCII, text[j].isNumber || text[j] == ":" {
                    if text[j] == ":" { colons += 1 }
                    j = text.index(after: j)
                }
                var token = String(text[i..<j])
                var end = j
                while token.hasSuffix(":") { token.removeLast(); end = text.index(before: end) }
                if colons >= 1, colons <= 2, let secs = parseDuration(token) {
                    let parts = token.split(separator: ":")
                    if parts.dropFirst().allSatisfy({ $0.count == 2 }) {
                        out.append((i..<end, secs))
                    }
                }
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }
}
