import Foundation

/// The signed-in person's runs — what a JOB tool (kind `generate` ·
/// `transcribe`) answers with. `start` asks the tool for a run and answers at
/// once (202); `watch` polls it to its end; `get` / `list` read; `cancel`
/// releases the hold on an open run. Credits are reserved at the tool's
/// ceiling when the run is created and settled at what the provider metered
/// when it ends; a run that fails, is cancelled, or passes its 60-minute
/// deadline releases the hold. App sessions only — no session is
/// `session_required` (401).
///
///     let run = try await g.runs.start("poster", inputs: ["prompt": .string("a lighthouse at dusk")])
///     let done = try await g.runs.watch(run.id) { progressView.progress = Float($0.progress ?? 0) / 100 }
///     if done.status == .succeeded, let url = done.result?.files.first?.url { imageView.load(url) }
public final class RunsClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Start a run on a job tool. Answers the run as created (202) — credits
    /// reserved at the tool's ceiling, status `queued`. `key` is YOUR dedupe
    /// key (1–80 characters): a second start with the same key answers the
    /// SAME run (the id says so; nothing is reserved twice).
    ///
    /// `ai.run`'s refusals (`unknown_tool` · `tool_disabled` ·
    /// `entitlement_required` · `invalid_inputs` · `ai_not_configured` …),
    /// plus `runs_capped` (429 — 10 open runs per person; end or cancel one)
    /// and `credits_exhausted` (402 — the message names the ceiling).
    // route: POST /ai/run/{tool}
    public func start(_ tool: String, inputs: [String: JSONValue] = [:], key: String? = nil) async throws -> Run {
        var payload: [String: Any] = ["inputs": inputs.mapValues { $0.foundationValue }]
        if let key, !key.isEmpty { payload["key"] = key }
        let body = try requireObject(
            try await runtimeRequest(
                config,
                "/ai/run/\(percentEncodeComponent(tool))",
                method: "POST",
                body: try JSONCodec.encode(payload),
                extraHeaders: ["content-type": "application/json"]
            ),
            "a run"
        )
        return try runFrom(body)
    }

    /// One run, as it is now. `result` is nil until `succeeded`; its file URLs
    /// are minted for this answer and lapse — call again when one does.
    /// `unknown_run` (404) when it is not this person's.
    // route: GET /runs/{id}
    public func get(_ id: String) async throws -> Run {
        let body = try requireObject(try await runtimeRequest(config, "/runs/\(percentEncodeComponent(id))"), "a run")
        return try runFrom(body)
    }

    /// The person's own runs, newest first. `since` narrows to runs updated
    /// after that instant (ISO 8601); `limit` 1…200.
    // route: GET /runs
    public func list(since: String? = nil, limit: Int? = nil) async throws -> [Run] {
        var pairs: [(String, String)] = []
        if let since, !since.isEmpty { pairs.append(("since", since)) }
        if let limit, limit != 0 { pairs.append(("limit", String(limit))) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try requireObject(try await runtimeRequest(config, "/runs\(query)"), "runs")
        return (body["runs"]?.array ?? []).compactMap { $0.object.map { Run(json: $0) } }
    }

    /// `list(since:limit:)` with a `Date` — sent as the same ISO 8601 instant
    /// the JS SDK's `toISOString()` writes.
    // route: GET /runs
    public func list(since: Date, limit: Int? = nil) async throws -> [Run] {
        try await list(since: isoString(since), limit: limit)
    }

    /// Cancel an open run — status `cancelled`, the reservation released.
    /// `run_ended` (409) when it already ended; `unknown_run` (404).
    // route: POST /runs/{id}/cancel
    public func cancel(_ id: String) async throws -> Run {
        let body = try requireObject(
            try await runtimeRequest(config, "/runs/\(percentEncodeComponent(id))/cancel", method: "POST"),
            "a run"
        )
        return try runFrom(body)
    }

    /// Poll a run to its end. Reads `get` every 2 s, backing off ×1.5 to at
    /// most 10 s (or every `intervalMs` when given), calls `onUpdate` on every
    /// answer whose `updatedAt` moved, and returns the run once its status is
    /// `succeeded` · `failed` · `cancelled` · `expired`. Cancelling the
    /// calling `Task` throws `GemmeinError(status: 0, code: "aborted")` — the
    /// JS SDK's aborted `signal`.
    // route: GET /runs/{id}
    public func watch(_ id: String, intervalMs: Int? = nil, onUpdate: (@Sendable (Run) -> Void)? = nil) async throws -> Run {
        let aborted = GemmeinError(status: 0, code: "aborted", message: "watch of run \(id) was aborted")
        var delay = intervalMs ?? 2000
        var lastUpdatedAt: String? = nil
        while true {
            if Task.isCancelled { throw aborted }
            let run: Run
            do { run = try await get(id) } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw aborted }
                throw error
            }
            if run.updatedAt != lastUpdatedAt {
                lastUpdatedAt = run.updatedAt
                onUpdate?(run)
            }
            if run.status.isEnded { return run }
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000) } catch {
                throw GemmeinError(status: 0, code: "aborted", message: "watch was aborted")
            }
            if intervalMs == nil { delay = min(10_000, Int((Double(delay) * 1.5).rounded())) }
        }
    }

    private func runFrom(_ body: [String: JSONValue]) throws -> Run {
        guard let run = body["run"]?.object else {
            throw GemmeinError(status: 0, code: "invalid_response", message: "Gemmein answered a run in a shape this SDK does not recognise")
        }
        return Run(json: run)
    }
}

/// `Date.toISOString()` — UTC, milliseconds, `Z`.
func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}
