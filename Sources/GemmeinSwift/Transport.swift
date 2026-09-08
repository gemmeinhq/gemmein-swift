import Foundation

/// This build's version. It tracks the npm SDK's major.minor — the two travel
/// together by law, and the release check pins them equal.
public enum GemmeinSwift {
    public static let version = "0.10.0"

    /// `x-client-info` — what every request tells the engine it is. The
    /// engine's key-usage ledger records it ("last seen from
    /// gemmein-swift/0.10.0 ios"), so a misbehaving build can be attributed
    /// from day one. It is a report, not a proof.
    public static let clientInfo = "gemmein-swift/\(version)"

    /// The platform tag appended to `x-client-info`.
    public static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "swift"
        #endif
    }

    /// The ledger that records this header caps it at 64 characters and strips
    /// control characters, so the value is cleaned and capped HERE: a tag that
    /// arrives truncated attributes nothing.
    public static func clientInfo(platform: String?) -> String {
        guard let platform else { return clientInfo }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        var cleaned = ""
        var lastWasHyphen = false
        for scalar in platform.unicodeScalars {
            if allowed.contains(scalar) { cleaned.unicodeScalars.append(scalar); lastWasHyphen = false }
            else if !lastWasHyphen { cleaned.append("-"); lastWasHyphen = true }
        }
        while cleaned.hasPrefix("-") { cleaned.removeFirst() }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        if cleaned.isEmpty { return clientInfo }
        return String("\(clientInfo) \(cleaned)".prefix(64))
    }
}

/// The default cloud engine.
public let defaultAPIURL = URL(string: "https://api.gemmein.com")!

// ── encoding, mirrored from the wire the JS SDK writes ───────────────────

/// `encodeURIComponent` — what the JS SDK puts in a path segment.
func percentEncodeComponent(_ value: String) -> String {
    // encodeURIComponent leaves A-Za-z0-9 and - _ . ! ~ * ' ( ) alone.
    let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}

/// `URLSearchParams` — what the JS SDK puts in a query string:
/// form-urlencoded, space as `+`, `*` `-` `.` `_` left alone.
func formURLEncode(_ pairs: [(String, String)]) -> String {
    let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
    func encode(_ s: String) -> String {
        (s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s).replacingOccurrences(of: "%20", with: "+")
    }
    return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
}

/// `new URL(pathAndQuery, apiUrl)` — an absolute path replaces the base's.
func makeURL(_ base: URL, _ pathAndQuery: String) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
    let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    components.percentEncodedPath = String(parts[0])
    components.percentEncodedQuery = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    return components.url ?? base
}

// ── the one request path every runtime client shares ─────────────────────

struct ClientConfig: @unchecked Sendable {
    let apiURL: URL
    let appKey: String
    let tokenStore: TokenStore
    let clientInfo: String
    let session: URLSession
}

/// Same headers for every call the client makes: the public key that
/// identifies the app, the build that is calling, and the session that
/// authorises the person when there is one.
func runtimeHeaders(_ config: ClientConfig, _ extra: [String: String] = [:]) async -> [String: String] {
    var headers = extra
    headers["x-app-key"] = config.appKey
    headers["x-client-info"] = config.clientInfo
    if let token = await config.tokenStore.get() { headers["authorization"] = "Bearer \(token)" }
    return headers
}

func makeRequest(_ url: URL, method: String, headers: [String: String], body: Data?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    return request
}

// ── the transport, typed ─────────────────────────────────────────────────

/// W10 row 9, found by driving the reference app with the engine stopped: a
/// transport failure — connection refused, no route, a host that does not
/// resolve, an `apiURL` pointing at nothing — never reaches
/// `handleResponse`, so `URLSession`'s own `URLError` came out of the SDK
/// unchanged. An app branching on `error as? GemmeinError`, which is what
/// every teaching tells it to do, got `nil` there and nowhere else. Every
/// call this package makes goes through `transported` instead, and answers
/// `GemmeinError(status: 0, code: "network_unreachable")` — the JS SDK's
/// own code and sentence.
///
/// Two throws pass through untouched: a cancel — `CancellationError` and
/// `URLError.cancelled` are the caller's own `Task.cancel()`, the same way
/// the JS SDK lets an `AbortError` through — and a `GemmeinError` already
/// typed further in.
func asTransportFailure(_ apiURL: URL, _ error: Error) -> Error {
    if error is CancellationError { return error }
    if let urlError = error as? URLError, urlError.code == .cancelled { return error }
    if let gemmein = error as? GemmeinError { return gemmein }
    return GemmeinError(
        status: 0,
        code: "network_unreachable",
        message: "Gemmein could not be reached — check the connection and the apiUrl (\(apiURL.host ?? apiURL.absoluteString))"
    )
}

/// The one place a `URLSession` throw becomes a Gemmein refusal. Wrap the
/// session call, never the handling that follows it: a refusal the server
/// sent is not a transport failure.
func transported<T>(_ apiURL: URL, _ work: () async throws -> T) async throws -> T {
    do { return try await work() } catch { throw asTransportFailure(apiURL, error) }
}

/// 204 answers with no bytes; anything else with the body. A refusal throws
/// the server's own `code` and sentence.
func handleResponse(_ data: Data, _ response: URLResponse, _ config: ClientConfig?) async throws -> JSONValue? {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 204 { return nil }
    if !(200...299).contains(status) {
        var error = readErrorBody(data, status: status)
        // An expired session is the one refusal that changes local state.
        if error.code == "auth_expired", let config { await config.tokenStore.clear() }
        // Signpost: a wrong or revoked key routes the builder to where a
        // working key comes from, instead of dead-ending.
        if error.code == "invalid_app_key" || error.code == "missing_app_key" {
            error = GemmeinError(
                status: error.status,
                code: error.code,
                message: error.message + " — get your app key from the Setup page at https://app.gemmein.com (sign in with an email code, free, no card)",
                resetAt: error.resetAt,
                requires: error.requires
            )
        }
        throw error
    }
    return JSONCodec.decode(data)
}

/// One request path for every runtime client (auth, subscriptions, payments,
/// account, credits, files) — same headers, same error handling, same
/// signposts.
func runtimeRequest(
    _ config: ClientConfig,
    _ pathAndQuery: String,
    method: String = "GET",
    body: Data? = nil,
    extraHeaders: [String: String] = [:]
) async throws -> JSONValue? {
    let headers = await runtimeHeaders(config, extraHeaders)
    let request = makeRequest(makeURL(config.apiURL, pathAndQuery), method: method, headers: headers, body: body)
    let (data, response) = try await transported(config.apiURL) { try await config.session.data(for: request) }
    return try await handleResponse(data, response, config)
}

/// The one place a shape the SDK promised did not arrive becomes a typed
/// error rather than a crash.
func requireObject(_ value: JSONValue?, _ what: String) throws -> [String: JSONValue] {
    guard let object = value?.object else {
        throw GemmeinError(status: 0, code: "invalid_response", message: "Gemmein answered \(what) in a shape this SDK does not recognise")
    }
    return object
}

let collectionNameRegex = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]{1,62}$")

func assertCollectionName(_ name: String) throws {
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    if collectionNameRegex.firstMatch(in: name, range: range) == nil {
        throw GemmeinError(
            status: 0,
            code: "invalid_collection_name",
            message: "Collection name must be lowercase letters, numbers, and underscores (e.g. \"tasks\", \"user_notes\"). Got: \"\(name)\""
        )
    }
}
