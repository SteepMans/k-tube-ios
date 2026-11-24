import Foundation

public struct SearchFilter: Hashable, Sendable, Codable {
    /// 0 relevance, 1 rating, 2 upload date, 3 view count
    public var sort: Int = 0
    /// 0 any, 1 hour, 2 today, 3 week, 4 month, 5 year
    public var date: Int = 0
    /// 0 any, 1 video, 2 channel, 3 playlist, 4 movie
    public var kind: Int = 0
    /// 0 any, 1 short (<4m), 2 long (>20m), 3 medium (4-20m)
    public var duration: Int = 0
    public var hd = false
    public var subtitles = false
    public var creativeCommons = false
    public var live = false
    public var fourK = false
    public var hdr = false

    public init() {}

    public var isDefault: Bool { self == SearchFilter() }

    /// The protobuf `sp` parameter of a search.
    public func encode() -> String? {
        if isDefault { return nil }
        func varint(_ out: inout [UInt8], _ value: UInt64) {
            var v = value
            repeat {
                let b = UInt8(v & 0x7f)
                v >>= 7
                out.append(v == 0 ? b : b | 0x80)
            } while v != 0
        }
        func field(_ out: inout [UInt8], _ num: UInt64, _ v: UInt64) {
            varint(&out, num << 3)
            varint(&out, v)
        }
        var filters: [UInt8] = []
        if date > 0 { field(&filters, 1, UInt64(date)) }
        if kind > 0 { field(&filters, 2, UInt64(kind)) }
        if duration > 0 { field(&filters, 3, UInt64(duration)) }
        if hd { field(&filters, 4, 1) }
        if subtitles { field(&filters, 5, 1) }
        if creativeCommons { field(&filters, 6, 1) }
        if live { field(&filters, 8, 1) }
        if fourK { field(&filters, 14, 1) }
        if hdr { field(&filters, 25, 1) }
        var out: [UInt8] = []
        if sort > 0 { field(&out, 1, UInt64(sort)) }
        if !filters.isEmpty {
            varint(&out, (2 << 3) | 2)
            varint(&out, UInt64(filters.count))
            out += filters
        }
        return Data(out).base64EncodedString()
    }
}

public enum ResolvedURL: Hashable, Sendable {
    case video(String, start: Int?)
    case channel(String)
    case playlist(String)
}

/// YouTube's internal API (the WEB client): search, browse, watch-next, comments, Shorts, live chat.
public final class Innertube: @unchecked Sendable {
    public static let base = "https://www.youtube.com/youtubei/v1"
    public static let webVersion = "2.20251120.01.00"

    /// Category channels of Explore (YouTube removed the Trending page in 2025).
    public static let explore: [(String, String)] = [
        ("Музыка", "UC-9-kyTW8ZkZNDHQJ6FgpwQ"),
        ("Игры", "UCOpNcN46UbXVtpKMrmU4Abg"),
        ("Спорт", "UCEgdi0XIXXZ-qJOFPf4JSKw"),
        ("Трансляции", "UC4R8DWoMoI7CAwX8_LjQHig"),
        ("Мода и красота", "UCrpQ4p1Ql_hG8rKXIKM1MOQ"),
        ("Обучение", "UCtFRv9O2AHqOZjjynzrv-xg"),
    ]

    public let http: HTTPClient
    private let regionValue: Locked<(String, String)>

    public init(http: HTTPClient, hl: String = "ru", gl: String = "RU") {
        self.http = http
        regionValue = Locked((hl, gl))
    }

    public var region: (hl: String, gl: String) {
        let r = regionValue.get
        return (r.0, r.1)
    }

    public func setRegion(hl: String, gl: String) {
        regionValue.with { $0 = (hl, gl) }
    }

    func webContext() -> [String: Any] {
        let r = region
        return ["client": ["clientName": "WEB", "clientVersion": Innertube.webVersion, "hl": r.hl, "gl": r.gl]]
    }

    public func call(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        var b = body
        b["context"] = webContext()
        return try await http.postJSON("\(Innertube.base)/\(endpoint)?prettyPrint=false", b, headers: [
            "X-YouTube-Client-Name": "1",
            "X-YouTube-Client-Version": Innertube.webVersion,
            "Origin": "https://www.youtube.com",
            "User-Agent": UA.browser,
        ])
    }

