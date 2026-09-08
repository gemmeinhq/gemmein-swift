import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// A `watch()` delivery. `initial == true`: REPLACE your state — `records` IS
/// the full current set, and replacing is what clears anything removed while
/// you weren't looking. `initial == false`: upsert `records` by id (a change
/// can arrive twice, never be missed) and remove the ids in `deleted`.
public struct WatchDelta: Sendable, Equatable {
    public let records: [GemmeinRecord]
    public let deleted: [String]
    public let initial: Bool
}

/// A running `watch()`. Call `stop()` when the screen goes away.
public final class Watcher: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init() {}

    func attach(task: Task<Void, Never>, observers: [NSObjectProtocol]) {
        lock.lock()
        let alreadyStopped = stopped
        if alreadyStopped {
            lock.unlock()
            task.cancel()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            return
        }
        self.task = task
        self.observers = observers
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let task = self.task
        let observers = self.observers
        self.task = nil
        self.observers = []
        lock.unlock()
        task?.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    deinit { stop() }
}

/// Talks to one collection. Collections themselves are created by the app
/// owner in their dashboard (app.gemmein.com → data) — a 404
/// `unknown_collection` means it doesn't exist yet: ask the owner to create it
/// there, don't retry.
public final class CollectionClient: @unchecked Sendable {
    private let config: ClientConfig
    private let name: String
    private let intent: String?

    init(config: ClientConfig, name: String, intent: String?) {
        self.config = config
        self.name = name
        self.intent = intent
    }

