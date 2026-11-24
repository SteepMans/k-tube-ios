import Foundation
import Network

/// One TCP connection to a site, opened on the gateway: TLS to the gateway, `GET /v1/proxy` with Upgrade tcp/1 and
/// the key, then raw bytes in both directions (docs/proxy-v1.md in SteepMans/api-gateway).
enum Tunnel {
    static let queue = DispatchQueue(label: "ktube.tunnel", qos: .userInitiated, attributes: .concurrent)

    /// Waits until the connection is ready (or fails).
    static func ready(_ c: NWConnection, timeout: Double = 15) async throws {
        let done = Locked(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            func finish(_ r: Result<Void, Error>) {
                let first = done.with { d -> Bool in
                    if d { return false }
                    d = true
                    return true
                }
                if first { cont.resume(with: r) }
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): finish(.failure(e))
                case .cancelled: finish(.failure(KTubeError("соединение закрыто")))
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(KTubeError("шлюз не отвечает")))
            }
        }
        c.stateUpdateHandler = nil
    }

    static func send(_ c: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    static func receive(_ c: NWConnection, max: Int = 65536) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            c.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, e in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if let e { cont.resume(throwing: e) }
                else if complete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    /// Reads up to the blank line; returns the head and whatever came after it.
    static func readHead(_ c: NWConnection, limit: Int = 65536, timeout: Double = 30) async throws -> (String, Data) {
        var buf = Data()
        let sep = Data("\r\n\r\n".utf8)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard Date() < deadline else { throw KTubeError("нет ответа") }
            guard let chunk = try await receive(c) else { throw KTubeError("соединение закрыто") }
            buf.append(chunk)
            if let r = buf.range(of: sep) {
                let head = String(decoding: buf[buf.startIndex..<r.upperBound], as: UTF8.self)
                return (head, Data(buf[r.upperBound...]))
            }
            if buf.count > limit { throw KTubeError("слишком длинный заголовок") }
        }
    }

    /// Opens host:port on the gateway. Returns the connection after 101 and bytes of the site that came with it.
    static func open(gatewayHost: String, token: String, client: String, host: String, port: Int) async throws -> (NWConnection, Data) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        let c = NWConnection(host: NWEndpoint.Host(gatewayHost), port: 443, using: params)
        do {
            try await ready(c)
            try await send(c, Gateway.proxyRequest(gatewayHost: gatewayHost, token: token, client: client, target: host, port: port))
            let (head, rest) = try await readHead(c, limit: 8192, timeout: 30)
            switch Gateway.parseAnswer(head: head, body: String(decoding: rest.prefix(256), as: UTF8.self), target: host) {
            case .success: return (c, rest)
            case .failure(let r): throw r
            }
        } catch {
            c.cancel()
            throw error
        }
    }

    /// Plain TCP to the site (debug builds in CI abroad, never in a release).
    static func direct(host: String, port: Int) async throws -> NWConnection {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 443, using: .tcp)
        do {
            try await ready(c)
            return c
        } catch {
            c.cancel()
            throw error
        }
    }

    /// Copies bytes both ways until either side closes; counts bytes.
    static func pump(_ a: NWConnection, _ b: NWConnection, onBytes: @escaping @Sendable (Int, Int) -> Void, onClose: @escaping @Sendable () -> Void) {
        let closed = Locked(0)
        let finish: @Sendable () -> Void = {
            let n = closed.with { v -> Int in
                v += 1
                return v
            }
            if n == 2 {
                a.cancel()
                b.cancel()
                onClose()
            }
        }
        pipe(from: a, to: b, up: true, onBytes: onBytes, done: finish)
        pipe(from: b, to: a, up: false, onBytes: onBytes, done: finish)
    }

    private static func pipe(from: NWConnection, to: NWConnection, up: Bool, onBytes: @escaping @Sendable (Int, Int) -> Void, done: @escaping @Sendable () -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty {
                onBytes(up ? data.count : 0, up ? 0 : data.count)
                to.send(content: data, completion: .contentProcessed { e in
                    if e != nil {
                        from.cancel()
                        to.cancel()
                        done()
                    } else if complete {
                        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                        done()
                    } else {
                        pipe(from: from, to: to, up: up, onBytes: onBytes, done: done)
                    }
                })
                return
            }
            if complete || error != nil {
                if error != nil {
                    from.cancel()
                    to.cancel()
                } else {
                    to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
                done()
                return
            }
            pipe(from: from, to: to, up: up, onBytes: onBytes, done: done)
        }
    }
}
