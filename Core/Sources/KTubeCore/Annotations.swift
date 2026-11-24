import Foundation

/// Video annotations (the notes, speech bubbles and clickable boxes YouTube removed in 2019) from the public archive
/// of the Annotations Restored project, like the desktop K-Tube. Positions and sizes are percents of the picture,
/// text size is a percent of its height.
public struct Annotation: Hashable, Sendable {
    public enum Kind: Sendable { case note, highlight }
    public enum Action: Hashable, Sendable {
        case seek(Double)
        case youtube(String)
        case web(String)
    }

    public var id: String
    public var kind: Kind
    public var style: String
    public var text: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var start: Double
    public var end: Double
    public var bg: Int
    public var bgAlpha: Double
    public var fg: Int
    public var textSize: Double
    public var action: Action?
    /// Text shown only for its highlight (the highlight's id)
    public var rolloverOf: String?

    public func visible(at t: Double) -> Bool { rolloverOf == nil && t >= start && t < end }
}

public enum Annotations {
    static let archive = "https://storage.googleapis.com/biggest_bucket/annotations"

    public static func url(for id: String) -> String {
        let first = String(id.prefix(1))
        // ids that start with "-" live in a differently named folder
        let dir = first == "-" ? "-/ar-" : first
        return "\(archive)/\(dir)/\(id.prefix(3))/\(id).xml.gz"
    }

    /// The archived annotations of a video; empty when it never had any.
    public static func fetch(_ id: String, http: HTTPClient) async throws -> [Annotation] {
        guard id.count == 11 else { return [] }
        // served with Content-Encoding: gzip, which URLSession decodes
        let r = try await http.get(url(for: id))
        if r.status == 404 || r.status == 403 { return [] }
        guard r.status < 400 else { throw KTubeError("HTTP \(r.status)") }
        return parse(r.text, videoId: id)
    }

    // MARK: a small XML reader for the machine-written files

    final class Node {
        var name = ""
        var attrs: [(String, String)] = []
        var children: [Node] = []
        var text = ""
        func attr(_ k: String) -> String? { attrs.first { $0.0 == k }?.1 }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func find(_ n: String) -> Node? {
            for c in children {
                if c.name == n { return c }
                if let f = c.find(n) { return f }
            }
            return nil
        }
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let i = rest.firstIndex(of: "&") {
            out += rest[..<i]
            rest = rest[i...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) <= 10 else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            let ent = String(rest[rest.index(after: rest.startIndex)..<semi])
            var ch: Character?
            switch ent {
            case "amp": ch = "&"
            case "lt": ch = "<"
            case "gt": ch = ">"
            case "quot": ch = "\""
            case "apos": ch = "'"
            default:
                if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                    ch = UInt32(ent.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
                } else if ent.hasPrefix("#") {
                    ch = UInt32(ent.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init)
                }
            }
            if let ch {
                out.append(ch)
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest.dropFirst()
            }
        }
        out += rest
        return out
    }

