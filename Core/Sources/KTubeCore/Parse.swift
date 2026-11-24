import Foundation

/// Item parsing of Innertube answers (port of the desktop client's innertube.rs/json.rs).
public enum Parse {
    /// Renderers that only ever hold ads or paid promotions: the whole subtree is skipped.
    static let adRenderers: Set<String> = [
        "adSlotRenderer", "inFeedAdLayoutRenderer", "adSlotAndLayoutMetadata", "promotedVideoRenderer",
        "compactPromotedVideoRenderer", "promotedSparklesWebRenderer", "promotedSparklesTextSearchRenderer",
        "searchPyvRenderer", "bannerPromoRenderer", "statementBannerRenderer", "brandVideoShelfRenderer",
        "brandVideoSingletonRenderer", "videoMastheadAdV3Renderer", "mastheadAdV4Renderer", "primetimePromoRenderer",
        "playerLegacyDesktopWatchAdsRenderer", "adBreakServiceRenderer", "displayAdRenderer",
        "actionCompanionAdRenderer", "feedAdMetadataViewModel",
    ]
    static let adMarkers: Set<String> = ["adSlotLoggingData", "adLayoutLoggingData", "adClientParams", "adVideoId", "promotedVideoRenderer"]

    public static func isAd(_ v: J) -> Bool {
        if v.object != nil {
            for (k, c) in v.entries {
                if adMarkers.contains(k) || adRenderers.contains(k) { return true }
                if (k == "style" || k == "badgeStyle"), let s = c.string, s == "BADGE_STYLE_TYPE_AD" || s == "BADGE_STYLE_TYPE_AD_INFO" { return true }
                if k == "iconType", c.string == "AD_BADGE" { return true }
                if isAd(c) { return true }
            }
            return false
        }
        if v.isArray { return v.array.contains(where: isAd) }
        return false
    }

    public static func fixURL(_ u: String) -> String {
        u.hasPrefix("//") ? "https:" + u : u
    }

