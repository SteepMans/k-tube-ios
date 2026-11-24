import Foundation

public struct Cue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

public enum WebVTT {
    /// "00:01:02.345" or "01:02.345" -> seconds
    static func time(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Cues of a WebVTT file, tags stripped. Auto captions repeat the previous line in each cue: kept as is, the
    /// overlay shows the cue text the way YouTube does.
    public static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: true)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let t = lines[ti]
            let ends = t.components(separatedBy: "-->")
            guard ends.count == 2,
                  let s = time(Substring(ends[0].trimmingCharacters(in: .whitespaces))),
                  let e = time(Substring(ends[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { continue }
            let body = lines[(ti + 1)...].map { stripTags(String($0)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: s, end: e, text: body.joined(separator: "\n")))
        }
        // auto captions: a cue of 10 ms that repeats the line, drop it
        return cues.filter { $0.end - $0.start > 0.02 }
    }

    static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// The text at time t.
    public static func text(at t: Double, in cues: [Cue]) -> String? {
        // binary search for the last cue starting at or before t
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        var i = found
        // overlapping cues: show the latest one that covers t
        while i >= 0 && i > found - 4 {
            if cues[i].end > t { return cues[i].text }
            i -= 1
        }
        return nil
    }
}
