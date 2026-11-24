import Foundation

/// Playback streams: the visionOS and iOS Innertube clients hand out an HLS master playlist that needs neither a PO
/// token nor solving YouTube's JS challenges (the desktop client does the same). AVPlayer plays HLS natively.
public final class Streams: @unchecked Sendable {
    static let visionVersion = "1.02"
    static let visionUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let iosVersion = "20.10.4"
    static let iosUA = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    public enum Client: String, Sendable, CaseIterable, Codable {
        case auto, visionos, ios
        public var title: String {
            switch self {
            case .auto: return "Автоматически"
            case .visionos: return "visionOS"
            case .ios: return "iOS"
            }
        }
    }

    let innertube: Innertube
    private let visitor = Locked<(String, Date)?>(nil)
    /// The visitor id that last got the iOS client an HLS manifest (some visitors are in a SABR-only experiment).
    private let iosVisitor = Locked("")
    private let cache = Locked<[String: (StreamInfo, Date)]>([:])

    public init(innertube: Innertube) {
        self.innertube = innertube
    }

    var http: HTTPClient { innertube.http }

    public func invalidate(_ id: String) {
        cache.with { $0[id] = nil }
    }

    public func clearCache() {
        cache.with { $0.removeAll() }
    }

    /// Streams of a video: visionOS first, then iOS (videos made for kids), cached for 2 hours (the URLs expire later).
    public func resolve(_ id: String, client: Client = .auto) async throws -> StreamInfo {
        if let (info, at) = cache.with({ $0[id] }), Date().timeIntervalSince(at) < 2 * 3600 {
            return info
        }
        let info: StreamInfo
        switch client {
        case .ios:
            info = try await ios(id)
        case .visionos:
            do { info = try await visionos(id) } catch let e1 {
                do { info = try await ios(id) } catch let e2 { throw KTubeError("\(e1.localizedDescription)\n\(e2.localizedDescription)") }
            }
        case .auto:
            do { info = try await visionos(id) } catch let e1 {
                do { info = try await ios(id) } catch let e2 { throw KTubeError(Streams.friendly(e1, e2)) }
            }
        }
        cache.with { $0[id] = (info, Date()) }
        return info
    }

    static func friendly(_ e1: Error, _ e2: Error) -> String {
        let a = e1.localizedDescription, b = e2.localizedDescription
        // YouTube's own reason first (age, private, removed): it is the same for both clients
        for m in [a, b] where !m.contains("no HLS") && !m.contains("HTTP") {
            if let r = m.split(separator: ":", maxSplits: 1).last { return r.trimmingCharacters(in: .whitespaces) }
        }
        return "Не удалось получить видео: \(a); \(b)"
    }

    public func visitorData() async -> String? {
        if let (v, at) = visitor.get, Date().timeIntervalSince(at) < 6 * 3600 { return v }
        let body: [String: Any] = ["context": ["client": ["clientName": "WEB", "clientVersion": Innertube.webVersion, "hl": "en", "gl": "US"]]]
        guard let r = try? await http.postJSON("https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false", body),
              let v = r.at("/responseContext/visitorData").string else { return nil }
        visitor.with { $0 = (v, Date()) }
        return v
    }

    func visionos(_ id: String) async throws -> StreamInfo {
        let vd = await visitorData() ?? ""
        let r = try await player(id, label: "visionOS", clientId: "101", version: Streams.visionVersion, ua: Streams.visionUA, client: [
            "clientName": "VISIONOS", "clientVersion": Streams.visionVersion, "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
            "osName": "visionOS", "osVersion": "26.5.23O471",
        ], visitor: vd)
        return try await finish(r, label: "visionOS", source: "visionos")
    }