    /// Create a record from your fields. The signed-in person becomes its owner.
    ///
    /// For anything two people can race for (a booking slot, a unique slug, a
    /// limited drop), pass a deterministic `key` derived from the thing that
    /// must be unique: `create(data, key: "slot:2026-07-15T15:00")`. The second
    /// writer gets a 409 `conflict` — that error IS the booking system working.
    /// Your own retry with the same key returns the record you already made
    /// (`existing == true`) instead of a duplicate.
    ///
    /// On `addressed` and `direct` collections every create names its
    /// recipient: `create(data, for: userId)`. On the PUBLIC rules pass
    /// `published: false` to save a draft the public can't see.
    // route: POST /storage/{collection}
    @discardableResult
    public func create(
        _ data: [String: JSONValue],
        key: String? = nil,
        for recipient: String? = nil,
        published: Bool? = nil
    ) async throws -> GemmeinRecord {
        var pairs: [(String, String)] = []
        if let key { pairs.append(("key", key)) }
        if let recipient { pairs.append(("for", recipient)) }
        if let published { pairs.append(("published", published ? "true" : "false")) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try await request(query, method: "POST", body: try JSONCodec.encode(data))
        return GemmeinRecord(json: try requireObject(body, "a record"))
    }

    /// List records this person is allowed to see under the collection's
    /// safety rule (the app owner sees everyone's).
    // route: GET /storage/{collection}
    public func list(_ options: ListOptions = ListOptions()) async throws -> ListResult {
        let pairs = options.queryPairs
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        return ListResult(json: try requireObject(try await request(query), "a list"))
    }

    /// Live-enough, honestly. Explicitly POLLING: a full list first, then
    /// "what changed?" every `every` seconds (default 10, floor 5) through
    /// exactly the same permission gate as `list()`. Nothing is pushed.
    ///
    ///     let w = try g.collection("orders").watch { delta in … }
    ///     // later: w.stop()
    ///
    /// On iOS it sleeps while the app is backgrounded and does a full resync
    /// on return. On errors it backs off, doubling up to 60s, and honours a
    /// rate limit's reset time. An auth refusal STOPS the watch — a signed-out
    /// watcher polling forever writes a denied-audit row per attempt on the
    /// server; start a fresh watch after signing in.
    // route: GET /storage/{collection}
    public func watch(
        every: TimeInterval? = nil,
        where filter: [String: JSONValue]? = nil,
        search: String? = nil,
        limit: Int? = nil,
        onChange: @escaping @Sendable (WatchDelta) -> Void
    ) -> Watcher {
        let interval = min(300, max(5, every ?? 10))
        let base = ListOptions(limit: limit ?? 100, where: filter, search: search)
        let watcher = Watcher()
        let state = WatchState()

        let task = Task<Void, Never> {
            var delay = interval
            var resync = true
            while !Task.isCancelled {
                while state.hiddenValue, !Task.isCancelled {
                    // Woken by the foreground observer; a wake always resyncs.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if state.takeWakeRequest() { resync = true; delay = interval }
                if Task.isCancelled { return }
                do {
                    let page = try await self.page(base: base, since: resync ? nil : state.watermarkValue)
                    if Task.isCancelled { return }
                    if let mark = page.mark { state.watermarkValue = mark }
                    delay = interval
                    if resync || !page.records.isEmpty || !page.deleted.isEmpty {
                        onChange(WatchDelta(records: page.records, deleted: page.deleted, initial: resync))
                    }
                    resync = false
                } catch let error as GemmeinError {
                    if error.status == 401 || error.status == 403 { return }
                    delay = min(max(delay * 2, interval), 60)
                    if let resetAt = error.resetAt, let until = ISO8601DateFormatter().date(from: resetAt) {
                        let wait = until.timeIntervalSinceNow
                        if wait > delay { delay = min(wait, 300) }
                    }
                } catch {
                    delay = min(max(delay * 2, interval), 60)
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        var observers: [NSObjectProtocol] = []
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            state.hiddenValue = true
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            state.hiddenValue = false
            state.requestWake()
        })
        #endif
        watcher.attach(task: task, observers: observers)
        return watcher
    }

    // route: GET /storage/{collection}/{id}
    public func get(_ id: String, expand: [String] = []) async throws -> GemmeinRecord {
        let query = expand.isEmpty ? "" : "?expand=\(percentEncodeComponent(expand.joined(separator: ",")))"
        return GemmeinRecord(json: try requireObject(try await request("/\(percentEncodeComponent(id))\(query)"), "a record"))
    }

    /// Merge-updates `data` fields; returns the full updated record.
    ///
    /// Counters people race for (stock, seats) must never be computed on the
    /// device — put an atomic op in value position and the server does the
    /// math on current state: `update(id, ["stock": ["decrement": 1, "floor": 0]])`.
    /// Breaching the floor is a 409 `conflict` ("out of stock" — the limit
    /// working, not a bug). When different people can edit the same record,
    /// pass `ifVersion: record.version` — a stale save gets a 409 instead of
    /// clobbering.
    // route: PATCH /storage/{collection}/{id}
    @discardableResult
    public func update(
        _ id: String,
        _ data: [String: JSONValue],
        ifVersion: Int? = nil,
        published: Bool? = nil
    ) async throws -> GemmeinRecord {
        var pairs: [(String, String)] = []
        if let ifVersion { pairs.append(("ifVersion", String(ifVersion))) }
        if let published { pairs.append(("published", published ? "true" : "false")) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try await request("/\(percentEncodeComponent(id))\(query)", method: "PATCH", body: try JSONCodec.encode(data))
        return GemmeinRecord(json: try requireObject(body, "a record"))
    }

    // route: DELETE /storage/{collection}/{id}
    public func delete(_ id: String) async throws {
        _ = try await request("/\(percentEncodeComponent(id))", method: "DELETE")
    }

    /// Upload a file and get back a REFERENCE — `file:<uuid>` — not a URL.
    ///
    /// Store the reference. It never expires, it is safe to log and export,
    /// and it grants nothing on its own. To show or download the file, call
    /// `files.link(ref)`; Gemmein re-checks who is asking every time, which is
    /// what makes revoking access actually take a download away.
    ///
    ///     let file = try await g.collection("films").upload(data, name: "poster.jpg", contentType: "image/jpeg")
    ///     try await g.collection("films").create(["title": "Ran", "poster": .string(file.ref)])
    ///
    /// Images (JPEG/PNG/WebP/GIF/HEIC) and documents (PDF/ZIP/EPUB), 25 MB per
    /// file. A document always downloads — link it with `intent: .download`.
    /// `for:` names ONE other person who may read this file (addressed and
    /// direct collections only). There is deliberately no `url` here: a URL
    /// that outlives a refund is the bug this replaced.
    // route: POST /storage/{collection}/upload
    // route: POST /storage/{collection}/upload/{fileId}/confirm
    public func upload(
        _ data: Data,
        name: String = "upload",
        contentType: String = "",
        for recipient: String? = nil
    ) async throws -> UploadedFile {
        // Step 1: the presign. The server refuses a presign that declares
        // nothing — it cannot accept an empty file.
        var presignFields: [String: Any] = ["name": name, "size": data.count, "contentType": contentType]
        if let recipient { presignFields["for"] = recipient }
        let presign = try requireObject(
            try await request("/upload", method: "POST", body: try JSONCodec.encode(presignFields)),
            "an upload"
        )
        guard let fileId = presign["fileId"]?.string,
              let uploadURLString = presign["uploadUrl"]?.string,
              let uploadURL = URL(string: uploadURLString) else {
            throw GemmeinError(status: 0, code: "invalid_response", message: "Gemmein answered an upload in a shape this SDK does not recognise")
        }

        // Step 2: straight to the object store, presigned POST. The `file`
        // part must be LAST — that is the store's own requirement.
        let boundary = "gemmein-\(UUID().uuidString)"
        var form = Data()
        func append(_ text: String) { form.append(Data(text.utf8)) }
        for (key, value) in presign["fields"]?.object ?? [:] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value.string ?? "")\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
        append("Content-Type: \(contentType.isEmpty ? "application/octet-stream" : contentType)\r\n\r\n")
        form.append(data)
        append("\r\n--\(boundary)--\r\n")

        var storeRequest = URLRequest(url: uploadURL)
        storeRequest.httpMethod = "POST"
        storeRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        storeRequest.httpBody = form
        let (_, storeResponse) = try await transported(config.apiURL) { try await config.session.data(for: storeRequest) }
        let storeStatus = (storeResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(storeStatus) else {
            throw GemmeinError(status: storeStatus, code: "upload_failed", message: "Upload failed: \(storeStatus)")
        }

        // Step 3: confirm. Only now does the reference exist.
        let confirmed = try requireObject(
            try await request("/upload/\(percentEncodeComponent(fileId))/confirm", method: "POST"),
            "an upload"
        )
        return UploadedFile(json: confirmed)
    }

    // ── internals ────────────────────────────────────────────────────────

    private func page(base: ListOptions, since: String?) async throws -> (records: [GemmeinRecord], deleted: [String], mark: String?) {
        var records: [GemmeinRecord] = []
        var deleted: [String] = []
        var cursor: String?
        var mark: String?
        repeat {
            var options = base
            options.cursor = cursor
            options.since = since
            let result = try await list(options)
            records.append(contentsOf: result.records)
            deleted.append(contentsOf: result.deleted)
            cursor = result.hasMore ? result.cursor : nil
            if since == nil {
                // Full sync: keep the FIRST page's watermark — anything
                // written while later pages stream must redeliver on the next
                // poll, not fall below an end-of-paging mark and vanish.
                mark = mark ?? result.watermark
            } else if !result.hasMore {
                mark = result.watermark
            }
        } while cursor != nil && !Task.isCancelled
        return (records, deleted, mark)
    }

    private func request(_ suffix: String, method: String = "GET", body: Data? = nil) async throws -> JSONValue? {
        var headers = ["content-type": "application/json"]
        // The intent rides every call so an undeclared collection reaches the
        // human WITH the AI's suggestion attached (local runtime only; the
        // cloud ignores it).
        if let intent { headers["x-collection-intent"] = String(intent.prefix(200)) }
        return try await runtimeRequest(
            config,
            "/storage/\(percentEncodeComponent(name))\(suffix)",
            method: method,
            body: body,
            extraHeaders: headers
        )
    }
}

/// The watcher's small shared state — one lock, no actor hop on the hot path.
final class WatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden = false
    private var wake = false
    private var watermark: String?

    var hiddenValue: Bool {
        get { lock.withLock { hidden } }
        set { lock.withLock { hidden = newValue } }
    }

    var watermarkValue: String? {
        get { lock.withLock { watermark } }
        set { lock.withLock { watermark = newValue } }
    }

    func requestWake() { lock.withLock { wake = true } }

    func takeWakeRequest() -> Bool {
        lock.withLock {
            let value = wake
            wake = false
            return value
        }
    }
}
