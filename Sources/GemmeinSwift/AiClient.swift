import Foundation

/// The provider's own answer, passed back as it came — status, headers and
/// bytes. Streaming stays streaming: read `lines()` as the tokens arrive.
///
/// An answer that carries `creditsRemaining` passed the spend, so its status
/// and body are the PROVIDER's; read `ok` / `status` yourself.
public struct AiResponse: @unchecked Sendable {
    enum Body {
        case buffered(Data)
        case live(URLSession.AsyncBytes)
    }

    public let status: Int
    public let headers: [String: String]
    let body: Body

    public var ok: Bool { (200...299).contains(status) }
    /// `x-gemmein-credits-remaining` — stamped only after the credit moved.
    public var creditsRemaining: Int? { headers["x-gemmein-credits-remaining"].flatMap(Int.init) }
    /// `x-gemmein-credit: refunded` — the provider failed before its first byte.
    public var refunded: Bool { headers["x-gemmein-credit"] == "refunded" }
    /// `x-gemmein-tool` — which named tool answered. Absent on the implicit default.
    public var tool: String? { headers["x-gemmein-tool"] }
    /// `x-gemmein-ai: fake` — a local engine with no provider key answered
    /// from its own echo. The shape is the provider's; the network hop is not.
    public var isFake: Bool { headers["x-gemmein-ai"] == "fake" }

    /// The whole body, collected.
    public func data() async throws -> Data {
        switch body {
        case .buffered(let data): return data
        case .live(let bytes):
            var collected = Data()
            for try await byte in bytes { collected.append(byte) }
            return collected
        }
    }

