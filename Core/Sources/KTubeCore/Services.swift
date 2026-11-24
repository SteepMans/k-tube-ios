import Foundation

public struct SponsorSegment: Hashable, Sendable {
    public var category: String
    public var action: String
    public var start: Double
    public var end: Double
    public var uuid: String
}

public struct SponsorCategory: Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: UInt32
}

public enum SegmentAction: String, Codable, Sendable, CaseIterable {
    case skip, ask, mark, ignore
    public var title: String {
        switch self {
        case .skip: return "Пропускать"
        case .ask: return "Спрашивать"
        case .mark: return "Только отмечать"
        case .ignore: return "Не трогать"
        }
    }
}

public struct Branding: Hashable, Sendable {
    public var title: String?
    public var thumbnailTime: Double?
}

public struct Votes: Hashable, Sendable {
    public var likes: Int
    public var dislikes: Int
    public var views: Int
    public var rating: Double
}

public struct SBUserInfo: Hashable, Sendable {
    public var userName: String
    public var segments: Int
    public var views: Int
    public var minutesSaved: Double
    public var reputation: Double
}

/// SponsorBlock, DeArrow, Return YouTube Dislike and channel RSS (all of them reached through the gateway).
public final class Services: @unchecked Sendable {
    public static let categories: [SponsorCategory] = [
        SponsorCategory(id: "sponsor", name: "Реклама спонсора", color: 0x00d400),
        SponsorCategory(id: "selfpromo", name: "Самореклама", color: 0xffff00),
        SponsorCategory(id: "interaction", name: "Просьба подписаться", color: 0xcc00ff),
        SponsorCategory(id: "intro", name: "Заставка", color: 0x00ffff),
        SponsorCategory(id: "outro", name: "Концовка и титры", color: 0x0202ed),
        SponsorCategory(id: "preview", name: "Анонс и повтор", color: 0x008fd6),
        SponsorCategory(id: "hook", name: "Приветствие", color: 0x395699),
        SponsorCategory(id: "music_offtopic", name: "Музыка: не по теме", color: 0xff9900),
        SponsorCategory(id: "filler", name: "Отступление", color: 0x7300ff),
        SponsorCategory(id: "poi_highlight", name: "Главный момент", color: 0xff1684),
        SponsorCategory(id: "exclusive_access", name: "Эксклюзивный доступ", color: 0x008a5c),
    ]

    public static func category(_ id: String) -> SponsorCategory {
        categories.first { $0.id == id } ?? SponsorCategory(id: id, name: id, color: 0xaaaaaa)
    }

    let http: HTTPClient
    private let branding = Locked<[String: Branding?]>([:])

    public init(http: HTTPClient) { self.http = http }

    public static func shaPrefix(_ id: String) -> String {
        String(SHA256.hex(Data(id.utf8)).prefix(4))
    }