    // MARK: search

    public func search(_ query: String, filter: SearchFilter = SearchFilter()) async throws -> Page {
        var body: [String: Any] = ["query": query]
        if let p = filter.encode() { body["params"] = p }
        return Parse.collectItems(try await call("search", body))
    }

    public func searchContinue(_ token: String) async throws -> Page {
        let r = try await call("search", ["continuation": token])
        // the next page comes in onResponseReceivedCommands, which the general walk skips
        let cmds = r["onResponseReceivedCommands"]
        return Parse.collectItems(cmds.isNull ? r : cmds)
    }

    public func suggestions(_ query: String) async throws -> [String] {
        let r = region
        let q = URLCoding.encode(query)
        if let t = try? await http.get("https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&hl=\(r.hl)&gl=\(r.gl)&q=\(q)").text,
           let v = Innertube.parseSuggestionsJSONP(t), !v.isEmpty {
            return v
        }
        let j = try await http.getOK("https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=\(r.hl)&gl=\(r.gl)&q=\(q)").json
        return j[1].array.compactMap(\.string)
    }

    /// `window.google.ac.h(["q",[["sugg",0,[..]],..],{..}])` -> the suggestions.
    public static func parseSuggestionsJSONP(_ t: String) -> [String]? {
        guard let s = t.firstIndex(of: "("), let e = t.lastIndex(of: ")"), s < e else { return nil }
        let j = J.parse(String(t[t.index(after: s)..<e]))
        guard j[1].isArray else { return nil }
        return j[1].array.compactMap { $0[0].string ?? $0.string }
    }

    // MARK: browse

    public func browse(_ id: String, params: String? = nil) async throws -> J {
        var body: [String: Any] = ["browseId": id]
        if let params { body["params"] = params }
        return try await call("browse", body)
    }

    public func browseContinue(_ token: String) async throws -> Page {
        Parse.collectItems(try await call("browse", ["continuation": token]))
    }

    public func explorePage(_ channelId: String) async throws -> Page {
        Parse.collectItems(try await browse(channelId))
    }

    public func resolve(_ url: String) async throws -> ResolvedURL {
        if let local = Innertube.parseYouTubeURL(url) { return local }
        let r = try await call("navigation/resolve_url", ["url": url])
        let ep = r["endpoint"]
        if let id = ep.at("/browseEndpoint/browseId").string {
            return id.hasPrefix("VL") ? .playlist(String(id.dropFirst(2))) : .channel(id)
        }
        if let id = ep.at("/watchEndpoint/videoId").string { return .video(id, start: nil) }
        throw KTubeError("Ссылка не распознана")
    }

    /// Fast local parse of the usual link shapes (watch, youtu.be, shorts, live, embed, playlist, channel).
    public static func parseYouTubeURL(_ input: String) -> ResolvedURL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func isId(_ x: String) -> Bool { x.count == 11 && x.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        if isId(s) { return .video(s, start: nil) }
        guard s.contains("youtu") else { return nil }
        let q = URLCoding.query(s)
        let start = q["t"].flatMap { t -> Int? in
            let digits = t.trimmingCharacters(in: CharacterSet(charactersIn: "s"))
            return Int(digits)
        }
        if let r = s.range(of: "youtu.be/") {
            let id = String(s[r.upperBound...].prefix(11))
            if isId(id) { return .video(id, start: start) }
        }
        for marker in ["/shorts/", "/live/", "/embed/"] {
            if let r = s.range(of: marker) {
                let id = String(s[r.upperBound...].prefix(11))
                if isId(id) { return .video(id, start: start) }
            }
        }
        if let v = q["v"], isId(v) { return .video(v, start: start) }
        if let l = q["list"], !l.isEmpty { return .playlist(l) }
        if let r = s.range(of: "/channel/") {
            let id = String(s[r.upperBound...].prefix { $0 != "/" && $0 != "?" })
            if !id.isEmpty { return .channel(id) }
        }
        return nil
    }

    // MARK: channel