    /// The answer line by line, as it arrives. SSE frames come through as
    /// `data: …` lines in the order the provider wrote them.
    public func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch body {
                    case .buffered(let data):
                        let text = String(decoding: data, as: UTF8.self)
                        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
                            continuation.yield(String(line))
                        }
                    case .live(let bytes):
                        for try await line in bytes.lines { continuation.yield(line) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The SSE payloads — every `data:` line's content, `[DONE]` dropped.
    public func events() -> AsyncThrowingStream<String, Error> {
        let lines = self.lines()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { continue }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The AI route. The primary path is a NAMED TOOL defined on the server:
/// `run(name, inputs)` sends a name and inputs, the server composes the
/// provider request from the tool's own instructions and template (never the
/// app), gates it, spends the tool's credits and streams the answer back;
/// `runText` is the same call collected to one string; `calls()` is the
/// signed-in person's own history. `chat` is the RAW call — the provider's own
/// request body, off by default (`raw_calls_off`, 403) until the founder
/// switches raw calls on for that provider's key.
///
/// The owner's provider key lives with Gemmein and never reaches the app.
public final class AiClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// The RAW call: the provider's own request body — exactly what you would
    /// POST to OpenAI's `/v1/chat/completions`, Anthropic's `/v1/messages` or
    /// Google's `generateContent` — answered with the provider's own status
    /// and bytes, streaming intact.
    ///
    /// Refusals, all `GemmeinError`: `raw_calls_off` (403 — call a named tool
    /// with `run` instead) · `session_required` (401) · `credits_exhausted`
    /// (402 — show your own "buy more" door, which is a product checkout) ·
    /// `ai_not_configured` (409) · `provider_required` (400) ·
    /// `model_not_allowed` (403) · `ai_capped` (429, `resetAt`) ·
    /// `payload_too_large` (413) · `provider_unreachable` (502, refunded).
    // route: POST /ai/chat
    public func chat(_ body: [String: JSONValue], provider: AiProvider? = nil, tool: String? = nil) async throws -> AiResponse {
        var payload = body.mapValues { $0.foundationValue }
        // The provider rides the body, exactly as the JS SDK sends it.
        if let provider { payload["provider"] = provider.rawValue }
        let query = tool.map { "?tool=\(percentEncodeComponent($0))" } ?? ""
        return try await send("/ai/chat\(query)", body: try JSONCodec.encode(payload))
    }

    /// Run a named tool with INPUTS — the server composes the provider request
    /// from the tool's own instructions and template, gates it, spends its
    /// credits and streams the answer back.
    ///
    ///     let answer = try await g.ai.run("summarise", ["text": .string(text)], stream: true)
    ///     for try await event in answer.events() { … }
    ///
    /// Refusals, all `GemmeinError`: `session_required` (401) · `ai_capped`
    /// (429, `resetAt`) · `unknown_tool` (404) · `tool_disabled` (403) ·
    /// `entitlement_required` (403 — the message names the plan it needs) ·
    /// `payload_too_large` (413) · `invalid_body` / `invalid_inputs` (400) ·
    /// `tool_incomplete` (409) · `ai_not_configured` (409) ·
    /// `credits_exhausted` (402) · `provider_unreachable` (502, refunded).
    // route: POST /ai/run/{tool}
    public func run(_ tool: String, inputs: [String: JSONValue] = [:], stream: Bool = false) async throws -> AiResponse {
        var payload: [String: Any] = ["inputs": inputs.mapValues { $0.foundationValue }]
        if stream { payload["stream"] = true }
        return try await send("/ai/run/\(percentEncodeComponent(tool))", body: try JSONCodec.encode(payload))
    }

    /// `run()` without a stream, as one string — the text lifted out of the
    /// tool's provider's answer. `run()`'s refusals, plus: a provider's own
    /// non-2xx throws `provider_error` with the provider's status and message;
    /// an answer with no text to lift out throws `invalid_response`.
    // route: POST /ai/run/{tool}
    public func runText(_ tool: String, inputs: [String: JSONValue] = [:]) async throws -> String {
        try await lift(await run(tool, inputs: inputs), streamHint: "use run(_:inputs:stream:) and read the stream")
    }

    /// The signed-in person's OWN AI calls, newest first — what they ran,
    /// when, what it cost, how it ended; the prompt and answer only where the
    /// tool keeps them. Session required.
    // route: GET /auth/ai-calls
    public func calls(limit: Int? = nil, before: String? = nil) async throws -> AiCallPage {
        var pairs: [(String, String)] = []
        if let limit { pairs.append(("limit", String(limit))) }
        if let before { pairs.append(("before", before)) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try requireObject(try await runtimeRequest(config, "/auth/ai-calls\(query)"), "an AI call list")
        return AiCallPage(
            calls: (body["calls"]?.array ?? []).compactMap { $0.object.map { AiCallRecord(json: $0) } },
            nextCursor: body["nextCursor"]?.string
        )
    }

    /// The non-streaming convenience on the RAW call: one call, one string.
    /// Pass a body that does NOT stream; the provider's JSON answer is read
    /// whole and the text is lifted out per provider — OpenAI
    /// `choices[0].message.content`, Anthropic `content[].text` joined, Google
    /// `candidates[0].content.parts[].text` joined.
    // route: POST /ai/chat
    public func text(_ body: [String: JSONValue], provider: AiProvider? = nil, tool: String? = nil) async throws -> String {
        try await lift(
            await chat(body, provider: provider, tool: tool),
            streamHint: "for a streaming body use chat(_:) and read the stream"
        )
    }

    // ── internals ────────────────────────────────────────────────────────

    /// The one request path both AI doors share. A refusal is Gemmein's; a
    /// forwarded answer is the provider's and comes back untouched.
    private func send(_ pathAndQuery: String, body: Data) async throws -> AiResponse {
        let headers = await runtimeHeaders(config, ["content-type": "application/json"])
        let request = makeRequest(makeURL(config.apiURL, pathAndQuery), method: "POST", headers: headers, body: body)
        let (bytes, response) = try await transported(config.apiURL) { try await config.session.bytes(for: request) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var fields: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String, let value = value as? String { fields[name.lowercased()] = value }
        }
        if (200...299).contains(status) {
            return AiResponse(status: status, headers: fields, body: .live(bytes))
        }

        // Past the spend, the engine stamps the balance (and, on a refund,
        // `x-gemmein-credit`); a refusal before the spend carries neither.
        var collected = Data()
        for try await byte in bytes { collected.append(byte) }
        let forwarded = fields["x-gemmein-credits-remaining"] != nil || fields["x-gemmein-credit"] != nil
        if forwarded {
            // `provider_unreachable` is the one Gemmein refusal written after
            // the spend — everything else here is the provider's own answer.
            let peek = JSONCodec.decode(collected)?.object?["code"]?.string
            if peek != "provider_unreachable" {
                return AiResponse(status: status, headers: fields, body: .buffered(collected))
            }
        }
        let error = readErrorBody(collected, status: status)
        if error.code == "auth_expired" { await config.tokenStore.clear() }
        throw error
    }

    private func lift(_ response: AiResponse, streamHint: String) async throws -> String {
        let data = try await response.data()
        if !response.ok {
            throw GemmeinError(status: response.status, code: "provider_error", message: providerErrorMessage(data, status: response.status))
        }
        guard let text = extractAiText(JSONCodec.decode(data)) else {
            throw GemmeinError(status: 0, code: "invalid_response", message: "the provider answered without any text — \(streamHint)")
        }
        return text
    }
}

/// The provider's own reason, whichever shape it used — OpenAI, Anthropic and
/// Google all nest it as `error.message`; anything else is the text.
func providerErrorMessage(_ data: Data, status: Int) -> String {
    if let object = JSONCodec.decode(data)?.object {
        if let nested = object["error"]?.object?["message"]?.string { return nested }
        if let plain = object["error"]?.string { return plain }
        if let message = object["message"]?.string { return message }
    }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "the provider answered \(status)" : String(text.prefix(500))
}

/// The per-provider lift, by shape (a provider's answer is unmistakable).
func extractAiText(_ value: JSONValue?) -> String? {
    guard let object = value?.object else { return nil }
    // OpenAI: choices[0].message.content (a string, or content parts)
    if let choices = object["choices"]?.array {
        guard let content = choices.first?.object?["message"]?.object?["content"] else { return nil }
        if let text = content.string { return text }
        if let parts = content.array { return joinTextParts(parts) }
        return nil
    }
    // Anthropic: content[] blocks, the text ones joined
    if let content = object["content"]?.array { return joinTextParts(content) }
    // Google: candidates[0].content.parts[].text joined
    if let candidates = object["candidates"]?.array {
        guard let parts = candidates.first?.object?["content"]?.object?["parts"]?.array else { return nil }
        return joinTextParts(parts)
    }
    return nil
}

private func joinTextParts(_ parts: [JSONValue]) -> String? {
    let texts = parts.compactMap { $0.object?["text"]?.string }
    return texts.isEmpty ? nil : texts.joined()
}