    public func segments(_ videoId: String, server: String, categories: [String]) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        let cats = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let url = "\(server.trimmingSuffix("/"))/api/skipSegments/\(Services.shaPrefix(videoId))?categories=\(URLCoding.encode(cats))&actionTypes=%5B%22skip%22,%22mute%22,%22poi%22,%22full%22%5D"
        let r = try await http.get(url)
        if r.status == 404 { return [] }
        guard r.status < 400 else { throw KTubeError("SponsorBlock: HTTP \(r.status)") }
        return Services.parseSegments(r.json, videoId: videoId)
    }

    public static func parseSegments(_ j: J, videoId: String) -> [SponsorSegment] {
        var out: [SponsorSegment] = []
        for entry in j.array where entry["videoID"].string == videoId {
            for seg in entry["segments"].array {
                guard let a = seg["segment"][0].double, let b = seg["segment"][1].double else { continue }
                out.append(SponsorSegment(category: seg["category"].string ?? "", action: seg["actionType"].string ?? "skip", start: a, end: b, uuid: seg["UUID"].string ?? ""))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    public func viewed(server: String, uuid: String) async {
        _ = try? await http.send(HTTPRequest(url: "\(server.trimmingSuffix("/"))/api/viewedVideoSponsorTime?UUID=\(URLCoding.encode(uuid))", method: "POST"))
    }

    public func vote(server: String, uuid: String, userId: String, up: Bool) async throws {
        let r = try await http.send(HTTPRequest(url: "\(server.trimmingSuffix("/"))/api/voteOnSponsorTime?UUID=\(URLCoding.encode(uuid))&userID=\(URLCoding.encode(userId))&type=\(up ? 1 : 0)", method: "POST"))
        guard r.status < 400 else { throw KTubeError("SponsorBlock ответил \(r.status)") }
    }

    public func userInfo(server: String, privateId: String) async throws -> SBUserInfo {
        let r = try await http.get("\(server.trimmingSuffix("/"))/api/userInfo?userID=\(URLCoding.encode(privateId))")
        if r.status == 404 { return SBUserInfo(userName: "", segments: 0, views: 0, minutesSaved: 0, reputation: 0) }
        guard r.status < 400 else { throw KTubeError("SponsorBlock ответил \(r.status)") }
        let v = r.json
        let name = v["userName"].string ?? ""
        return SBUserInfo(userName: name == v["userID"].string ? "" : name, segments: v["segmentCount"].int ?? 0, views: v["viewCount"].int ?? 0,
                          minutesSaved: v["minutesSaved"].double ?? 0, reputation: v["reputation"].double ?? 0)
    }

    public static func newUserId() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<36).map { _ in chars.randomElement()! })
    }

    public func cachedBranding(_ id: String) -> Branding?? {
        branding.with { $0[id] }
    }

    public func dearrow(_ videoId: String) async -> Branding? {
        if let b = cachedBranding(videoId) { return b }
        var res: Branding?
        if let r = try? await http.getOK("https://sponsor.ajay.app/api/branding/\(Services.shaPrefix(videoId))") {
            res = Services.parseBranding(r.json, videoId: videoId)
        }
        branding.with { b in
            if b.count > 4000 { b.removeAll() }
            b[videoId] = .some(res)
        }
        return res
    }

    public static func parseBranding(_ j: J, videoId: String) -> Branding? {
        let e = j[videoId]
        guard !e.isNull else { return nil }
        let title = e["titles"].array.first {
            !($0["original"].bool ?? false) && (($0["locked"].bool ?? false) || ($0["votes"].int ?? 0) >= 0)
        }?["title"].string.map { $0.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) }
        let time = e["thumbnails"].array.first { !($0["original"].bool ?? false) }?["timestamp"].double
        if title == nil && time == nil { return nil }
        return Branding(title: title, thumbnailTime: time)
    }

    public static func dearrowThumbnail(_ videoId: String, time: Double) -> String {
        "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoId)&time=\(time)"
    }

    public func votes(_ videoId: String) async throws -> Votes {
        let v = try await http.getOK("https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)").json
        return Votes(likes: v["likes"].int ?? 0, dislikes: v["dislikes"].int ?? 0, views: v["viewCount"].int ?? 0, rating: v["rating"].double ?? 0)
    }

    /// A channel's latest uploads from its RSS feed (fast and light, 15 items).
    public func channelRSS(_ channelId: String) async throws -> (String, [VideoItem]) {
        let xml = try await http.getOK("https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)").text
        return Services.parseRSS(xml, channelId: channelId)
    }

    public static func parseRSS(_ xml: String, channelId: String) -> (String, [VideoItem]) {
        func tag(_ s: Substring, _ t: String) -> String? {
            guard let start = s.range(of: "<\(t)") else { return nil }
            let after = s[start.lowerBound...]
            guard let openEnd = after.firstIndex(of: ">"), let close = after.range(of: "</\(t)>") else { return nil }
            return unescape(String(after[after.index(after: openEnd)..<close.lowerBound]))
        }
        func attr(_ s: Substring, _ t: String, _ a: String) -> String? {
            guard let start = s.range(of: "<\(t) ") else { return nil }
            let after = s[start.lowerBound...]
            guard let end = after.firstIndex(of: ">") else { return nil }
            let el = after[..<end]
            guard let p = el.range(of: "\(a)=\"") else { return nil }
            let rest = el[p.upperBound...]
            guard let q = rest.firstIndex(of: "\"") else { return nil }
            return unescape(String(rest[..<q]))
        }
        let parts = xml.components(separatedBy: "<entry>")
        let name = parts.first.flatMap { tag(Substring($0), "title") } ?? ""
        var out: [VideoItem] = []
        for entry in parts.dropFirst() {
            let e = Substring(entry)
            guard let id = tag(e, "yt:videoId") else { continue }
            var v = VideoItem(id: id, title: tag(e, "title") ?? "", thumbnail: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg", channelName: name, channelId: channelId)
            if let p = tag(e, "published"), let ts = parseISO8601(p) {
                v.publishedTs = ts
                v.publishedText = Format.relative(from: ts)
            }
            if let views = attr(e, "media:statistics", "views").flatMap(Int.init) { v.viewsText = Format.views(views) }
            v.isShort = (attr(e, "link", "href") ?? "").contains("/shorts/")
            out.append(v)
        }
        return (name, out)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// "2024-01-02T03:04:05+00:00" -> unix seconds
    public static func parseISO8601(_ s: String) -> Int? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s).map { Int($0.timeIntervalSince1970) }
    }
}

extension String {
    func trimmingSuffix(_ s: String) -> String {
        var t = self
        while t.hasSuffix(s) { t.removeLast(s.count) }
        return t
    }
}

/// SHA-256 (Foundation only, so the package builds and tests on Linux too).
public enum SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }
}