    public func channel(_ channelId: String, tabParams: String? = nil) async throws -> ChannelPage {
        let r = try await browse(channelId, params: tabParams)
        return Innertube.parseChannel(r, id: channelId)
    }

    public static func parseChannel(_ r: J, id channelId: String) -> ChannelPage {
        var info = ChannelItem(id: channelId)
        let md = r.at("/metadata/channelMetadataRenderer")
        if !md.isNull {
            info.name = md["title"].string ?? ""
            info.description = md["description"].string
            info.avatar = Parse.bestThumb(md["avatar"])
            if let ext = md["externalId"].string { info.id = ext }
            info.handle = md["vanityChannelUrl"].string?.split(separator: "/").last.map(String.init)
        }
        var banner: String?
        let ph = r.at("/header/pageHeaderRenderer/content/pageHeaderViewModel")
        if !ph.isNull {
            if info.name.isEmpty { info.name = ph.at("/title/dynamicTextViewModel/text/content").string ?? "" }
            if info.avatar == nil { info.avatar = Parse.bestThumb(ph.at("/image/decoratedAvatarViewModel/avatar/avatarViewModel/image")) }
            banner = Parse.bestThumb(ph.at("/banner/imageBannerViewModel/image"))
            for row in ph.at("/metadata/contentMetadataViewModel/metadataRows").array {
                for part in row["metadataParts"].array {
                    guard let t = part.at("/text/content").string else { continue }
                    let low = t.lowercased()
                    if t.hasPrefix("@") { info.handle = t }
                    else if low.contains("subscriber") || low.contains("подписчик") { info.subscribersText = t }
                    else if low.contains("video") || low.contains("видео") { info.videoCountText = t }
                }
            }
        } else {
            let c4 = r.at("/header/c4TabbedHeaderRenderer")
            banner = Parse.bestThumb(c4["banner"])
            info.subscribersText = c4["subscriberCountText"].optText
        }
        var tabs: [ChannelTab] = []
        var page = Page()
        for t in r.at("/contents/twoColumnBrowseResultsRenderer/tabs").array {
            let tr = t["tabRenderer"].isNull ? t["expandableTabRenderer"] : t["tabRenderer"]
            if tr.isNull { continue }
            let title = tr["title"].string ?? ""
            let selected = tr["selected"].bool ?? false
            let params = tr.at("/endpoint/browseEndpoint/params").string
            if selected, !tr["content"].isNull { page = Parse.collectItems(tr["content"]) }
            if !title.isEmpty { tabs.append(ChannelTab(title: title, params: params, selected: selected)) }
        }
        for i in page.items.indices {
            if case .video(var v) = page.items[i] {
                if v.channelName.isEmpty { v.channelName = info.name }
                if v.channelId == nil { v.channelId = info.id }
                if v.channelAvatar == nil { v.channelAvatar = info.avatar }
                page.items[i] = .video(v)
            }
        }
        return ChannelPage(info: info, banner: banner, tabs: tabs, page: page)
    }

    public func channelSearch(_ channelId: String, query: String) async throws -> Page {
        Parse.collectItems(try await call("browse", ["browseId": channelId, "params": "EgZzZWFyY2jyBgQKAloA", "query": query]))
    }

    public func channelAvatar(_ channelId: String) async throws -> String? {
        let r = try await browse(channelId)
        return Parse.smallThumb(r.at("/metadata/channelMetadataRenderer/avatar"))
            ?? Parse.smallThumb(r.at("/header/pageHeaderRenderer/content/pageHeaderViewModel/image/decoratedAvatarViewModel/avatar/avatarViewModel/image"))
    }

    // MARK: playlist

    public func playlist(_ playlistId: String) async throws -> PlaylistPage {
        Innertube.parsePlaylist(try await browse("VL" + playlistId), id: playlistId)
    }

