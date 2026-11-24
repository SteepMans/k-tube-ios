import Foundation
import Network

/// The local server on 127.0.0.1:
/// - `CONNECT host:443` from the app's URLSession: the connection is opened on the gateway and bytes are copied;
/// - `GET /hls/<url>/master.m3u8?q=..&f=..&a=..` and `GET /m/<url>/<name>` from AVPlayer: playlists and segments are
///   fetched through the gateway session, playlists are rewritten so every URI comes back here.
final class LocalServer: @unchecked Sendable {
    private var listener: NWListener?
    private let portBox = Locked<UInt16?>(nil)
    private weak var gateway: GatewayService?
    private let queue = DispatchQueue(label: "ktube.server", qos: .userInitiated, attributes: .concurrent)

    var port: UInt16? { portBox.get }

    func start(gateway: GatewayService) {
        self.gateway = gateway
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                self?.portBox.with { $0 = l.port?.rawValue }
                ready.signal()
            case .failed:
                ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { c.cancel(); return }
            c.start(queue: self.queue)
            Task.detached(priority: .userInitiated) { await self.serve(c) }
        }
        l.start(queue: queue)
        listener = l
        // the port is needed right away by the URLSession configuration
        _ = ready.wait(timeout: .now() + 3)
    }

    /// If iOS took the listener away while in the background, start again on the next activation.
    func restartIfNeeded() {
        guard let l = listener else { return }
        if case .failed = l.state {
            listener = nil
            portBox.with { $0 = nil }
            if let g = gateway { start(gateway: g) }
        }
    }

    func mediaURL(_ remote: String, name: String = "x") -> String {
        "http://127.0.0.1:\(port ?? 0)/m/\(Base64URL.encode(Data(remote.utf8)))/\(name)"
    }

    /// The master playlist with a chosen quality (0 = every quality), frame rate and audio rendition.
    func masterURL(_ remote: String, quality: Int, fps: Int, audio: String?, av1: Bool) -> URL? {
        var s = "http://127.0.0.1:\(port ?? 0)/hls/\(Base64URL.encode(Data(remote.utf8)))/master.m3u8?q=\(quality)&f=\(fps)&av1=\(av1 ? 1 : 0)"
        if let audio { s += "&a=\(Base64URL.encode(Data(audio.utf8)))" }
        return URL(string: s)
    }

    // MARK: serving

    private func serve(_ c: NWConnection) async {
        var pending = Data()
        // keep-alive: AVPlayer sends several requests on one connection
        while true {
            let head: String
            do {
                if let r = pending.range(of: Data("\r\n\r\n".utf8)) {
                    head = String(decoding: pending[pending.startIndex..<r.upperBound], as: UTF8.self)
                    pending = Data(pending[r.upperBound...])
                } else {
                    let (h, rest) = try await Tunnel.readHead(c, timeout: 120)
                    head = String(decoding: pending, as: UTF8.self) + h
                    pending = rest
                }
            } catch {
                c.cancel()
                return
            }
            let lines = head.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ").map(String.init)
            guard parts.count >= 2 else { await reply(c, "400 Bad Request"); c.cancel(); return }
            let method = parts[0].uppercased(), target = parts[1]
            var headers: [String: String] = [:]
            for l in lines.dropFirst() where l.contains(":") {
                let kv = l.split(separator: ":", maxSplits: 1)
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
            }
            if method == "CONNECT" {
                await connect(c, target: target, early: pending)
                return
            }
            if target.hasPrefix("http://") {
                await forwardPlain(c, method: method, target: target, head: lines, early: pending)
                return
            }
            if method == "GET" || method == "HEAD" {
                let keep = await media(c, target: target, headers: headers, head: method == "HEAD")
                if !keep { c.cancel(); return }
                continue
            }
            await reply(c, "405 Method Not Allowed")
            c.cancel()
            return
        }
    }

    private func reply(_ c: NWConnection, _ status: String, close: Bool = true) async {
        let s = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\(close ? "Connection: close\r\n" : "")\r\n"
        try? await Tunnel.send(c, Data(s.utf8))
    }

    private func connect(_ c: NWConnection, target: String, early: Data) async {
        guard let g = gateway, let (host, port) = Gateway.splitHostPort(target, defaultPort: 443) else {
            await reply(c, "400 Bad Request"); c.cancel(); return
        }
        do {
            let (up, siteBytes) = try await g.connect(host: host, port: port)
            try await Tunnel.send(c, Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            if !early.isEmpty { try await Tunnel.send(up, early) }
            if !siteBytes.isEmpty { try await Tunnel.send(c, siteBytes) }
            g.stats.with { $0.active += 1 }
            Tunnel.pump(c, up, onBytes: { u, d in
                g.stats.with { $0.up += Int64(u); $0.down += Int64(d) }
            }, onClose: {
                g.stats.with { $0.active -= 1 }
            })
        } catch let r as Gateway.Refusal {
            await reply(c, Gateway.localStatus(r))
            c.cancel()
        } catch {
            await reply(c, "502 Bad Gateway")
            c.cancel()
        }
    }

    /// Plain HTTP in absolute form (http://host/path): rare, sent as is to port 80 of the host.
    private func forwardPlain(_ c: NWConnection, method: String, target: String, head: [String], early: Data) async {
        guard let g = gateway else { c.cancel(); return }
        let rest = target.dropFirst("http://".count)
        let auth = String(rest.prefix { $0 != "/" })
        let path = rest.dropFirst(auth.count)
        guard let (host, port) = Gateway.splitHostPort(auth, defaultPort: 80) else { await reply(c, "400 Bad Request"); c.cancel(); return }
        var out = "\(method) \(path.isEmpty ? "/" : String(path)) HTTP/1.1\r\n"
        for l in head.dropFirst() where !l.isEmpty {
            let k = l.split(separator: ":").first.map { $0.lowercased() } ?? ""
            if k != "proxy-connection" && k != "proxy-authorization" { out += l + "\r\n" }
        }
        out += "\r\n"
        do {
            let (up, siteBytes) = try await g.connect(host: host, port: port)
            var first = Data(out.utf8)
            first.append(early)
            try await Tunnel.send(up, first)
            if !siteBytes.isEmpty { try await Tunnel.send(c, siteBytes) }
            Tunnel.pump(c, up, onBytes: { _, _ in }, onClose: {})
        } catch {
            await reply(c, "502 Bad Gateway")
            c.cancel()
        }
    }

    /// Serves one media request; returns whether the connection stays open.
    private func media(_ c: NWConnection, target: String, headers: [String: String], head: Bool) async -> Bool {
        guard let g = gateway else { return false }
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let comps = pathAndQuery[0].split(separator: "/").map(String.init)
        guard comps.count >= 2, comps[0] == "m" || comps[0] == "hls", let raw = Base64URL.decode(comps[1]) else {
            await reply(c, "404 Not Found", close: false)
            return true
        }
        let remote = String(decoding: raw, as: UTF8.self)
        let q = pathAndQuery.count > 1 ? URLCoding.query("?" + pathAndQuery[1]) : [:]
        guard let url = URL(string: remote) else { await reply(c, "400 Bad Request", close: false); return true }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(UA.browser, forHTTPHeaderField: "User-Agent")
        if let range = headers["range"] { req.setValue(range, forHTTPHeaderField: "Range") }
        do {
            let (data, resp) = try await g.session.data(for: req)
            guard let h = resp as? HTTPURLResponse else { throw KTubeError("пустой ответ") }
            var body = data
            var contentType = h.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            if h.statusCode < 400, HLS.isPlaylist(contentType: contentType, url: remote, body: data) {
                let text = String(decoding: data, as: UTF8.self)
                let quality = Int(q["q"] ?? "") ?? 0
                let fps = Int(q["f"] ?? "") ?? 0
                let audio = q["a"].flatMap { Base64URL.decode($0) }.map { String(decoding: $0, as: UTF8.self) }
                let av1 = q["av1"] == "1"
                let keep: ((Variant) -> Bool)? = comps[0] == "hls" && quality > 0 ? { v in
                    v.qualityClass == quality && (fps == 0 || v.fps == fps)
                } : nil
                var rewritten = HLS.rewrite(text, base: remote, av1: av1, keep: keep, audio: audio) { self.mediaURL($0, name: Self.name(for: $0)) }
                // the chosen quality is missing (another frame rate): keep every one
                if keep != nil, !rewritten.contains("#EXT-X-STREAM-INF") {
                    rewritten = HLS.rewrite(text, base: remote, av1: av1, keep: nil, audio: audio) { self.mediaURL($0, name: Self.name(for: $0)) }
                }
                body = Data(rewritten.utf8)
                contentType = "application/vnd.apple.mpegurl"
            }
            var out = "HTTP/1.1 \(h.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: h.statusCode).capitalized)\r\n"
            out += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n"
            if let cr = h.value(forHTTPHeaderField: "Content-Range") { out += "Content-Range: \(cr)\r\n" }
            out += "Accept-Ranges: bytes\r\n\r\n"
            var payload = Data(out.utf8)
            if !head { payload.append(body) }
            try await Tunnel.send(c, payload)
            return true
        } catch {
            await reply(c, "502 Bad Gateway")
            return false
        }
    }

    /// A file name for AVPlayer: playlists end in .m3u8, the rest keep a neutral name.
    static func name(for url: String) -> String {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        if path.hasSuffix(".m3u8") || path.contains("/hls_playlist/") || path.contains("/hls_variant/") || path.contains("/playlist/") { return "index.m3u8" }
        if path.hasSuffix(".mp4") { return "seg.mp4" }
        if path.hasSuffix(".ts") { return "seg.ts" }
        return "seg"
    }
}
