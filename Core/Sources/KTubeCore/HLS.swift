import Foundation

/// HLS playlists: the quality menu from a master playlist, and rewriting every URI to the local media server so
/// AVPlayer fetches all of it through the gateway.
public enum HLS {
    public static func attr(_ line: String, _ key: String) -> String? {
        // attribute list after the colon: KEY=value or KEY="value", comma separated
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var rest = Substring(line[line.index(after: colon)...])
        while !rest.isEmpty {
            guard let eq = rest.firstIndex(of: "=") else { return nil }
            let k = rest[..<eq].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: eq)...]
            var value: String
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let end = rest.firstIndex(of: "\"") ?? rest.endIndex
                value = String(rest[..<end])
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
                if rest.first == "," { rest = rest.dropFirst() }
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = String(rest[..<end])
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
            }
            if k == key { return value }
            value = ""
        }
        return nil
    }

    public static func isHDR(_ codecs: String) -> Bool {
        let c = codecs.lowercased()
        return c.contains("vp09.02") || c.contains("av01.0.") && c.contains(".10.") || c.contains("hvc1.2") || c.contains("hev1.2") || c.contains("dvh1")
    }

    /// Codecs AVPlayer decodes on iPhone: H.264 and HEVC always, AV1 only with hardware support.
    public static func playable(_ codecs: String, av1: Bool) -> Bool {
        let c = codecs.lowercased()
        if c.isEmpty { return true }
        if c.contains("vp09") || c.contains("vp9") { return false }
        if c.contains("av01") { return av1 }
        return true
    }

    /// Qualities (one per resolution and frame rate: SDR over HDR, then the higher bitrate) and audio renditions.
    public static func parseMaster(_ text: String, av1: Bool = false) -> ([Variant], [AudioTrack]) {
        var out: [Variant] = []
        var audio: [AudioTrack] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.hasPrefix("#EXT-X-MEDIA"), attr(l, "TYPE") == "AUDIO", let name = attr(l, "NAME") {
                if !audio.contains(where: { $0.name == name }) {
                    audio.append(AudioTrack(name: name, language: attr(l, "LANGUAGE") ?? "", isOriginal: name.lowercased().contains("original") || name.lowercased().contains("оригинал"), url: attr(l, "URI") ?? ""))
                }
            } else if l.hasPrefix("#EXT-X-STREAM-INF"), i + 1 < lines.count {
                let url = lines[i + 1].trimmingCharacters(in: .whitespaces)
                i += 1
                let res = (attr(l, "RESOLUTION") ?? "").split(separator: "x").compactMap { Int($0) }
                let w = res.count == 2 ? res[0] : 0, h = res.count == 2 ? res[1] : 0
                let fps = Int(Double(attr(l, "FRAME-RATE") ?? "") ?? 0)
                let bw = Int(attr(l, "BANDWIDTH") ?? "") ?? 0
                let codecs = attr(l, "CODECS") ?? ""
                guard playable(codecs, av1: av1) else { i += 1; continue }
                let v = Variant(url: url, width: w, height: h, fps: fps, bandwidth: bw, codecs: codecs)
                if let idx = out.firstIndex(where: { $0.qualityClass == v.qualityClass && $0.fps == fps }) {
                    let a = (!isHDR(codecs), bw), b = (!isHDR(out[idx].codecs), out[idx].bandwidth)
                    if (a.0 ? 1 : 0, a.1) > (b.0 ? 1 : 0, b.1) { out[idx] = v }
                } else {
                    out.append(v)
                }
            }
            i += 1
        }
        out.sort { ($0.qualityClass, $0.fps, $0.bandwidth) > ($1.qualityClass, $1.fps, $1.bandwidth) }
        return (out, audio)
    }

    public static func resolve(_ uri: String, base: String) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
        guard let b = URL(string: base), let u = URL(string: uri, relativeTo: b) else { return uri }
        return u.absoluteString
    }

    /// Rewrites a playlist for the local server.
    /// - keep: for a master playlist, which variant URLs stay (nil keeps every playable one).
    /// - audio: the NAME of the audio rendition to make the default.
    public static func rewrite(_ text: String, base: String, av1: Bool = false, keep: ((Variant) -> Bool)? = nil, audio: String? = nil, proxify: (String) -> String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            var l = lines[i]
            if l.hasPrefix("#EXT-X-STREAM-INF"), i + 1 < lines.count {
                let uri = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let res = (attr(l, "RESOLUTION") ?? "").split(separator: "x").compactMap { Int($0) }
                let v = Variant(url: uri, width: res.count == 2 ? res[0] : 0, height: res.count == 2 ? res[1] : 0,
                                fps: Int(Double(attr(l, "FRAME-RATE") ?? "") ?? 0), bandwidth: Int(attr(l, "BANDWIDTH") ?? "") ?? 0,
                                codecs: attr(l, "CODECS") ?? "")
                if playable(v.codecs, av1: av1), keep?(v) ?? true {
                    out.append(rewriteURIAttr(l, base: base, proxify: proxify))
                    out.append(proxify(resolve(uri, base: base)))
                }
                i += 2
                continue
            }
            if l.hasPrefix("#EXT-X-MEDIA"), let audio, attr(l, "TYPE") == "AUDIO", let name = attr(l, "NAME") {
                let def = name == audio ? "YES" : "NO"
                if l.contains("DEFAULT=") {
                    l = l.replacingOccurrences(of: "DEFAULT=YES", with: "DEFAULT=\(def)").replacingOccurrences(of: "DEFAULT=NO", with: "DEFAULT=\(def)")
                } else {
                    l += ",DEFAULT=\(def)"
                }
            }
            if l.hasPrefix("#") {
                out.append(l.contains("URI=\"") ? rewriteURIAttr(l, base: base, proxify: proxify) : l)
            } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(l)
            } else {
                out.append(proxify(resolve(l.trimmingCharacters(in: .whitespaces), base: base)))
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }

    static func rewriteURIAttr(_ line: String, base: String, proxify: (String) -> String) -> String {
        guard let r = line.range(of: "URI=\"") else { return line }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<end])
        return String(line[..<r.upperBound]) + proxify(resolve(uri, base: base)) + String(rest[end...])
    }

    public static func isPlaylist(contentType: String?, url: String, body: Data) -> Bool {
        if let ct = contentType?.lowercased(), ct.contains("mpegurl") { return true }
        if url.contains(".m3u8") || url.contains("/hls_playlist/") || url.contains("/hls_variant/") || url.contains("/playlist/index.m3u8") { return true }
        return body.starts(with: Data("#EXTM3U".utf8))
    }
}
