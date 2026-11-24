import Foundation

/// Google account sign-in through YouTube's TV device flow, like the desktop K-Tube (and SmartTube): the app shows a
/// code, the user enters it at google.com/device, and the token authorizes the TV Innertube client for the personal
/// home feed, subscriptions, playlists, likes, the live chat and the watch history.
public final class Account: @unchecked Sendable {
    // Public OAuth client of the YouTube TV app (the same one the desktop K-Tube and SmartTube use).
    static let clientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT" // gitleaks:allow (public client of the TV app)
    static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    static let tvVersion = "7.20251120.13.00"
    static let tvUA = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"

    public struct Profile: Codable, Sendable, Equatable {
        public var name: String
        public var handle: String?
        public var avatar: String?
    }

    public struct Stored: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Int
        public var profile: Profile?
    }

    public struct DeviceCode: Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: String
        public var interval: Int
        public var expiresIn: Int
    }

    public enum Poll: Sendable {
        case pending, slowDown
        case done(Profile)
    }

    let http: HTTPClient
    let innertube: Innertube
    let stored: Locked<Stored?>
    /// Saves the tokens (the app keeps them in the Keychain).
    let persist: @Sendable (Stored?) -> Void
    private let removal = Locked<[String: String]>([:])

    public init(innertube: Innertube, stored: Stored?, persist: @escaping @Sendable (Stored?) -> Void) {
        self.http = innertube.http
        self.innertube = innertube
        self.stored = Locked(stored)
        self.persist = persist
    }

    public var signedIn: Bool { !(stored.get?.refreshToken.isEmpty ?? true) }
    public var profile: Profile? { stored.get?.profile }

    public func signOut() {
        stored.with { $0 = nil }
        persist(nil)
    }

    private func oauth(_ url: String, _ body: [String: Any]) async throws -> (Int, J) {
        let r = try await http.send(HTTPRequest(url: url, method: "POST",
                                                headers: ["Content-Type": "application/json", "User-Agent": Account.tvUA],
                                                body: JSONBody.data(body)))
        return (r.status, r.json)
    }

    /// Step 1: a code for the user to enter at google.com/device.
    public func startLogin() async throws -> DeviceCode {
        let deviceId = (0..<32).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
        let (_, v) = try await oauth("https://www.youtube.com/o/oauth2/device/code",
                                     ["client_id": Account.clientId, "scope": Account.scope, "device_id": deviceId, "device_model": "ytlr::"])
        guard let dc = v["device_code"].string, let uc = v["user_code"].string else {
            throw KTubeError("YouTube не выдал код входа")
        }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURL: v["verification_url"].string ?? "https://www.google.com/device",
                          interval: v["interval"].int ?? 5, expiresIn: v["expires_in"].int ?? 1800)
    }

    /// Step 2: poll until the user has approved the code.
    public func poll(_ dc: DeviceCode) async throws -> Poll {
        let (_, v) = try await oauth("https://www.youtube.com/o/oauth2/token", [
            "client_id": Account.clientId, "client_secret": Account.clientSecret, "code": dc.deviceCode,
            "grant_type": "http://oauth.net/grant_type/device/1.0",
        ])
        if let err = v["error"].string {
            switch err {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": throw KTubeError("Код устарел, начните вход заново")
            case "access_denied": throw KTubeError("Вход отменён")
            default: throw KTubeError("Вход не удался: \(err)")
            }
        }
        guard let access = v["access_token"].string else { throw KTubeError("YouTube не выдал токен") }
        let s = Stored(accessToken: access, refreshToken: v["refresh_token"].string ?? "",
                       expiresAt: Format.now() + (v["expires_in"].int ?? 3600) - 60, profile: nil)
        stored.with { $0 = s }
        persist(s)
        let p = (try? await fetchProfile()) ?? Profile(name: "Аккаунт YouTube")
        let withProfile = stored.with { st -> Stored? in
            st?.profile = p
            return st
        }
        persist(withProfile)
        return .done(p)
    }

    /// A valid access token, refreshed when needed.
    public func accessToken() async -> String? {
        guard let cur = stored.get else { return nil }
        if cur.expiresAt > Format.now(), !cur.accessToken.isEmpty { return cur.accessToken }
        guard let (status, v) = try? await oauth("https://www.youtube.com/o/oauth2/token", [
            "client_id": Account.clientId, "client_secret": Account.clientSecret,
            "refresh_token": cur.refreshToken, "grant_type": "refresh_token",
        ]) else { return nil }
        if let tok = v["access_token"].string {
            let exp = v["expires_in"].int ?? 3600
            let s = stored.with { st -> Stored? in
                st?.accessToken = tok
                st?.expiresAt = Format.now() + exp - 60
                return st
            }
            persist(s)
            return tok
        }
        // the grant was revoked on the Google account page
        if status == 400 || status == 401 { signOut() }
        return nil
    }

    /// Authorized call to the TV Innertube client.
    public func tv(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        guard let token = await accessToken() else { throw KTubeError("Вход в аккаунт YouTube не выполнен") }
        var b = body
        let r = innertube.region
        b["context"] = ["client": ["clientName": "TVHTML5", "clientVersion": Account.tvVersion, "hl": r.hl, "gl": r.gl]]
        return try await http.postJSON("https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", b, headers: [
            "User-Agent": Account.tvUA, "Authorization": "Bearer \(token)", "X-YouTube-Client-Name": "7",
            "X-YouTube-Client-Version": Account.tvVersion, "Origin": "https://www.youtube.com",
        ])
    }

    func fetchProfile() async throws -> Profile {
        let r = try await tv("account/accounts_list", ["accountReadMask": ["returnOwner": true]])
        let item = r.find("accountItem") ?? r.find("accountItemRenderer") ?? r
        let name = item["accountName"].text
        return Profile(name: name.isEmpty ? "Аккаунт YouTube" : name,
                       handle: item["channelHandle"].optText,
                       avatar: Parse.bestThumb(item["accountPhoto"]))
    }

    // MARK: feeds

    static func videosOnly(_ p: Page) -> Page {
        var seen = Set<String>()
        var out = Page(continuation: p.continuation)
        for i in p.items {
            guard case .video(var v) = i, seen.insert(v.id).inserted else { continue }
            if v.publishedTs == nil { v.publishedTs = v.publishedText.flatMap(Format.parseRelative) }
            out.items.append(.video(v))
        }
        return out
    }

    /// The account's own YouTube Home.
    public func home() async throws -> Page {
        Account.videosOnly(Parse.collectItems(try await tv("browse", ["browseId": "FEwhat_to_watch"])))
    }

    public func subscriptionsFeed() async throws -> Page {
        Account.videosOnly(Parse.collectItems(try await tv("browse", ["browseId": "FEsubscriptions"])))
    }

    public func history() async throws -> Page {
        let r = try await tv("browse", ["browseId": "FEhistory"])
        harvestRemoval(r)
        return Account.videosOnly(Parse.collectItems(r))
    }

    public func browseContinue(_ token: String) async throws -> Page {
        let r = try await tv("browse", ["continuation": token])
        harvestRemoval(r)
        return Account.videosOnly(Parse.collectItems(r))
    }

    /// Remembers the "remove from watch history" feedback tokens of the history tiles.
    func harvestRemoval(_ r: J) {
        var found: [String: String] = [:]
        for tile in r.findAll("tileRenderer") {
            guard let id = tile.at("/onSelectCommand/watchEndpoint/videoId").string else { continue }
            for item in tile.findAll("menuServiceItemRenderer") {
                let text = item.at("/text/runs/0/text").string?.lowercased() ?? ""
                if let t = item.at("/serviceEndpoint/feedbackEndpoint/feedbackToken").string,
                   text.contains("history") || text.contains("remove") || text.contains("истори") || text.contains("удал") {
                    found[id] = t
                    break
                }
            }
        }
        if !found.isEmpty { removal.with { $0.merge(found) { $1 } } }
    }

    public func removeFromHistory(_ videoId: String) async throws {
        guard let t = removal.get[videoId] else { throw KTubeError("Обновите историю аккаунта и попробуйте ещё раз") }
        _ = try await tv("feedback", ["feedbackTokens": [t]])
        removal.with { $0[videoId] = nil }
    }

    /// A "UC..." channel id inside base64 protobuf browse params.
    static func channelId(fromParams params: String) -> String? {
        let p = params.replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "%3d", with: "=")
        guard let d = Base64URL.decode(p.trimmingCharacters(in: CharacterSet(charactersIn: "="))) ?? Data(base64Encoded: p) else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        guard let r = s.range(of: "UC") else { return nil }
        let id = String(s[r.lowerBound...].prefix(24))
        return id.count == 24 && id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) ? id : nil
    }

    /// Channels the account is subscribed to.
    public func subscribedChannels() async throws -> [ChannelItem] {
        let r = try await tv("browse", ["browseId": "FEsubscriptions"])
        var out: [ChannelItem] = []
        for t in r.findAll("tabRenderer") {
            let epj = t.at("/endpoint/browseEndpoint")
            guard let ep = epj.isNull ? t.find("browseEndpoint") : epj else { continue }
            let id = ep["browseId"].string.flatMap { $0.hasPrefix("UC") ? $0 : nil } ?? ep["params"].string.flatMap(Account.channelId(fromParams:))
            guard let id, !out.contains(where: { $0.id == id }) else { continue }
            var c = ChannelItem(id: id, name: t["title"].text)
            c.avatar = Parse.bestThumb(t["thumbnail"])
            out.append(c)
        }
        return out
    }

    public func like(_ videoId: String, _ kind: String) async throws {
        // kind: like, dislike, removelike
        _ = try await tv("like/\(kind)", ["target": ["videoId": videoId]])
    }

    public func subscribe(_ channelId: String, _ on: Bool) async throws {
        _ = try await tv(on ? "subscription/subscribe" : "subscription/unsubscribe", ["channelIds": [channelId]])
    }

    /// The account's playlists (own and saved), Watch later and Liked included.
    public func playlists() async throws -> [PlaylistItem] {
        let r = try await tv("browse", ["browseId": "FEplaylist_aggregation"])
        var out: [PlaylistItem] = []
        for t in r.findAll("tileRenderer") where t["contentType"].string == "TILE_CONTENT_TYPE_PLAYLIST" {
            guard let id = t["contentId"].string, !out.contains(where: { $0.id == id }) else { continue }
            let md = t.at("/metadata/tileMetadataRenderer")
            var p = PlaylistItem(id: id, title: md["title"].optText ?? "")
            let sub = md.findAll("lineItemRenderer").compactMap { $0["text"].optText }.filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
            p.videoCountText = sub.isEmpty ? nil : sub.joined(separator: " • ")
            p.thumbnail = t.at("/header/tileHeaderRenderer/thumbnail/thumbnails").array.last?["url"].string.map(Parse.fixURL)
            out.append(p)
        }
        return out
    }

    /// A playlist as the account sees it (private and unlisted ones too).
    public func playlist(_ id: String) async throws -> PlaylistPage {
        let r = try await tv("browse", ["browseId": "VL\(id)"])
        let page = Account.videosOnly(Parse.collectItems(r))
        var info = PlaylistItem(id: id)
        if let m = r.find("entityMetadataRenderer") {
            info.title = m["title"].optText ?? ""
            let parts = m.findAll("lineItemRenderer").compactMap { $0["text"].optText }.filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
            info.videoCountText = parts.first { $0.lowercased().contains("video") || $0.lowercased().contains("видео") }
            if let o = parts.first, info.videoCountText != o { info.channelName = o }
        }
        let videos = page.items.compactMap(\.video)
        info.thumbnail = videos.first?.thumbnail
        info.firstVideoId = videos.first?.id
        return PlaylistPage(info: info, description: nil, videos: videos, continuation: page.continuation)
    }

    /// The params of live_chat/send_message: protobuf {1: {5: {1: channel, 2: video}}, 2: 1, 3: 4}.
    public static func chatParams(channelId: String, videoId: String) -> String {
        func field(_ out: inout [UInt8], _ tag: UInt8, _ bytes: [UInt8]) {
            out.append(tag)
            var n = bytes.count
            while n >= 0x80 {
                out.append(UInt8(n & 0x7f) | 0x80)
                n >>= 7
            }
            out.append(UInt8(n))
            out += bytes
        }
        var ids: [UInt8] = []
        field(&ids, 0x0a, Array(channelId.utf8))
        field(&ids, 0x12, Array(videoId.utf8))
        var inner: [UInt8] = []
        field(&inner, 0x2a, ids)
        var buf: [UInt8] = []
        field(&buf, 0x0a, inner)
        buf += [0x10, 0x01, 0x18, 0x04]
        let once = Data(buf).base64EncodedString()
        return Data(URLCoding.encode(once).utf8).base64EncodedString()
    }

    /// Posts a message to a stream's live chat as the signed-in account.
    public func sendChat(channelId: String, videoId: String, message: String) async throws {
        let r = try await tv("live_chat/send_message", [
            "params": Account.chatParams(channelId: channelId, videoId: videoId),
            "clientMessageId": "kt\(UInt64(Date().timeIntervalSince1970 * 1_000_000))",
            "richMessage": ["textSegments": [["text": message]]],
        ])
        if let err = r.find("liveChatRestrictedParticipationRenderer") ?? r.find("errorMessage") {
            let t = (err["message"].isNull ? err : err["message"]).text
            throw KTubeError(t.isEmpty ? "YouTube не принял сообщение" : t)
        }
    }

    /// The account's watch history (from every device) as history entries, newest first, with resume positions.
    public func historyEntries(maxPages: Int) async throws -> [HistoryEntry] {
        var r = try await tv("browse", ["browseId": "FEhistory"])
        let now = Format.now()
        var out: [HistoryEntry] = []
        var n = 0
        for page in 0..<maxPages {
            for t in r.findAll("tileRenderer") {
                guard var v = Parse.tile(t) else { continue }
                let resume = t.at("/onSelectCommand/watchEndpoint/startTimeSeconds").double ?? 0
                let duration = Double(t.findAll("thumbnailOverlayTimeStatusRenderer").first.flatMap { Format.parseDuration($0["text"].text) } ?? 0)
                let percent = t.findAll("thumbnailOverlayResumePlaybackRenderer").first?["percentDurationWatched"].double ?? 0
                let progress = resume > 0 ? resume : (percent >= 95 ? duration : duration * percent / 100)
                if v.durationSecs == nil, duration > 0 { v.durationSecs = Int(duration) }
                out.append(HistoryEntry(video: v, watchedAt: now - n * 60, position: progress, duration: duration))
                n += 1
            }
            guard let tok = Parse.collectItems(r).continuation, page + 1 < maxPages else { break }
            r = try await tv("browse", ["continuation": tok])
        }
        return out
    }

    /// The account's recent searches (YouTube gives them as suggestions for an empty signed-in query).
    public func searchHistory() async throws -> [String] {
        guard let token = await accessToken() else { throw KTubeError("Вход в аккаунт YouTube не выполнен") }
        let hl = URLCoding.encode(innertube.region.hl)
        let r = try await http.getOK("https://suggestqueries-clients6.youtube.com/complete/search?client=youtube-lr&ds=yt&xhr=t&q=&hl=\(hl)",
                                     headers: ["Authorization": "Bearer \(token)", "User-Agent": Account.tvUA])
        return r.json[1].array.compactMap { e in (e[0].string ?? e.string) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