    func ios(_ id: String) async throws -> StreamInfo {
        let client: [String: Any] = [
            "clientName": "IOS", "clientVersion": Streams.iosVersion, "deviceMake": "Apple", "deviceModel": "iPhone16,2",
            "osName": "iPhone", "osVersion": "18.3.2.22D82",
        ]
        var last: J?
        for attempt in 0..<5 {
            let kept = iosVisitor.get
            let vd = attempt % 2 == 0 ? kept : ""
            let r = try await player(id, label: "iOS", clientId: "5", version: Streams.iosVersion, ua: Streams.iosUA, client: client, visitor: vd)
            last = r
            if !r.at("/streamingData/hlsManifestUrl").isNull {
                if vd.isEmpty, let v = r.at("/responseContext/visitorData").string {
                    iosVisitor.with { $0 = v }
                }
                break
            }
            if !kept.isEmpty && vd == kept && attempt >= 2 {
                iosVisitor.with { $0 = "" }
            }
        }
        guard let r = last else { throw KTubeError("iOS: нет ответа") }
        return try await finish(r, label: "iOS", source: "ios")
    }

    func player(_ id: String, label: String, clientId: String, version: String, ua: String, client: [String: Any], visitor: String) async throws -> J {
        let region = innertube.region
        var c = client
        c["userAgent"] = ua
        c["hl"] = region.hl
        c["gl"] = region.gl
        if !visitor.isEmpty { c["visitorData"] = visitor }
        var headers = [
            "User-Agent": ua,
            "X-YouTube-Client-Name": clientId,
            "X-YouTube-Client-Version": version,
            "Origin": "https://www.youtube.com",
        ]
        if !visitor.isEmpty { headers["X-Goog-Visitor-Id"] = visitor }
        let r = try await http.postJSON("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", [
            "videoId": id, "contentCheckOk": true, "racyCheckOk": true, "context": ["client": c],
        ], headers: headers)
        let status = r.at("/playabilityStatus/status").string ?? ""
        if status != "OK" {
            throw KTubeError("\(label): \(r.at("/playabilityStatus/reason").string ?? status)")
        }
        return r
    }

    func finish(_ r: J, label: String, source: String) async throws -> StreamInfo {
        var info = Streams.parsePlayer(r)
        guard let hls = info.hlsURL else { throw KTubeError("\(label): no HLS manifest") }
        let master = try await http.getOK(hls, headers: ["User-Agent": UA.browser]).text
        let (variants, audio) = HLS.parseMaster(master, av1: true)
        info.variants = variants
        info.audioTracks = audio
        info.source = source
        return info
    }

    public static func parsePlayer(_ r: J) -> StreamInfo {
        let vd = r["videoDetails"], sd = r["streamingData"]
        var info = StreamInfo()
        info.id = vd["videoId"].string ?? ""
        info.title = vd["title"].string ?? ""
        info.author = vd["author"].string ?? ""
        info.channelId = vd["channelId"].string ?? ""
        info.lengthSecs = vd["lengthSeconds"].int ?? 0
        info.viewCount = vd["viewCount"].int
        info.description = vd["shortDescription"].string ?? ""
        info.isLive = vd["isLive"].bool ?? false
        info.hlsURL = sd["hlsManifestUrl"].string
        info.thumbnail = Parse.bestThumb(vd["thumbnail"]) ?? Thumbs.video(info.id)
        for t in r.at("/captions/playerCaptionsTracklistRenderer/captionTracks").array {
            guard let url = t["baseUrl"].string, !url.isEmpty else { continue }
            info.captions.append(CaptionTrack(
                lang: t["languageCode"].string ?? "",
                name: t["name"].text,
                url: url.replacingOccurrences(of: "&fmt=srv3", with: "") + "&fmt=vtt",
                auto: t["kind"].string == "asr"
            ))
        }
        if let spec = r.at("/storyboards/playerStoryboardSpecRenderer/spec").string {
            info.storyboard = parseStoryboard(spec)
        }
        return info
    }

    /// spec: "base|w#h#count#cols#rows#interval#name#sigh|..." -> the largest level.
    public static func parseStoryboard(_ spec: String) -> Storyboard? {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let li = parts.count - 2
        let f = parts[parts.count - 1].split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 8, let w = Int(f[0]), let h = Int(f[1]), let n = Int(f[2]), let c = Int(f[3]), let rr = Int(f[4]), let iv = Int(f[5]) else { return nil }
        let url = parts[0].replacingOccurrences(of: "$L", with: String(li)).replacingOccurrences(of: "$N", with: f[6]) + "&sigh=\(f[7])"
        return Storyboard(urlTemplate: url, width: w, height: h, count: n, cols: c, rows: rr, intervalMs: iv)
    }
}