    static func parseXML(_ s: String) -> Node {
        let root = Node()
        var stack: [Node] = [root]
        let b = Array(s.utf8)
        func str(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<min(to, b.count)], as: UTF8.self) }
        func index(of pat: String, from: Int) -> Int? {
            let p = Array(pat.utf8)
            guard !p.isEmpty, from <= b.count - p.count else { return nil }
            var i = from
            while i <= b.count - p.count {
                if b[i] == p[0] && Array(b[i..<i + p.count]) == p { return i }
                i += 1
            }
            return nil
        }
        func starts(_ pat: String, at i: Int) -> Bool {
            let p = Array(pat.utf8)
            return i + p.count <= b.count && Array(b[i..<i + p.count]) == p
        }
        var i = 0
        while i < b.count {
            if b[i] != UInt8(ascii: "<") {
                let end = index(of: "<", from: i) ?? b.count
                stack.last!.text += unescape(str(i, end))
                i = end
                continue
            }
            if starts("<!--", at: i) { i = (index(of: "-->", from: i).map { $0 + 3 }) ?? b.count; continue }
            if starts("<![CDATA[", at: i) {
                let end = index(of: "]]>", from: i) ?? b.count
                stack.last!.text += str(i + 9, end)
                i = min(end + 3, b.count)
                continue
            }
            if starts("<?", at: i) || starts("<!", at: i) { i = (index(of: ">", from: i).map { $0 + 1 }) ?? b.count; continue }
            // the end of the tag, skipping '>' inside quoted values
            var j = i + 1
            var quote: UInt8?
            while j < b.count {
                let c = b[j]
                if let q = quote { if c == q { quote = nil } } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { quote = c } else if c == UInt8(ascii: ">") { break }
                j += 1
            }
            var tag = str(i + 1, j)
            i = j + 1
            if tag.hasPrefix("/") {
                let name = tag.dropFirst().trimmingCharacters(in: .whitespaces)
                if stack.dropFirst().contains(where: { $0.name == name }) {
                    while stack.count > 1 {
                        let n = stack.removeLast()
                        stack.last!.children.append(n)
                        if n.name == name { break }
                    }
                }
                continue
            }
            let selfClosing = tag.hasSuffix("/")
            if selfClosing { tag.removeLast() }
            let node = Node()
            let nameEnd = tag.firstIndex(where: { $0.isWhitespace }) ?? tag.endIndex
            node.name = String(tag[..<nameEnd])
            var a = tag[nameEnd...]
            while true {
                a = a.drop(while: { $0.isWhitespace })
                guard let eq = a.firstIndex(of: "=") else { break }
                let key = a[..<eq].trimmingCharacters(in: .whitespaces)
                var v = a[a.index(after: eq)...].drop(while: { $0.isWhitespace })
                guard let q = v.first, q == "\"" || q == "'" else { break }
                v = v.dropFirst()
                guard let close = v.firstIndex(of: q) else { break }
                node.attrs.append((key, unescape(String(v[..<close]))))
                a = v[v.index(after: close)...]
            }
            if selfClosing { stack.last!.children.append(node) } else { stack.append(node) }
        }
        while stack.count > 1 {
            let n = stack.removeLast()
            stack.last!.children.append(n)
        }
        return root
    }

    /// "1:02:03.5", "2:03.5", "3.5" in seconds; nil for "never".
    static func parseTime(_ t: String) -> Double? {
        if t.isEmpty || t == "never" { return nil }
        var total = 0.0
        for part in t.split(separator: ":", omittingEmptySubsequences: false) {
            guard let n = Double(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    /// "#t=1m30s", "t=90" in seconds.
    static func urlTime(_ url: String) -> Double? {
        guard let t = url.split(whereSeparator: { "#&?".contains($0) }).first(where: { $0.hasPrefix("t=") })?.dropFirst(2) else { return nil }
        if let s = Double(t.hasSuffix("s") ? t.dropLast() : t) { return s }
        var total = 0.0
        var num = ""
        for c in t {
            if c.isNumber || c == "." { num.append(c); continue }
            guard let n = Double(num), "hms".contains(c) else { return nil }
            num = ""
            total += n * (c == "h" ? 3600 : c == "m" ? 60 : 1)
        }
        return total
    }

    static func action(_ raw: String, videoId: String) -> Annotation.Action? {
        var url = raw.trimmingCharacters(in: .whitespaces)
        if url.isEmpty { return nil }
        if url.hasPrefix("//") { url = "https:" + url } else if url.hasPrefix("/") { url = "https://www.youtube.com" + url }
        if url.contains("youtube.com/redirect"),
           let q = url.split(whereSeparator: { $0 == "?" || $0 == "&" }).first(where: { $0.hasPrefix("q=") }) {
            return .web(URLCoding.decode(String(q.dropFirst(2))))
        }
        let host = (url.components(separatedBy: "://").dropFirst().first ?? "").split(whereSeparator: { "/?#".contains($0) }).first.map { $0.lowercased() } ?? ""
        let youtube = host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
        if !youtube { return .web(url) }
        let target = url.split(whereSeparator: { "?&#".contains($0) }).first(where: { $0.hasPrefix("v=") }).map { String($0.dropFirst(2)) }
        if target == videoId || (target == nil && url.contains("youtu.be/\(videoId)")) {
            return .seek(urlTime(url) ?? 0)
        }
        return .youtube(url)
    }

    static func color(_ v: String?, _ def: Int) -> Int {
        v.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }.map { Int($0 & 0xFFFFFF) } ?? def
    }

    static func annotation(_ n: Node, videoId: String) -> Annotation? {
        let kind: Annotation.Kind
        switch n.attr("type") {
        case "text": kind = .note
        case "highlight": kind = .highlight
        default: return nil // pauses, cards, branding and promotions aren't drawn
        }
        let style = n.attr("style") ?? ""
        guard let segment = n.find("segment"), let region = segment.find("movingRegion") else { return nil }
        let rtype = region.attr("type") ?? "rect"
        let regions = region.children.filter { $0.name == "\(rtype)Region" || $0.name.hasSuffix("Region") }
        guard let first = regions.first, let last = regions.last else { return nil }
        func num(_ k: String) -> Double? { first.attr(k).flatMap(Double.init) }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return nil }
        let rollover = style == "highlightText" ? segment.attr("spaceRelative") : nil
        var start = 0.0, end = 0.0
        if let s = parseTime(first.attr("t") ?? ""), let e = parseTime(last.attr("t") ?? "") {
            start = s
            end = max(e, s)
        } else if rollover == nil {
            return nil
        }
        let app = n.child("appearance")
        func a(_ k: String) -> String? { app?.attr(k) }
        let text = n.find("TEXT").map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r")) } ?? ""
        let act = n.children.first { $0.name == "action" && $0.attr("type") == "openUrl" }?.child("url")?.attr("value").flatMap { action($0, videoId: videoId) }
        let defaults: (Int, Double, Int)
        switch (kind, style) {
        case (.highlight, _): defaults = (0x857F85, 0.25, 0xFFFFFF)
        case (_, "highlightText"), (_, "title"): defaults = (0x000000, 0, 0xFFFFFF)
        default: defaults = (0xFFFFFF, 0.8, 0x000000)
        }
        let fgKey = style == "highlightText" ? "highlightFontColor" : "fgColor"
        let alpha = (a("bgAlpha") ?? (style.isEmpty ? a("borderAlpha") : nil)).flatMap(Double.init) ?? defaults.1
        let size = a("textSize").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 3.15
        return Annotation(id: n.attr("id") ?? "", kind: kind, style: style, text: text, x: x, y: y, w: w, h: h, start: start, end: end,
                          bg: color(a("bgColor"), defaults.0), bgAlpha: alpha, fg: color(a(fgKey) ?? a("fgColor"), defaults.2),
                          textSize: size, action: act, rolloverOf: rollover)
    }

    /// The annotations of a file, in drawing order.
    public static func parse(_ xml: String, videoId: String) -> [Annotation] {
        guard let list = parseXML(xml).find("annotations") else { return [] }
        var out = list.children.filter { $0.name == "annotation" }.compactMap { annotation($0, videoId: videoId) }
            // empty notes that do nothing are leftovers of YouTube's editor
            .filter { $0.kind == .highlight || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.action != nil }
        // rollover text is placed relative to its highlight
        let highlights = out.filter { $0.kind == .highlight }.map { ($0.id, $0.x, $0.y) }
        out = out.compactMap { a in
            guard let parent = a.rolloverOf else { return a }
            guard let h = highlights.first(where: { $0.0 == parent }) else { return nil }
            var b = a
            b.x += h.1
            b.y += h.2
            return b
        }
        return out
    }
}
