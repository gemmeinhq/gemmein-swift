import Foundation

/// The rig for ring 1: no engine, no network. Every request the SDK makes is
/// captured here and answered from a canned exchange, so the assertions are
/// about the WIRE — the request line, the headers, the body — and not about
/// what a server happened to do.
final class StubURLProtocol: URLProtocol {
    struct Exchange {
        var status: Int = 200
        var headers: [String: String] = ["content-type": "application/json"]
        var body: Data = Data("{}".utf8)
        /// More than one chunk: what a streaming answer arrives as.
        var chunks: [Data]? = nil
        /// No answer at all: the connection is refused, the host does not
        /// resolve, the device is offline. `URLSession` throws instead of
        /// returning, which is the one failure `handleResponse` never sees.
        var failure: URLError? = nil
    }

    struct Captured {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        /// The path AS SENT — `url.path` decodes percent-escapes, which would
        /// let an unescaped path segment pass a byte-for-byte assertion.
        var path: String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path }
        var query: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
        /// The request line as it went out — "POST /storage/notes?key=x".
        var line: String { "\(method) \(path)\(query.map { "?\($0)" } ?? "")" }
        var json: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _exchanges: [Exchange] = []
    nonisolated(unsafe) private static var _captured: [Captured] = []

    /// Queue the answers the next requests get, in order. The last one repeats
    /// if more requests arrive than answers were queued.
    static func queue(_ exchanges: [Exchange]) {
        lock.withLock {
            _exchanges = exchanges
            _captured = []
        }
    }

    static var captured: [Captured] { lock.withLock { _captured } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol never sees `httpBody` for a request URLSession has
        // already turned into a stream — the bytes are only on
        // `httpBodyStream`. Reading the wrong one is how a body assertion
        // silently passes on nil.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            body = collected
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }

        let exchange: Exchange = StubURLProtocol.lock.withLock {
            StubURLProtocol._captured.append(Captured(
                method: request.httpMethod ?? "GET",
                url: request.url!,
                headers: headers,
                body: body
            ))
            if StubURLProtocol._exchanges.isEmpty { return Exchange() }
            if StubURLProtocol._exchanges.count == 1 { return StubURLProtocol._exchanges[0] }
            return StubURLProtocol._exchanges.removeFirst()
        }

        if let failure = exchange.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: exchange.status,
            httpVersion: "HTTP/1.1",
            headerFields: exchange.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in exchange.chunks ?? [exchange.body] {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