    /// Channel avatars come as 900x900 but are drawn small: ask for 240 px.
    public static func limitAvatar(_ u: String) -> String {
        guard u.contains("yt3.ggpht.com") || u.contains("yt3.googleusercontent.com"), let r = u.range(of: "=s", options: .backwards) else { return u }
        let rest = u[r.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        if let n = Int(digits), n > 240 {
            return String(u[..<r.lowerBound]) + "=s240" + rest.dropFirst(digits.count)
        }
        return u
    }

    /// The smallest thumbnail that is big enough for a card (or the largest one).
    public static func bestThumb(_ v: J) -> String? {
        let arr = v["thumbnails"].isArray ? v["thumbnails"].array : v["sources"].array
        guard !arr.isEmpty else { return nil }
        let w = { (t: J) in t["width"].int ?? 0 }
        let h = { (t: J) in t["height"].int ?? 0 }
        let big = arr.filter { w($0) >= 600 || h($0) >= 700 }.min(by: { w($0) * max(h($0), 1) < w($1) * max(h($1), 1) })
        let best = big ?? arr.max(by: { w($0) < w($1) })
        return best?["url"].string.map(fixURL).map(limitAvatar)
    }

    public static func smallThumb(_ v: J) -> String? {
        let arr = v["thumbnails"].isArray ? v["thumbnails"].array : v["sources"].array
        return arr.first?["url"].string.map(fixURL)
    }

    public static func continuationToken(_ c: J) -> String? {
        c.at("/continuationEndpoint/continuationCommand/token").string
            ?? c.at("/button/buttonRenderer/command/continuationCommand/token").string
            ?? c.find("continuationCommand")?["token"].string
    }

    /// Walks any Innertube answer and collects every recognizable item plus the last continuation token.
    public static func collectItems(_ v: J) -> Page {
        var page = Page()
        walk(v, &page)
        return page
    }

    private static func walk(_ v: J, _ page: inout Page) {
        if v.object != nil {
            for (k, c) in v.entries {
                if adRenderers.contains(k) { continue }
                switch k {
                case "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
                     "playlistPanelVideoRenderer", "videoWithContextRenderer", "videoCardRenderer":
                    if let vi = videoRenderer(c) { page.items.append(.video(vi)) }
                case "reelItemRenderer":
                    if let vi = reelItem(c) { page.items.append(.video(vi)) }
                case "shortsLockupViewModel":
                    if let vi = shortsLockup(c) { page.items.append(.video(vi)) }
                case "tileRenderer":
                    if let vi = tile(c) { page.items.append(.video(vi)) }
                case "nextContinuationData":
                    if let t = c["continuation"].string { page.continuation = t }
                case "lockupViewModel":
                    if let it = lockup(c) { page.items.append(it) }
                case "channelRenderer", "gridChannelRenderer":
                    if let ch = channelRenderer(c) { page.items.append(.channel(ch)) }
                case "playlistRenderer", "gridPlaylistRenderer", "radioRenderer", "compactPlaylistRenderer":
                    if let p = playlistRenderer(c) { page.items.append(.playlist(p)) }
                case "continuationItemRenderer":
                    if let t = continuationToken(c) { page.continuation = t }
                case "frameworkUpdates", "topbar", "header", "engagementPanels", "playerOverlays", "menu", "endScreen",
                     "onResponseReceivedCommands":
                    break
                default:
                    walk(c, &page)
                }
            }
        } else if v.isArray {
            for c in v.array { walk(c, &page) }
        }
    }

    static func lower(_ s: String) -> String { s.lowercased() }

    static func looksLikeViews(_ s: String) -> Bool {
        let l = lower(s)
        return l.contains("view") || l.contains("watching") || l.contains("waiting") || l.contains("просмотр") || l.contains("смотрят") || l.contains("зрител") || l.contains("ожида")
    }

    static func looksLikeDate(_ s: String) -> Bool {
        let l = lower(s)
        return l.contains("ago") || l.contains("streamed") || l.contains("premiere") || l.contains("scheduled") || l.contains("назад") || l.contains("трансляц") || l.contains("премьер") || l.contains("запланир")
    }

    public static func videoRenderer(_ r: J) -> VideoItem? {
        if isAd(r) { return nil }
        guard let id = r["videoId"].string else { return nil }
        var v = VideoItem(id: id)
        v.title = r["title"].optText ?? r["headline"].optText ?? ""
        let owner: J = !r["ownerText"].isNull ? r["ownerText"] : (!r["longBylineText"].isNull ? r["longBylineText"] : r["shortBylineText"])
        v.channelName = owner.text
        v.channelId = owner.at("/runs/0/navigationEndpoint/browseEndpoint/browseId").string
        var duration = r["lengthText"].optText
        if duration == nil {
            duration = r.findAll("thumbnailOverlayTimeStatusRenderer").first?["text"].optText
        }
        let badges = r["badges"].serialized
        v.isLive = badges.contains("LIVE_NOW") || badges.contains("\"LIVE\"") || (duration?.lowercased() == "live") || (duration?.lowercased() == "в эфире")
        v.isUpcoming = !r["upcomingEventData"].isNull
        v.durationSecs = duration.flatMap(Format.parseDuration)
        v.durationText = v.isLive ? nil : (v.durationSecs != nil ? duration : nil)
        v.publishedText = r["publishedTimeText"].optText
        v.publishedTs = v.publishedText.flatMap(Format.parseRelative)
        v.viewsText = r["shortViewCountText"].optText ?? r["viewCountText"].optText
        v.descriptionSnippet = r.at("/detailedMetadataSnippets/0/snippetText").optText ?? r["descriptionSnippet"].optText
        let av = r.at("/channelThumbnailSupportedRenderers/channelThumbnailWithLinkRenderer/thumbnail")
        v.channelAvatar = smallThumb(av.isNull ? r["channelThumbnail"] : av)
        v.isShort = !r.at("/navigationEndpoint/reelWatchEndpoint").isNull
        v.thumbnail = bestThumb(r["thumbnail"]) ?? Thumbs.video(id)
        return v
    }

    /// A video tile of the TV client (the signed-in feeds come from it).
    public static func tile(_ t: J) -> VideoItem? {
        if isAd(t) { return nil }
        let ctype = t["contentType"].string ?? ""
        if !ctype.isEmpty && ctype != "TILE_CONTENT_TYPE_VIDEO" { return nil }
        guard let id = t["contentId"].string ?? t.at("/onSelectCommand/watchEndpoint/videoId").string else { return nil }
        let meta = t.at("/metadata/tileMetadataRenderer")
        guard !meta.isNull else { return nil }
        var v = VideoItem(id: id, title: meta["title"].text, thumbnail: bestThumb(t.at("/header/tileHeaderRenderer/thumbnail")))
        let overlays = t.findAll("thumbnailOverlayTimeStatusRenderer")
        let badge = overlays.first?["text"].optText
        v.isLive = overlays.contains { $0["style"].string == "LIVE" }
        var parts: [String] = []
        for line in meta["lines"].array {
            for item in line.at("/lineRenderer/items").array {
                let r = item["lineItemRenderer"].isNull ? item : item["lineItemRenderer"]
                if v.channelId == nil, let b = r.find("browseEndpoint")?["browseId"].string { v.channelId = b }
                let tx = r["text"].text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "•")).trimmingCharacters(in: .whitespaces)
                if !tx.isEmpty { parts.append(tx) }
            }
        }
        if v.channelId == nil {
            v.channelId = t.findAll("browseEndpoint").compactMap { $0["browseId"].string }.first { $0.hasPrefix("UC") }
        }
        let published = parts.first(where: looksLikeDate) ?? parts.first { Format.parseRelative($0) != nil }
        let views = parts.first(where: looksLikeViews)
            ?? parts.dropFirst().first { $0 != published && ($0.first?.isNumber ?? false) }
        v.channelName = parts.first { $0 != views && $0 != published } ?? ""
        v.durationSecs = badge.flatMap(Format.parseDuration)
        v.durationText = v.durationSecs != nil ? badge : nil
        v.viewsText = views
        v.publishedText = published
        v.publishedTs = published.flatMap(Format.parseRelative)
        return v
    }

    static func reelItem(_ r: J) -> VideoItem? {
        guard let id = r["videoId"].string else { return nil }
        var v = VideoItem(id: id, title: r["headline"].text, thumbnail: Thumbs.short(id))
        v.viewsText = r["viewCountText"].optText
        v.isShort = true
        return v
    }

    static func shortsLockup(_ r: J) -> VideoItem? {
        let id = r.at("/onTap/innertubeCommand/reelWatchEndpoint/videoId").string
            ?? r["entityId"].string.map { $0.replacingOccurrences(of: "shorts-shelf-item-", with: "") }
        guard let id, !id.isEmpty else { return nil }
        var v = VideoItem(id: id, title: r.at("/overlayMetadata/primaryText/content").string ?? "", thumbnail: bestThumb(r["thumbnail"]) ?? Thumbs.short(id))
        v.viewsText = r.at("/overlayMetadata/secondaryText/content").string
        v.isShort = true
        return v
    }

    public static func lockup(_ l: J) -> Item? {
        if isAd(l) { return nil }
        guard let id = l["contentId"].string else { return nil }
        let ctype = l["contentType"].string ?? ""
        let meta = l.at("/metadata/lockupMetadataViewModel")
        guard !meta.isNull else { return nil }
        let title = meta.at("/title/content").string ?? ""
        var thumbVM = l.at("/contentImage/thumbnailViewModel")
        if thumbVM.isNull { thumbVM = l.at("/contentImage/collectionThumbnailViewModel/primaryThumbnail/thumbnailViewModel") }
        let thumbnail = thumbVM.isNull ? nil : bestThumb(thumbVM["image"])
        var badgeTexts: [String] = []
        if !thumbVM.isNull {
            for b in thumbVM.findAll("thumbnailBadgeViewModel") {
                if let t = b["text"].string { badgeTexts.append(t) }
            }
        }
        var channelName: String?
        var channelId: String?
        var views: String?
        var published: String?
        var others: [String] = []
        for row in meta.at("/metadata/contentMetadataViewModel/metadataRows").array {
            for part in row["metadataParts"].array {
                guard let raw = part.at("/text/content").string else { continue }
                let tx = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if tx.isEmpty { continue }
                let browse = part.find("browseEndpoint")?["browseId"].string
                if let b = browse, b.hasPrefix("UC") {
                    channelName = tx
                    channelId = b
                } else if looksLikeViews(tx) {
                    views = tx
                } else if looksLikeDate(tx) {
                    published = tx
                } else {
                    others.append(tx)
                }
            }
        }
        if channelId == nil {
            channelId = meta.at("/image/decoratedAvatarViewModel/rendererContext/commandContext/onTap/innertubeCommand/browseEndpoint/browseId").string
        }
        let avatar = smallThumb(meta.at("/image/decoratedAvatarViewModel/avatar/avatarViewModel/image"))
        if channelId == nil {
            channelId = l.findAll("browseEndpoint").compactMap { $0["browseId"].string }.first(where: { $0.hasPrefix("UC") })
        }
        if channelName == nil { channelName = others.first }
        switch ctype {
        case "LOCKUP_CONTENT_TYPE_VIDEO", "LOCKUP_CONTENT_TYPE_MUSIC", "LOCKUP_CONTENT_TYPE_SHORT":
            var v = VideoItem(id: id, title: title, thumbnail: thumbnail ?? Thumbs.video(id), channelName: channelName ?? "", channelId: channelId)
            v.isShort = ctype == "LOCKUP_CONTENT_TYPE_SHORT"
            v.isLive = badgeTexts.contains { ["live", "в эфире"].contains($0.lowercased()) }
            v.isUpcoming = badgeTexts.contains { ["upcoming", "скоро"].contains($0.lowercased()) }
            let durationText = badgeTexts.first { Format.parseDuration($0) != nil }
            v.durationText = durationText
            v.durationSecs = durationText.flatMap(Format.parseDuration)
            let pub = published ?? others.first { Format.parseRelative($0) != nil }
            v.publishedText = pub
            v.publishedTs = pub.flatMap(Format.parseRelative)
            v.viewsText = views ?? others.first { $0 != pub && $0 != channelName && ($0.first?.isNumber ?? false) }
            v.channelAvatar = avatar
            return .video(v)
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_COURSE", "LOCKUP_CONTENT_TYPE_SHOW":
            var p = PlaylistItem(id: id, title: title)
            p.thumbnail = thumbnail
            p.channelName = channelName
            p.channelId = channelId
            p.videoCountText = badgeTexts.first
            p.firstVideoId = l.find("watchEndpoint")?["videoId"].string
            return .playlist(p)
        case "LOCKUP_CONTENT_TYPE_CHANNEL":
            return .channel(ChannelItem(id: id, name: title, avatar: thumbnail))
        default:
            return nil
        }
    }

    static func channelRenderer(_ r: J) -> ChannelItem? {
        guard let id = r["channelId"].string else { return nil }
        var c = ChannelItem(id: id, name: r["title"].text, avatar: bestThumb(r["thumbnail"]))
        // in search results "subscriberCountText" often holds the handle and "videoCountText" the subscribers
        let a = r["subscriberCountText"].optText
        let b = r["videoCountText"].optText
        if let a, a.hasPrefix("@") {
            c.handle = a
            c.subscribersText = b
        } else {
            c.subscribersText = a
            c.videoCountText = b
        }
        c.description = r["descriptionSnippet"].optText
        return c
    }

    static func playlistRenderer(_ r: J) -> PlaylistItem? {
        guard let id = r["playlistId"].string else { return nil }
        var p = PlaylistItem(id: id, title: r["title"].text)
        p.thumbnail = bestThumb(r.at("/thumbnails/0")) ?? bestThumb(r["thumbnail"]) ?? bestThumb(r.at("/thumbnailRenderer/playlistVideoThumbnailRenderer/thumbnail"))
        let owner = r["longBylineText"].isNull ? r["shortBylineText"] : r["longBylineText"]
        p.channelName = owner.optText
        p.channelId = owner.at("/runs/0/navigationEndpoint/browseEndpoint/browseId").string
        p.videoCountText = r["videoCountText"].optText ?? r["videoCountShortText"].optText ?? r["videoCount"].string.map { "\($0) видео" }
        p.firstVideoId = r.at("/navigationEndpoint/watchEndpoint/videoId").string
        return p
    }

    /// Parses "0:00 Intro" lines of a description (at least three, starting at 0:00).
    public static func chaptersFromDescription(_ desc: String) -> [Chapter] {
        var out: [Chapter] = []
        for rawLine in desc.split(separator: "\n") {
            let words = rawLine.split(separator: " ").map(String.init)
            var found: (Int, Int)?
            for (i, w) in words.enumerated() {
                let w2 = w.trimmingCharacters(in: CharacterSet(charactersIn: "()[]-"))
                if w2.contains(":"), let secs = Format.parseDuration(w2) { found = (i, secs); break }
                if i > 1 { break }
            }
            if let (idx, secs) = found {
                var title = words.enumerated().filter { $0.offset != idx }.map(\.element).joined(separator: " ")
                while let f = title.first, "-–:|".contains(f) || f.isWhitespace { title.removeFirst() }
                out.append(Chapter(title: title, start: Double(secs)))
            }
        }
        return out.count >= 3 && out[0].start == 0 ? out : []
    }
}