    public static func parsePlaylist(_ r: J, id playlistId: String) -> PlaylistPage {
        let page = Parse.collectItems(r["contents"])
        var info = PlaylistItem(id: playlistId)
        info.title = r.at("/metadata/playlistMetadataRenderer/title").string ?? ""
        var description: String?
        let h = r.at("/header/pageHeaderRenderer")
        if !h.isNull {
            if info.title.isEmpty { info.title = h["pageTitle"].string ?? "" }
            for arr in h.findAll("metadataParts") {
                for p in arr.array {
                    guard let t = p.at("/text/content").string else { continue }
                    let low = t.lowercased()
                    if low.contains("video") || low.contains("видео") { info.videoCountText = t }
                    if let b = p.find("browseEndpoint")?["browseId"].string, b.hasPrefix("UC") {
                        info.channelId = b
                        info.channelName = t.replacingOccurrences(of: "by ", with: "")
                    }
                }
            }
            description = h.find("descriptionPreviewViewModel")?.at("/description/content").string
        } else {
            let ph = r.at("/header/playlistHeaderRenderer")
            info.videoCountText = ph["numVideosText"].optText
            info.channelName = ph["ownerText"].optText
            description = ph["descriptionText"].optText
        }
        let videos = page.videos
        info.thumbnail = videos.first?.thumbnail
        info.firstVideoId = videos.first?.id
        return PlaylistPage(info: info, description: description, videos: videos, continuation: page.continuation)
    }

    // MARK: watch

    public func watchNext(_ videoId: String, playlistId: String? = nil) async throws -> WatchInfo {
        var body: [String: Any] = ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        if let playlistId { body["playlistId"] = playlistId }
        return Innertube.parseWatchNext(try await call("next", body), id: videoId)
    }

    public static func parseWatchNext(_ r: J, id videoId: String) -> WatchInfo {
        var w = WatchInfo(id: videoId)
        let results = r.at("/contents/twoColumnWatchNextResults")
        if let p = results.find("videoPrimaryInfoRenderer") {
            w.title = p["title"].text
            w.viewsText = p.at("/viewCount/videoViewCountRenderer/viewCount").text
            w.dateText = p["dateText"].text
            w.isLive = p.at("/viewCount/videoViewCountRenderer/isLive").bool ?? false
            if let like = p.find("likeButtonViewModel") {
                w.likesText = like.find("defaultButtonViewModel")?.at("/buttonViewModel/title").string
            }
        }
        if let sec = results.find("videoSecondaryInfoRenderer") {
            let o = sec.at("/owner/videoOwnerRenderer")
            if !o.isNull {
                w.channel.name = o["title"].text
                w.channel.id = o.at("/navigationEndpoint/browseEndpoint/browseId").string ?? o.at("/title/runs/0/navigationEndpoint/browseEndpoint/browseId").string ?? ""
                w.channel.avatar = Parse.bestThumb(o["thumbnail"])
                w.channel.subscribersText = o["subscriberCountText"].optText
                if w.channel.name.isEmpty { w.channel.name = o.at("/attributedTitle/content").string ?? "" }
                if w.channel.id.isEmpty, let first = o.findAll("listItemViewModel").first {
                    w.channel.id = first.find("browseEndpoint")?["browseId"].string ?? ""
                }
                if w.channel.avatar == nil {
                    w.channel.avatar = o.at("/avatarStack/avatarStackViewModel/avatars/0/avatarViewModel/image/sources/0/url").string.map(Parse.fixURL)
                }
            }
            w.description = sec.at("/attributedDescription/content").string ?? sec["description"].text
        }
        let sr = results["secondaryResults"]
        if !sr.isNull {
            let page = Parse.collectItems(sr)
            w.related = page.items
            w.relatedContinuation = page.continuation
        }
        for sec in results.findAll("itemSectionRenderer") where sec["sectionIdentifier"].string == "comment-item-section" {
            w.commentsToken = Parse.continuationToken(sec.at("/contents/0/continuationItemRenderer"))
        }
        if let items = r["engagementPanels"].find("sortFilterSubMenuRenderer")?["subMenuItems"], items.isArray {
            w.commentsSort = (items[0].at("/serviceEndpoint/continuationCommand/token").string, items[1].at("/serviceEndpoint/continuationCommand/token").string)
        }
        if let lc = r.find("liveChatRenderer"), !(lc["isReplay"].bool ?? false),
           let first = lc.at("/continuations/0/reloadContinuationData/continuation").string {
            // "Top chat" and "every message" differ by one flag inside the token
            if let range = first.range(of: "ggEMCAQY") {
                w.liveChat = (first, first.replacingCharacters(in: range, with: "ggEMCAEY"))
            } else {
                w.liveChat = (first, first)
            }
        }
        if let cnt = results.find("commentsEntryPointHeaderRenderer") {
            w.commentCountText = cnt["commentCount"].optText
        }
        var chapters: [Chapter] = []
        for c in r.findAll("chapterRenderer") {
            chapters.append(Chapter(title: c["title"].text, start: (c["timeRangeStartMillis"].double ?? 0) / 1000, thumbnail: Parse.bestThumb(c["thumbnail"])))
        }
        if chapters.isEmpty {
            for c in r.findAll("macroMarkersListItemRenderer") {
                if let t = c["timeDescription"].optText.flatMap(Format.parseDuration) {
                    chapters.append(Chapter(title: c["title"].text, start: Double(t), thumbnail: Parse.bestThumb(c["thumbnail"])))
                }
            }
            chapters.sort { $0.start < $1.start }
            var seen = Set<Double>()
            chapters = chapters.filter { seen.insert($0.start).inserted }
        }
        if chapters.isEmpty { chapters = Parse.chaptersFromDescription(w.description) }
        w.chapters = chapters
        for l in r.findAll("macroMarkersListEntity") where l.at("/markersList/markerType").string == "MARKER_TYPE_HEATMAP" {
            for m in l.at("/markersList/markers").array {
                w.heatmap.append(HeatPoint(start: (m["startMillis"].double ?? 0) / 1000, duration: (m["durationMillis"].double ?? 0) / 1000, intensity: m["intensityScoreNormalized"].double ?? 0))
            }
            break
        }
        let pl = results.at("/playlist/playlist")
        if !pl.isNull {
            w.playlist = WatchPlaylist(id: pl["playlistId"].string ?? "", title: pl["title"].string ?? "", items: Parse.collectItems(pl["contents"]).videos)
        }
        return w
    }

