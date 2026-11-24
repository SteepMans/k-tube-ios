import Foundation

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Double

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: Double = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
    public var json: J { J.parse(body) }

    public func header(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.key.lowercased() == n }?.value
    }
}

/// The app sends everything through the gateway; tests and the CI screenshots use plain URLSession.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct KTubeError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public extension HTTPClient {
    func get(_ url: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(HTTPRequest(url: url, headers: headers))
    }

    func getOK(_ url: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let r = try await get(url, headers: headers)
        guard r.status < 400 else { throw KTubeError("HTTP \(r.status)") }
        return r
    }

    func postJSON(_ url: String, _ body: [String: Any], headers: [String: String] = [:]) async throws -> J {
        var h = headers
        h["Content-Type"] = "application/json"
        let r = try await send(HTTPRequest(url: url, method: "POST", headers: h, body: JSONBody.data(body)))
        let j = r.json
        guard r.status < 400 else {
            let msg = j.at("/error/message").string ?? "HTTP \(r.status)"
            throw KTubeError(msg)
        }
        return j
    }
}

public enum URLCoding {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    public static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    public static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    /// Query parameters of a URL string (last one wins).
    public static func query(_ url: String) -> [String: String] {
        guard let q = url.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for kv in q.split(separator: "#").first?.split(separator: "&") ?? [] {
            let p = kv.split(separator: "=", maxSplits: 1)
            guard let k = p.first else { continue }
            out[decode(String(k))] = p.count > 1 ? decode(String(p[1])) : ""
        }
        return out
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// A value behind a lock, usable from async code (the lock is held only inside the closure).
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ value: T) { self.value = value }
    @discardableResult
    public func with<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
    public var get: T { with { $0 } }
}
