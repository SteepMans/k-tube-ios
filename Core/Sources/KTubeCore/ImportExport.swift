import Foundation

/// Import from YouTube Takeout, NewPipe, FreeTube and OPML; export to NewPipe JSON, YouTube CSV, OPML and a full backup.
public enum ImportExport {
    public struct Result: Sendable {
        public var subscriptions: [ChannelItem] = []
        public var history: [HistoryEntry] = []
        public var library: Library?
        public var settings: AppSettings?
        public var format: String = ""
    }

    /// Recognizes the file by its content.
    public static func parse(_ data: Data, fileName: String = "") throws -> Result {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fileName.lowercased()
        if trimmed.hasPrefix("<") { return Result(subscriptions: opml(text), format: "OPML") }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let j = J.parse(data)
            if !j["ktube"].isNull {
                return try backup(data)
            }
            if j["subscriptions"].isArray {
                return Result(subscriptions: newPipe(j), format: "NewPipe")
            }
            if j.isArray, j[0]["titleUrl"].string != nil || j[0]["header"].string != nil {
                return Result(history: takeoutHistory(j), format: "YouTube Takeout (история)")
            }
            if j.isArray, j[0].at("/snippet/resourceId/channelId").string != nil {
                return Result(subscriptions: j.array.compactMap { e in
                    e.at("/snippet/resourceId/channelId").string.map { ChannelItem(id: $0, name: e.at("/snippet/title").string ?? "") }
                }, format: "YouTube Takeout (подписки)")
            }
        }
        // FreeTube profiles: one JSON object per line with "subscriptions"
        if trimmed.contains("\"subscriptions\""), trimmed.contains("\n") || name.hasSuffix(".db") {
            var subs: [ChannelItem] = []
            for line in trimmed.split(separator: "\n") {
                let j = J.parse(String(line))
                for s in j["subscriptions"].array {
                    if let id = s["id"].string { subs.append(ChannelItem(id: id, name: s["name"].string ?? "", avatar: s["thumbnail"].string)) }
                }
            }
            if !subs.isEmpty { return Result(subscriptions: unique(subs), format: "FreeTube") }
        }
        if name.hasSuffix(".csv") || trimmed.lowercased().hasPrefix("channel id") || trimmed.contains("youtube.com/channel/") {
            let subs = csv(text)
            if !subs.isEmpty { return Result(subscriptions: subs, format: "YouTube CSV") }
        }
        throw KTubeError("Формат файла не распознан")
    }

    static func unique(_ c: [ChannelItem]) -> [ChannelItem] {
        var seen = Set<String>()
        return c.filter { seen.insert($0.id).inserted }
    }

    static func channelId(fromURL u: String) -> String? {
        if let r = u.range(of: "channel_id=") { return String(u[r.upperBound...].prefix { $0 != "&" && $0 != "\"" }) }
        if let r = u.range(of: "/channel/") { return String(u[r.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "\"" }) }
        return nil
    }

    public static func opml(_ text: String) -> [ChannelItem] {
        var out: [ChannelItem] = []
        for part in text.components(separatedBy: "<outline").dropFirst() {
            let el = part.prefix { $0 != ">" }
            func attr(_ a: String) -> String? {
                guard let r = el.range(of: " \(a)=\"") ?? el.range(of: "\(a)=\"") else { return nil }
                return Services.unescape(String(el[r.upperBound...].prefix { $0 != "\"" }))
            }
            guard let url = attr("xmlUrl"), let id = channelId(fromURL: url) else { continue }
            out.append(ChannelItem(id: id, name: attr("title") ?? attr("text") ?? ""))
        }
        return unique(out)
    }

    public static func newPipe(_ j: J) -> [ChannelItem] {
        unique(j["subscriptions"].array.compactMap { s in
            guard (s["service_id"].int ?? 0) == 0, let url = s["url"].string, let id = channelId(fromURL: url) else { return nil }
            return ChannelItem(id: id, name: s["name"].string ?? "")
        })
    }

    public static func csv(_ text: String) -> [ChannelItem] {
        var out: [ChannelItem] = []
        for line in text.components(separatedBy: .newlines) {
            let cols = splitCSV(line)
            guard let first = cols.first, first.hasPrefix("UC"), first.count == 24 else { continue }
            out.append(ChannelItem(id: first, name: cols.count > 2 ? cols[2] : ""))
        }
        return unique(out)
    }

    static func splitCSV(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var it = line.makeIterator()
        while let ch = it.next() {
            if ch == "\"" {
                if quoted, let n = it.next() {
                    if n == "\"" { cur.append("\"") } else if n == "," { quoted = false; out.append(cur); cur = "" } else { quoted = false; cur.append(n) }
                } else { quoted.toggle() }
            } else if ch == ",", !quoted {
                out.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func takeoutHistory(_ j: J) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        var seen = Set<String>()
        for e in j.array {
            guard let url = e["titleUrl"].string, case .video(let id, _)? = Innertube.parseYouTubeURL(url), seen.insert(id).inserted else { continue }
            var title = e["title"].string ?? ""
            for prefix in ["Watched ", "Вы смотрели видео ", "Просмотрено: "] where title.hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)) }
            let ch = e["subtitles"][0]
            var v = VideoItem(id: id, title: title, channelName: ch["name"].string ?? "", channelId: ch["url"].string.flatMap(channelId(fromURL:)))
            v.thumbnail = Thumbs.video(id)
            let ts = e["time"].string.flatMap(Services.parseISO8601) ?? 0
            out.append(HistoryEntry(video: v, watchedAt: ts))
        }
        return out
    }

    // MARK: export

    public static func exportNewPipe(_ subs: [Subscription]) -> Data {
        let list: [[String: Any]] = subs.map { ["service_id": 0, "url": "https://www.youtube.com/channel/\($0.channel.id)", "name": $0.channel.name] }
        return (try? JSONSerialization.data(withJSONObject: ["app_version": "0.27.0", "app_version_int": 999, "subscriptions": list], options: [.prettyPrinted])) ?? Data()
    }

    public static func exportOPML(_ subs: [Subscription]) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"1.1\">\n<head><title>K-Tube</title></head>\n<body>\n<outline text=\"YouTube Subscriptions\" title=\"YouTube Subscriptions\">\n"
        for sub in subs {
            let n = esc(sub.channel.name)
            s += "<outline text=\"\(n)\" title=\"\(n)\" type=\"rss\" xmlUrl=\"https://www.youtube.com/feeds/videos.xml?channel_id=\(sub.channel.id)\"/>\n"
        }
        s += "</outline>\n</body>\n</opml>\n"
        return Data(s.utf8)
    }

    public static func exportCSV(_ subs: [Subscription]) -> Data {
        var s = "Channel Id,Channel Url,Channel Title\n"
        for sub in subs {
            let name = sub.channel.name.contains(",") || sub.channel.name.contains("\"") ? "\"\(sub.channel.name.replacingOccurrences(of: "\"", with: "\"\""))\"" : sub.channel.name
            s += "\(sub.channel.id),http://www.youtube.com/channel/\(sub.channel.id),\(name)\n"
        }
        return Data(s.utf8)
    }

    struct Backup: Codable {
        var ktube: Int
        var library: Library
        var settings: AppSettings
    }

    public static func exportBackup(library: Library, settings: AppSettings) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(Backup(ktube: 1, library: library, settings: settings))) ?? Data()
    }

    static func backup(_ data: Data) throws -> Result {
        let b = try JSONDecoder().decode(Backup.self, from: data)
        return Result(library: b.library, settings: b.settings, format: "резервная копия K-Tube")
    }
}

/// "For you": related videos of what was watched and results of recent searches, interleaved two at a time.
public enum Recommend {
    /// The seeds: the latest long videos of different channels, then a couple of older ones.
    public static func seeds(_ history: [HistoryEntry], recent: Int = 6, older: Int = 2) -> [String] {
        var channels = Set<String>()
        let longs = history.map(\.video).filter { !$0.isShort }.filter { channels.insert($0.channelId ?? $0.channelName).inserted }
        var out = longs.prefix(recent).map(\.id)
        out += longs.dropFirst(recent).shuffled().prefix(older).map(\.id)
        return out
    }

    public static func interleave(_ lists: [[VideoItem]], exclude: Set<String>, step: Int = 2) -> [VideoItem] {
        var seen = exclude
        var out: [VideoItem] = []
        var idx = Array(repeating: 0, count: lists.count)
        var any = true
        while any {
            any = false
            for (n, l) in lists.enumerated() {
                for _ in 0..<step where idx[n] < l.count {
                    any = true
                    let v = l[idx[n]]
                    idx[n] += 1
                    if seen.insert(v.id).inserted { out.append(v) }
                }
            }
        }
        return out
    }
}