    public func relatedContinue(_ token: String) async throws -> Page {
        Parse.collectItems(try await call("next", ["continuation": token]))
    }

    // MARK: comments

    public func comments(_ token: String) async throws -> CommentPage {
        Innertube.parseComments(try await call("next", ["continuation": token]))
    }

    public static func parseComments(_ r: J) -> CommentPage {
        var page = CommentPage()
        var payloads: [String: J] = [:]
        var toolbarStates: [String: J] = [:]
        for m in r.at("/frameworkUpdates/entityBatchUpdate/mutations").array {
            let key = m["entityKey"].string ?? ""
            let p = m.at("/payload/commentEntityPayload")
            if !p.isNull { payloads[key] = p; continue }
            let s = m.at("/payload/engagementToolbarStateEntityPayload")
            if !s.isNull { toolbarStates[key] = s }
        }
        var list: [J] = []
        for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
            for e in r[key].array {
                for k in ["reloadContinuationItemsCommand", "appendContinuationItemsAction"] {
                    list += e.at("/\(k)/continuationItems").array
                }
            }
        }
        for it in list {
            let h = it["commentsHeaderRenderer"]
            if !h.isNull {
                page.countText = h["countText"].optText
                let items = h.at("/sortMenu/sortFilterSubMenuRenderer/subMenuItems")
                page.sortTopToken = items[0].at("/serviceEndpoint/continuationCommand/token").string
                page.sortNewToken = items[1].at("/serviceEndpoint/continuationCommand/token").string
            }
            var vm = J(nil)
            var thread = J(nil)
            if !it["commentThreadRenderer"].isNull {
                thread = it["commentThreadRenderer"]
                let c = thread["commentViewModel"]
                vm = c["commentViewModel"].isNull ? c : c["commentViewModel"]
            } else if !it["commentViewModel"].isNull {
                vm = it["commentViewModel"]
            }
            if !vm.isNull, let p = payloads[vm["commentKey"].string ?? ""] {
                let props = p["properties"], author = p["author"], toolbar = p["toolbar"]
                let heart = toolbarStates[vm["toolbarStateKey"].string ?? ""]?["heartState"].string ?? ""
                let replies = thread.at("/replies/commentRepliesRenderer/contents").array.first { !$0["continuationItemRenderer"].isNull }
                page.comments.append(Comment(
                    id: props["commentId"].string ?? UUID().uuidString,
                    author: author["displayName"].string ?? "",
                    authorId: author["channelId"].string,
                    authorAvatar: author["avatarThumbnailUrl"].string,
                    text: props.at("/content/content").string ?? "",
                    published: props["publishedTime"].string ?? "",
                    likes: (toolbar["likeCountNotliked"].string ?? "").trimmingCharacters(in: .whitespaces),
                    replyCount: toolbar["replyCount"].string ?? "",
                    repliesToken: replies.flatMap { Parse.continuationToken($0["continuationItemRenderer"]) },
                    isCreator: author["isCreator"].bool ?? false,
                    isVerified: author["isVerified"].bool ?? false,
                    isPinned: !vm["pinnedText"].isNull,
                    hearted: heart.contains("HEARTED") && !heart.contains("UNHEARTED")
                ))
            }
            let c = it["continuationItemRenderer"]
            if !c.isNull { page.continuation = Parse.continuationToken(c) }
        }
        return page
    }

    // MARK: Shorts

    /// The Shorts feed: from a seed Short (the last one watched) or from nothing; ids only.
    public func shortsFeed(token: String?, seed: String?) async throws -> ([VideoItem], String?) {
        var ids: [String] = []
        let seq: String
        if let token {
            seq = token
        } else if let seed {
            var pb: [UInt8] = [0x0a, UInt8(seed.utf8.count)]
            pb += Array(seed.utf8)
            seq = Data(pb).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        } else {
            let r = try await call("reel/reel_item_watch", ["params": "CA8%3D", "disablePlayerResponse": true, "inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS"])
            if let id = r.at("/replacementEndpoint/reelWatchEndpoint/videoId").string { ids.append(id) }
            guard let s = r["sequenceContinuation"].string else { throw KTubeError("Лента Shorts недоступна") }
            seq = s
        }
        let s = try await call("reel/reel_watch_sequence", ["sequenceParams": seq])
        for e in s["entries"].array {
            if let id = e.at("/command/reelWatchEndpoint/videoId").string, !ids.contains(id) { ids.append(id) }
        }
        let cont = s.at("/continuationEndpoint/continuationCommand/token").string
        return (ids.map { id in
            var v = VideoItem(id: id, thumbnail: Thumbs.short(id))
            v.isShort = true
            return v
        }, cont)
    }

    // MARK: live chat

    public func liveChat(_ token: String) async throws -> ChatBatch {
        Innertube.parseLiveChat(try await call("live_chat/get_live_chat", ["continuation": token]))
    }

    public static func parseLiveChat(_ r: J) -> ChatBatch {
        var b = ChatBatch()
        let c = r.at("/continuationContents/liveChatContinuation")
        for a in c["actions"].array {
            let item = a.at("/addChatItemAction/item")
            var rr = item["liveChatTextMessageRenderer"]
            var paid: String?
            if rr.isNull {
                rr = item["liveChatPaidMessageRenderer"]
                paid = rr["purchaseAmountText"].optText
            }
            if rr.isNull { continue }
            var owner = false, moderator = false
            for badge in rr["authorBadges"].array {
                let bb = badge["liveChatAuthorBadgeRenderer"].isNull ? badge : badge["liveChatAuthorBadgeRenderer"]
                switch bb.at("/icon/iconType").string {
                case "OWNER": owner = true
                case "MODERATOR": moderator = true
                default: break
                }
            }
            let text = rr.at("/message/runs").array.map { run -> String in
                if let t = run["text"].string { return t }
                return run.at("/emoji/shortcuts/0").string ?? run.at("/emoji/emojiId").string ?? ""
            }.joined()
            b.messages.append(ChatMessage(id: rr["id"].string ?? UUID().uuidString, author: rr["authorName"].text, text: text, isOwner: owner, isModerator: moderator, superChat: paid))
        }
        if let next = c.at("/continuations/0").object?.values.first {
            let n = J(next)
            b.continuation = n["continuation"].string
            b.timeoutMs = n["timeoutMs"].int ?? 5000
        }
        return b
    }
}

public enum UA {
    public static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
