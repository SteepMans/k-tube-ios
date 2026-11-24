import Foundation

/// The external proxy gateway (protocol in docs/gateway-protocol.md): every connection to a YouTube or Google host is
/// opened on the gateway with the user's key, and the gateway connects to the site. The same rules as the desktop K-Tube.
public enum Gateway {
    /// Hosts the gateway lets through (the same list as the gateway allows).
    public static let hosts = [
        "youtube.com", "*.youtube.com", "youtu.be", "youtube-nocookie.com", "*.youtube-nocookie.com", "*.googlevideo.com",
        "*.ytimg.com", "*.ggpht.com", "google.com", "*.google.com", "*.gstatic.com", "*.googleapis.com",
        "*.googleusercontent.com", "sponsor.ajay.app", "dearrow-thumb.ajay.app", "returnyoutubedislikeapi.com",
    ]

    /// Platform name for the gateway's statistics: "streamtube-ios/<version>".
    public static let platform = "streamtube-ios"

    public static func clientHeader(version: String) -> String { "\(platform)/\(version)" }

    public static func matches(_ host: String, _ list: [String] = hosts) -> Bool {
        let h = host.lowercased()
        return list.contains { p in
            if p.hasPrefix("*.") {
                let sfx = String(p.dropFirst(2))
                return h.count > sfx.count + 1 && h.hasSuffix("." + sfx)
            }
            return h == p
        }
    }

    public enum Route: Equatable, Sendable { case gateway, refuse }

    public static func route(_ host: String) -> Route {
        matches(host) ? .gateway : .refuse
    }

    /// Whether a key looks like a gateway key: tc_ and 43 letters or digits.
    public static func validToken(_ t: String) -> Bool {
        t.count == 46 && t.hasPrefix("tc_") && t.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// https://host from "https://host/...", "wss://host/v1/stream" or a bare host.
    public static func normalize(_ u: String) -> String? {
        var t = u.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("https://") { t = String(t.dropFirst(8)) }
        else if t.hasPrefix("wss://") { t = String(t.dropFirst(6)) }
        else if t.contains("://") { return nil }
        let host = String(t.prefix { $0 != "/" && $0 != "?" && $0 != "#" }).lowercased()
        guard !host.isEmpty, host.contains("."), !host.contains("@"), !host.contains(" ") else { return nil }
        return "https://" + host
    }

    public static func host(of url: String) -> String? {
        guard let n = normalize(url) else { return nil }
        return String(n.dropFirst(8).prefix { $0 != ":" })
    }

    /// A key link ktube://gateway?url=...&token=... (the older tgeshka://gateway form is accepted too), or a bare key.
    public static func parseInput(_ s: String) -> (url: String?, token: String?) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if validToken(t) { return (nil, t) }
        guard t.hasPrefix("tgeshka://gateway?") || t.hasPrefix("ktube://gateway?") else { return (nil, nil) }
        let q = URLCoding.query(t)
        return (q["url"].flatMap(normalize), q["token"].flatMap { validToken($0) ? $0 : nil })
    }

    /// The client header name is part of the gateway protocol and stays as the server expects it.
    public static let clientHeaderName = "X-TGeshka-Client"

    /// The upgrade request that opens host:port on the gateway.
    public static func proxyRequest(gatewayHost: String, token: String, client: String, target: String, port: Int) -> Data {
        Data(("GET /v1/proxy HTTP/1.1\r\nHost: \(gatewayHost)\r\nConnection: Upgrade\r\nUpgrade: tcp/1\r\n" +
              "Authorization: Bearer \(token)\r\n\(clientHeaderName): \(client)\r\nX-Proxy-Target: \(target):\(port)\r\n\r\n").utf8)
    }

    public struct Refusal: Error, Equatable, Sendable {
        public var status: Int
        public var text: String
        /// Worth showing to the user at once (not a single failed connection).
        public var important: Bool { [404, 407, 503].contains(status) }
    }

    /// Status of the answer head; the text the user sees for a refusal.
    public static func parseAnswer(head: String, body: String, target: String) -> Result<Void, Refusal> {
        let first = head.split(separator: "\r\n").first ?? ""
        let status = Int(first.split(separator: " ").dropFirst().first ?? "") ?? 0
        if status == 101 { return .success(()) }
        let lower = head.lowercased()
        switch status {
        case 404: return .failure(Refusal(status: 404, text: "ключ не принят шлюзом (отозван или опечатка)"))
        case 403: return .failure(Refusal(status: 403, text: "шлюз не пускает к \(target)"))
        case 429: return .failure(Refusal(status: 429, text: "слишком много соединений по ключу"))
        case 503 where lower.contains("x-proxy-error: no_leg"):
            return .failure(Refusal(status: 503, text: "выходы шлюза для YouTube сейчас недоступны, попробуйте через несколько минут"))
        case 503: return .failure(Refusal(status: 502, text: "шлюз перезапускается, повторите"))
        default:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Refusal(status: status == 0 ? 502 : status, text: "шлюз ответил \(status) \(detail)"))
        }
    }

    /// The local proxy's answer to its client for a refusal.
    public static func localStatus(_ r: Refusal) -> String {
        switch r.status {
        case 403: return "403 Forbidden"
        case 404, 407: return "407 Proxy Authentication Required"
        case 429: return "429 Too Many Requests"
        case 503: return "503 Service Unavailable"
        default: return "502 Bad Gateway"
        }
    }

    /// host and port of "CONNECT host:port" (lowercased, trailing dot dropped).
    public static func splitHostPort(_ s: String, defaultPort: Int) -> (String, Int)? {
        var h = s
        var p = defaultPort
        if let i = s.lastIndex(of: ":"), !s[..<i].contains("]") || s[..<i].hasSuffix("]") {
            guard let port = Int(s[s.index(after: i)...]) else { return nil }
            h = String(s[..<i])
            p = port
        }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : (h, p)
    }

    /// Info of the key from /v1/info.
    public struct Info: Sendable, Equatable {
        public var description: String
        public var id: Int
        public var proxy: Bool
        public var upgradeRequired: Bool
        public var rttMs: Int
    }

    public static func parseInfo(_ j: J, rttMs: Int) -> Info {
        Info(description: j["description"].string ?? "", id: j["id"].int ?? 0, proxy: j["proxy"].bool ?? false,
             upgradeRequired: j["upgrade_required"].bool ?? false, rttMs: rttMs)
    }
}
