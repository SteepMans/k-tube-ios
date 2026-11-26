import Foundation
import Network

/// All network traffic of the app goes through the external proxy gateway with the user's key, like the desktop K-Tube:
/// URLSession is pointed at a local proxy (127.0.0.1) and every CONNECT becomes a connection on the gateway. AVPlayer
/// gets the video from the same local server, which fetches playlists and segments through that session.
final class GatewayService: @unchecked Sendable, HTTPClient {
    static let shared = GatewayService()

    struct Stats: Sendable, Equatable {
        var active = 0
        var opened = 0
        var failed = 0
        var refused = 0
        var down: Int64 = 0
        var up: Int64 = 0
    }

    struct Config: Sendable {
        var token = ""
        var gatewayURL = ""
        /// debug builds only: straight to the sites (screenshots in CI abroad)
        var direct = false
    }

    let config = Locked(Config())
    let stats = Locked(Stats())
    let lastError = Locked<(Date, String)?>(nil)
    /// Refusals the user must see (no exit for YouTube, key not accepted): serial and text.
    let notice = Locked<(Int, String, Date?)>((0, "", nil))
    let server = LocalServer()
    private let sessionBox = Locked<URLSession?>(nil)

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var builtInGateway: String {
        (Bundle.main.object(forInfoDictionaryKey: "KTubeGatewayURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    var clientHeader: String { Gateway.clientHeader(version: GatewayService.version) }

    /// The gateway's https://host: built in at build time, or the one from the user's link.
    var gatewayURL: String? {
        let built = GatewayService.builtInGateway
        return Gateway.normalize(built.isEmpty || built.hasPrefix("$(") ? config.get.gatewayURL : built)
    }

    var gatewayHost: String? { gatewayURL.flatMap(Gateway.host(of:)) }

    var isConfigured: Bool {
        let c = config.get
        return c.direct || (Gateway.validToken(c.token) && gatewayHost != nil)
    }

    func start() {
        server.start(gateway: self)
    }

    func configure(token: String, gatewayURL: String, direct: Bool) {
        config.with {
            $0.token = token
            $0.gatewayURL = gatewayURL
            $0.direct = direct
        }
        sessionBox.with { s in
            s?.invalidateAndCancel()
            s = nil
        }
    }

    /// URLSession whose connections all go through the local proxy.
    var session: URLSession {
        if let s = sessionBox.get { return s }
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        if let port = server.port {
            c.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(port),
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(port),
            ]
        }
        let s = URLSession(configuration: c)
        sessionBox.with { $0 = s }
        return s
    }

    // MARK: HTTPClient

    func send(_ r: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: r.url) else { throw KTubeError("Неверный адрес") }
        if !config.get.direct {
            guard isConfigured else { throw KTubeError("Нет ключа шлюза") }
        }
        var req = URLRequest(url: url)
        req.httpMethod = r.method
        req.httpBody = r.body
        req.timeoutInterval = r.timeout
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue(UA.browser, forHTTPHeaderField: "User-Agent") }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let h = resp as? HTTPURLResponse else { throw KTubeError("Пустой ответ") }
            var headers: [String: String] = [:]
            for (k, v) in h.allHeaderFields { headers["\(k)"] = "\(v)" }
            return HTTPResponse(status: h.statusCode, headers: headers, body: data)
        } catch let e as URLError {
            throw KTubeError(explain(e))
        }
    }

    /// The user-facing reason of a failed request: the gateway's refusal when there was one.
    func explain(_ e: URLError) -> String {
        if case let (at, text)? = lastError.get, Date().timeIntervalSince(at) < 20 { return "Шлюз: \(text)" }
        switch e.code {
        case .notConnectedToInternet: return "Нет интернета"
        case .timedOut: return "Шлюз не ответил вовремя"
        case .cancelled: return "Отменено"
        default: return "Сеть: \(e.localizedDescription)"
        }
    }

    func recordRefusal(_ r: Gateway.Refusal, host: String) {
        lastError.with { $0 = (Date(), r.text) }
        stats.with { $0.failed += 1 }
        if r.important {
            notice.with { n in
                if n.1 == r.text, let t = n.2, Date().timeIntervalSince(t) < 60 { return }
                n = (n.0 + 1, r.text, Date())
            }
        }
    }

    // MARK: the gateway's own API (direct, not through the local proxy)

    func info() async throws -> Gateway.Info {
        let c = config.get
        guard Gateway.validToken(c.token) else { throw KTubeError("Ключ должен начинаться с tc_ и быть длиной 46 символов") }
        guard let base = gatewayURL, let url = URL(string: base + "/v1/info") else { throw KTubeError("Не задан адрес шлюза") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientHeader, forHTTPHeaderField: Gateway.clientHeaderName)
        let t = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw KTubeError("Ключ не принят шлюзом (отозван или опечатка)") }
        guard status == 200 else { throw KTubeError("Шлюз ответил \(status)") }
        return Gateway.parseInfo(J.parse(data), rttMs: Int(Date().timeIntervalSince(t) * 1000))
    }

    // MARK: connections for the local proxy

    /// Opens host:port: on the gateway, or straight in a debug build with direct mode.
    func connect(host: String, port: Int) async throws -> (NWConnection, Data) {
        let c = config.get
        if c.direct {
            return (try await Tunnel.direct(host: host, port: port), Data())
        }
        guard Gateway.route(host) == .gateway else {
            stats.with { $0.refused += 1 }
            throw Gateway.Refusal(status: 403, text: "\(host) не входит в список шлюза")
        }
        guard Gateway.validToken(c.token), let gw = gatewayHost else {
            throw Gateway.Refusal(status: 407, text: "нет ключа шлюза")
        }
        do {
            let r = try await Tunnel.open(gatewayHost: gw, token: c.token, client: clientHeader, host: host, port: port)
            stats.with { $0.opened += 1 }
            return r
        } catch let r as Gateway.Refusal {
            recordRefusal(r, host: host)
            throw r
        } catch {
            let r = Gateway.Refusal(status: 502, text: "шлюз недоступен: \(error.localizedDescription)")
            recordRefusal(r, host: host)
            throw r
        }
    }
}
