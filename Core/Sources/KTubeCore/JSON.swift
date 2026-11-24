import Foundation

/// A read-only view of a value parsed by JSONSerialization: Innertube answers are deep and change often, so they are
/// read by path instead of decoded into fixed types. Every access is optional; a missing key gives an empty J.
public struct J: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public static func parse(_ data: Data) -> J {
        J(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parse(_ text: String) -> J { parse(Data(text.utf8)) }

    public var isNull: Bool { raw == nil || raw is NSNull }
    public var object: [String: Any]? { raw as? [String: Any] }
    public var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    public var isArray: Bool { raw is [Any] }

    public subscript(key: String) -> J { J(object?[key]) }
    public subscript(index: Int) -> J {
        guard let a = raw as? [Any], index >= 0, index < a.count else { return J(nil) }
        return J(a[index])
    }

    /// "/a/0/b" like a JSON pointer.
    public func at(_ path: String) -> J {
        var cur = self
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if let i = Int(part), cur.isArray {
                cur = cur[i]
            } else {
                cur = cur[String(part)]
            }
            if cur.isNull { return J(nil) }
        }
        return cur
    }

    public var string: String? {
        if let s = raw as? String { return s }
        return nil
    }

    public var double: Double? {
        if let s = raw as? String { return Double(s) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    public var int: Int? {
        if let s = raw as? String { return Int(s) }
        if let n = raw as? NSNumber { return n.intValue }
        if let i = raw as? Int { return i }
        return nil
    }

    public var bool: Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return nil
    }

    /// Keys sorted: walks are deterministic (the desktop client walks sorted maps too).
    public var entries: [(String, J)] {
        guard let o = object else { return [] }
        return o.keys.sorted().map { ($0, J(o[$0])) }
    }

    /// Text from {simpleText}, {runs:[{text}]}, {content} or a plain string.
    public var text: String {
        if let s = string { return s }
        if let s = self["simpleText"].string { return s }
        if self["runs"].isArray { return self["runs"].array.compactMap { $0["text"].string }.joined() }
        if let s = self["content"].string { return s }
        return ""
    }

    public var optText: String? {
        let t = text
        return t.isEmpty ? nil : t
    }

    /// Depth-first search for the first value under `key`.
    public func find(_ key: String) -> J? {
        if let o = object {
            if let x = o[key] { return J(x) }
            for (_, c) in entries {
                if let f = c.find(key) { return f }
            }
            return nil
        }
        if let a = raw as? [Any] {
            for c in a {
                if let f = J(c).find(key) { return f }
            }
        }
        return nil
    }

    /// Every value under `key` (not looking inside a match).
    public func findAll(_ key: String) -> [J] {
        var out: [J] = []
        findAll(key, into: &out)
        return out
    }

    private func findAll(_ key: String, into out: inout [J]) {
        if object != nil {
            for (k, c) in entries {
                if k == key { out.append(c) } else { c.findAll(key, into: &out) }
            }
        } else if let a = raw as? [Any] {
            for c in a { J(c).findAll(key, into: &out) }
        }
    }

    public var serialized: String {
        guard let r = raw, JSONSerialization.isValidJSONObject(r),
              let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

enum JSONBody {
    static func data(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }
}
