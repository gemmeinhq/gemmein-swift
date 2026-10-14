import Foundation

/// THE GATE — your compute, our answer. Ships here for parity with the other
/// SDKs, and for the Swift code that runs on a SERVER (Vapor, Hummingbird, a
/// command-line job).
///
/// **This belongs on a server, never in an app bundle.** A secret key in a
/// shipped app is a key in every customer's hands: anyone can extract it from
/// the binary and act as your backend. In an iOS or macOS app use `Gemmein`
/// with your PUBLIC key (`pk_…`) — the public key identifies the app, the
/// session authorises the person.
public final class GemmeinServer: @unchecked Sendable {
    private let apiURL: URL
    private let secretKey: String
    private let session: URLSession
    /// E2E #3 F20: present when the app named what it expects of the key.
    private let keyCheck: KeyCheck?

    /// `expects`: what this app needs the key to do, exactly. Before the
    /// first call the SDK asks `GET /manage/whoami` what the key may do;
    /// anything missing OR extra throws `key_scope_mismatch` (with `missing`
    /// and `extra`) and no call is made — the same check the JS SDK's
    /// `gemmeinServer(sk, { expects })` makes. Nil: nothing is checked.
    public init(secretKey: String, apiURL: URL = defaultAPIURL, session: URLSession = .shared, expects: KeyExpectations? = nil) throws {
        // Same signpost law as the client: a missing key (the env var didn't
        // load) must be a typed error, never a crash.
        if !secretKey.hasPrefix("sk_") {
            throw GemmeinError(
                status: 0,
                code: "invalid_secret_key",
                message: secretKey.hasPrefix("pk_")
                    ? "Public keys (pk_) must not be used with GemmeinServer — use the Gemmein client instead"
                    : "GemmeinServer needs a secret key (it starts with \"sk_\") — create one in the dashboard at https://app.gemmein.com and pass it from a server env var"
            )
        }
        // FULL BOUNDARY (23 Sep 2026) — the same refusal as the JS SDK's
        // `secret_key_in_client`. THE RULE: GemmeinServer runs only where no
        // customer holds the binary.
        //   · iOS, tvOS, watchOS, visionOS — always an app → refused.
        //   · macOS inside an app bundle — Bundle.main's path ends in `.app`,
        //     `.appex` (an extension) or `.xpc` (a service), or the executable
        //     sits anywhere inside a `.app` (a helper under Contents/MacOS,
        //     Contents/Library/LoginItems, …) → refused: a Mac app ships to
        //     the people who install it.
        //   · macOS or Linux as a plain executable — Vapor, Hummingbird, a
        //     command-line job, `swift run` on a dev machine → allowed.
        if GemmeinServer.runsInsideAnApp() {
            throw GemmeinError(
                status: 0,
                code: "secret_key_in_client",
                message: "A secret key (sk_) cannot run in a browser or a mobile app — anyone using the app could read it and act as your server. Keep it on your server (an API route, a server action, a worker) and call that from the app; for an admin screen, see \"Admin views\" in the Gemmein guide. Your Gemmein dashboard already shows every customer."
            )
        }
        self.apiURL = apiURL
        self.secretKey = secretKey
        self.session = session
        self.keyCheck = expects.map { KeyCheck(expects: $0, apiURL: apiURL, secretKey: secretKey, session: session) }
    }

    /// True when this process is an app its users install — every Apple
    /// platform but macOS, and a macOS `.app` bundle. `bundlePath` is the
    /// seam a test drives.
    static func runsInsideAnApp(
        bundlePath: String = Bundle.main.bundlePath,
        executablePath: String? = Bundle.main.executablePath
    ) -> Bool {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return true
        #else
        let bundle = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        for suffix in [".app", ".appex", ".xpc"] where bundle.hasSuffix(suffix) { return true }
        // A helper binary inside an app bundle (Contents/MacOS/Helper, a login
        // item, a bundled tool) has its own Bundle.main but still ships inside
        // the app.
        // (Contents/Developer — Xcode's own toolchain, e.g. xctest — is not an
        // app's payload.)
        if let exe = executablePath {
            for part in ["MacOS", "Library", "Helpers", "PlugIns", "XPCServices", "Frameworks", "Resources"]
            where exe.contains(".app/Contents/\(part)/") { return true }
        }
        return false
        #endif
    }

    // route: none
    public func collection(_ name: String) throws -> ServerCollectionClient {
        try assertCollectionName(name)
        return ServerCollectionClient(apiURL: apiURL, secretKey: secretKey, name: name, session: session, keyCheck: keyCheck)
    }

    /// Mint a member session for a test email WITHOUT an OTP round-trip — so a
    /// CI self-test can sign in as N test people and prove your app's
    /// isolation boundaries hold. DEV ENVIRONMENTS ONLY: refused on an
    /// `sk_live` key here and on the server. Never ship this in app code.
    // route: POST /server/test-session
    public func testSession(_ email: String) async throws -> AuthSession {
        if secretKey.hasPrefix("sk_live") {
            throw GemmeinError(
                status: 0,
                code: "test_session_forbidden_live",
                message: "test sessions are only available in a development environment — never with a live (sk_live) key"
            )
        }
        let body = try requireObject(
            try await gate("/server/test-session", method: "POST", body: try JSONCodec.encode(["email": email])),
            "a test session"
        )
        let user = body["user"]?.object ?? [:]
        return AuthSession(
            token: body["token"]?.string ?? "",
            expiresAt: body["expiresAt"]?.string ?? "",
            user: AuthUser(id: user["id"]?.string ?? "", email: user["email"]?.string ?? "", role: user["role"]?.string)
        )
    }

    /// Tell one of YOUR OWN people that something happened, by email. A person
    /// id, never an email address — the recipient must be a verified user of
    /// this app. This is for EVENTS, not campaigns: event-class sends are
    /// capped at about 5 per person per day (429 `notify_capped`, `resetAt`).
    /// `kind: .account` is for account activity — a new sign-in, an access
    /// change, a billing problem — and skips the per-person cap.
    // route: POST /server/notify
    @discardableResult
    public func notify(_ personId: String, subject: String, text: String, kind: NotifyKind? = nil, key: String? = nil) async throws -> NotifyResult {
        var payload: [String: Any] = ["personId": personId, "subject": subject, "text": text]
        if let kind { payload["kind"] = kind.rawValue }
        if let key { payload["key"] = key }
        return NotifyResult(json: try requireObject(
            try await gate("/server/notify", method: "POST", body: try JSONCodec.encode(payload)),
            "a notification"
        ))
    }

    /// ONE call per request answers identity AND holdings — don't call it
    /// twice, and don't cache the answer past the request.
    ///
    /// Refusals (`err.code`): `session_invalid` · `session_expired` ·
    /// `session_revoked` — all three send the person back to sign-in ·
    /// `person_suspended` · `invalid_body`.
    // route: POST /server/verify-session
    public func verifySession(_ token: String) async throws -> PersonHoldings {
        let body = try requireObject(
            try await gate("/server/verify-session", method: "POST", body: try JSONCodec.encode(["token": token])),
            "a session"
        )
        return PersonHoldings(
            person: GatePerson(json: body["person"]?.object ?? [:]),
            holdings: Holdings(json: body["holdings"]?.object ?? [:])
        )
    }

    /// THE INVITE DOOR: create a person by email BEFORE they sign in — the
    /// envelope, the invoice, the client portal. Create-or-fetch, idempotent,
    /// case-insensitive. Their first sign-in lands on this account: records
    /// and files you addressed to `person.id` are already theirs.
    ///
    /// Needs the key's "Create a person by email before they sign in" box
    /// ticked. Refusals: `capability_required` · `invalid_email` (400) ·
    /// `invite_capped` (429, `resetAt`).
    // route: POST /server/people
    public func invitePerson(_ email: String) async throws -> InviteResult {
        let body = try requireObject(
            try await gate("/server/people", method: "POST", body: try JSONCodec.encode(["email": email])),
            "a person"
        )
        return InviteResult(
            person: GatePerson(json: body["person"]?.object ?? [:]),
            created: body["created"]?.bool ?? false
        )
    }

    /// What one of YOUR people holds, by person id — for the paths where no
    /// token is in hand (a webhook of your own, a nightly job, an admin screen
    /// you built). A person id, NEVER an email address. A suspended person is
    /// RETURNED, with `suspended == true`; the gate itself refuses them.
    // route: GET /server/people/{personId}/holdings
    public func holdings(_ personId: String) async throws -> PersonHoldings {
        let body = try requireObject(
            try await gate("/server/people/\(percentEncodeComponent(personId))/holdings"),
            "holdings"
        )
        return PersonHoldings(
            person: GatePerson(json: body["person"]?.object ?? [:]),
            holdings: Holdings(json: body["holdings"]?.object ?? [:])
        )
    }

    /// Give a person access by hand — a trial, a promotion, an apology, a
    /// migration. MANUAL sources only: purchases and subscriptions come only
    /// from Stripe, so a key cannot mint paid access, by design. `reason` is up
    /// to 200 characters, is never edited afterwards, and is what the owner
    /// reads in their logs; write it for them. `sourceId` is minted per call,
    /// so two calls make TWO grants — call it once.
    // route: POST /server/people/{personId}/grants
    @discardableResult
    public func grantAccess(
        _ personId: String,
        entitlement: String,
        source: ManualGrantSource? = nil,
        expiresAt: String? = nil,
        reason: String? = nil
    ) async throws -> GrantResult {
        var payload: [String: Any] = ["entitlement": entitlement]
        if let source { payload["source"] = source.rawValue }
        if let expiresAt { payload["expiresAt"] = expiresAt }
        if let reason { payload["reason"] = reason }
        let body = try requireObject(
            try await gate("/server/people/\(percentEncodeComponent(personId))/grants", method: "POST", body: try JSONCodec.encode(payload)),
            "a grant"
        )
        return GrantResult(grant: Grant(json: body["grant"]?.object ?? [:]), holdings: Holdings(json: body["holdings"]?.object ?? [:]))
    }

    /// Spend a person's credits from YOUR server, with a reason. ONE
    /// conditional update, floored at 0: the spend succeeds whole or not at
    /// all, and `402 credits_exhausted` says how many they have. Pass `key`
    /// when the caller can retry — the same key answers the first spend again
    /// with `deduped == true`, `spent == 0` and the balance untouched. The key
    /// is scoped to the person: one order id reused for two people charges both.
    ///
    /// Needs the key's "Spend a person's credits" box ticked.
    // route: POST /server/people/{personId}/credits/spend
    @discardableResult
    public func spendCredits(_ personId: String, amount: Int? = nil, reason: String, key: String? = nil) async throws -> SpendCreditsResult {
        var payload: [String: Any] = ["reason": reason]
        if let amount { payload["amount"] = amount }
        if let key { payload["key"] = key }
        return SpendCreditsResult(json: try requireObject(
            try await gate("/server/people/\(percentEncodeComponent(personId))/credits/spend", method: "POST", body: try JSONCodec.encode(payload)),
            "a spend"
        ))
    }

    /// End one grant — the reversibility law in one call. A grant ends ONCE:
    /// `revokedAt` is set and never edited, so a second call is `409
    /// already_revoked`, not a silent no-op. A key MAY end a grant a payment
    /// created (the same as the owner's "end this access" button) — the
    /// payment itself is untouched, and the audit row says so.
    // route: POST /server/people/{personId}/grants/{grantId}/revoke
    @discardableResult
    public func revokeAccess(_ personId: String, grantId: String, reason: String? = nil) async throws -> GrantResult {
        var payload: [String: Any] = [:]
        if let reason { payload["reason"] = reason }
        let path = "/server/people/\(percentEncodeComponent(personId))/grants/\(percentEncodeComponent(grantId))/revoke"
        let body = try requireObject(
            try await gate(path, method: "POST", body: try JSONCodec.encode(payload)),
            "a grant"
        )
        return GrantResult(grant: Grant(json: body["grant"]?.object ?? [:]), holdings: Holdings(json: body["holdings"]?.object ?? [:]))
    }

    /// 0.23.0 THE INBOX ON YOUR SERVER — the app's support conversations,
    /// unanswered first (up to 50, default 20). A Live key sees Live's side
    /// of the Inbox; a Development key only Development's people. Needs the
    /// key's "Read your customers' support messages" box ticked.
    // route: GET /server/inbox/threads
    public func listInboxThreads(unanswered: Bool = false, limit: Int? = nil) async throws -> InboxThreadList {
        var query: [String] = []
        if unanswered { query.append("unanswered=true") }
        if let limit { query.append("limit=\(limit)") }
        let path = "/server/inbox/threads" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        return InboxThreadList(json: try requireObject(try await gate(path), "an inbox list"))
    }

    /// One conversation, oldest first, plain text — who wrote each message,
    /// which were automatic, and whether an AI reply would go now
    /// (`aiMayReply`). Reading never marks it read. Needs "Read your
    /// customers' support messages"; `thread_not_found` (404) otherwise.
    // route: GET /server/inbox/threads/{threadId}
    public func getInboxThread(_ threadId: String) async throws -> InboxThread {
        InboxThread(json: try requireObject(try await gate("/server/inbox/threads/\(percentEncodeComponent(threadId))"), "a conversation"))
    }

    /// Reply inside an EXISTING conversation — plain text, to its customer
    /// only, from the app's own support address, exactly as the dashboard's
    /// reply. Refused with nothing sent after an automatic message
    /// (`inbox_auto_reply`), after 3 AI replies in a row (`inbox_reply_cap`),
    /// while the last message can't be read (`inbox_unreadable`), past the
    /// caps (`inbox_reply_limited`, `development_capped`). Needs "Reply to
    /// your customers' support messages".
    // route: POST /server/inbox/threads/{threadId}/reply
    @discardableResult
    public func replyInboxThread(_ threadId: String, text: String) async throws -> InboxReplyResult {
        InboxReplyResult(json: try requireObject(
            try await gate("/server/inbox/threads/\(percentEncodeComponent(threadId))/reply", method: "POST", body: try JSONCodec.encode(["text": text])),
            "a reply"
        ))
    }

    /// One request path for every gate call, so every refusal reaches the
    /// caller through the SAME typed error the rest of the SDK throws.
    private func gate(_ pathAndQuery: String, method: String = "GET", body: Data? = nil) async throws -> JSONValue? {
        try await keyCheck?.ensure()
        var headers = ["x-app-key": secretKey, "x-client-info": GemmeinSwift.clientInfo]
        if body != nil { headers["content-type"] = "application/json" }
        let request = makeRequest(makeURL(apiURL, pathAndQuery), method: method, headers: headers, body: body)
        // W10 review row 14a: through the SAME seam every other call uses. A
        // refused connection here was a raw URLError — the one place in the
        // package where `error as? GemmeinError` came back nil.
        let (data, response) = try await transported(apiURL) { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return nil }
        guard (200...299).contains(status) else { throw readErrorBody(data, status: status) }
        return JSONCodec.decode(data)
    }
}

/// Records read and written with a SECRET key — a server's own view of a
/// collection, past the person's safety rule. Reached as
/// `try gemmeinServer.collection("orders")`. Server-side only.
public final class ServerCollectionClient: @unchecked Sendable {
    private let apiURL: URL
    private let secretKey: String
    private let name: String
    private let session: URLSession
    private let keyCheck: KeyCheck?

    init(apiURL: URL, secretKey: String, name: String, session: URLSession, keyCheck: KeyCheck? = nil) {
        self.apiURL = apiURL
        self.secretKey = secretKey
        self.name = name
        self.session = session
        self.keyCheck = keyCheck
    }

    // route: GET /storage/{collection}/{id}
    public func get(_ id: String) async throws -> GemmeinRecord {
        GemmeinRecord(json: try requireObject(try await request("/\(percentEncodeComponent(id))"), "a record"))
    }

    // route: GET /storage/{collection}
    public func list(_ options: ListOptions = ListOptions()) async throws -> ListResult {
        let pairs = options.queryPairs
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        return ListResult(json: try requireObject(try await request(query), "a list"))
    }

    // route: PATCH /storage/{collection}/{id}
    @discardableResult
    public func update(_ id: String, _ data: [String: JSONValue], published: Bool? = nil, ifVersion: Int? = nil) async throws -> GemmeinRecord {
        var pairs: [(String, String)] = []
        if let ifVersion { pairs.append(("ifVersion", String(ifVersion))) }
        if let published { pairs.append(("published", published ? "true" : "false")) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try await request("/\(percentEncodeComponent(id))\(query)", method: "PATCH", body: try JSONCodec.encode(data))
        return GemmeinRecord(json: try requireObject(body, "a record"))
    }

    /// Create a record from your server, under ANY rule, when the key may
    /// write this collection. Whose record it is, per rule: private · shared ·
    /// community → `for:` its owner; admin_write · public_read → no person;
    /// addressed → `for:` the recipient; direct → `from:` the author and
    /// `for:` the recipient. A missing or extra person is `person_required` /
    /// `invalid_person`; a read-only key is `scope_denied`.
    // route: POST /storage/{collection}
    @discardableResult
    public func create(
        _ data: [String: JSONValue],
        for person: String? = nil,
        from author: String? = nil,
        key: String? = nil,
        published: Bool? = nil
    ) async throws -> GemmeinRecord {
        var pairs: [(String, String)] = []
        if let person { pairs.append(("for", person)) }
        if let author { pairs.append(("from", author)) }
        if let key { pairs.append(("key", key)) }
        if let published { pairs.append(("published", published ? "true" : "false")) }
        let query = pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
        let body = try await request(query, method: "POST", body: try JSONCodec.encode(data))
        return GemmeinRecord(json: try requireObject(body, "a record"))
    }

    /// MANY RECIPIENTS: a direct record `from:` its author to up to 20 people
    /// at once — one record every named person reads.
    // route: POST /storage/{collection}
    @discardableResult
    public func create(
        _ data: [String: JSONValue],
        for recipients: [String],
        from author: String? = nil,
        key: String? = nil
    ) async throws -> GemmeinRecord {
        var pairs: [(String, String)] = [("for", recipients.joined(separator: ","))]
        if let author { pairs.append(("from", author)) }
        if let key { pairs.append(("key", key)) }
        let body = try await request("?\(formURLEncode(pairs))", method: "POST", body: try JSONCodec.encode(data))
        return GemmeinRecord(json: try requireObject(body, "a record"))
    }

    /// Delete any record in a collection this key may DELETE — its own tick at
    /// mint (or a full key); a key without it is `scope_denied`.
    // route: DELETE /storage/{collection}/{id}
    public func delete(_ id: String) async throws {
        _ = try await request("/\(percentEncodeComponent(id))", method: "DELETE")
    }

    private func request(_ suffix: String, method: String = "GET", body: Data? = nil) async throws -> JSONValue? {
        try await keyCheck?.ensure()
        var headers = ["x-app-key": secretKey, "x-client-info": GemmeinSwift.clientInfo]
        if body != nil { headers["content-type"] = "application/json" }
        let url = makeURL(apiURL, "/storage/\(percentEncodeComponent(name))\(suffix)")
        // Same seam, same reason (W10 review row 14a).
        let (data, response) = try await transported(apiURL) { try await session.data(for: makeRequest(url, method: method, headers: headers, body: body)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return nil }
        // One parser for every refusal body, so a 403 entitlement_required on
        // a collection surfaces `requires` exactly as it does on the runtime
        // clients.
        guard (200...299).contains(status) else { throw readErrorBody(data, status: status) }
        return JSONCodec.decode(data)
    }
}

// ── E2E #3 F20: A KEY CAN BE CHECKED ─────────────────────────────────────
// The JS SDK's `expects` (packages/sdk/src/index.ts compareKeyAccess), the
// same words in the same order — the parity law.

/// The level a key holds on one collection, as `/manage/whoami` answers it.
public enum KeyAccessLevel: String, Sendable {
    case read = "read"
    case readWrite = "read-write"
    case readWriteDelete = "read-write-delete"
}

/// The people powers a server key can hold (ticked per key at mint).
public enum KeyCapability: String, Sendable, CaseIterable {
    case readPeople, grantAccess, invitePeople, spendCredits, inboxRead, inboxReply

    var words: String {
        switch self {
        case .readPeople: return "look up a person's access by id"
        case .grantAccess: return "grant and revoke access"
        case .invitePeople: return "create a person by email"
        case .spendCredits: return "spend a person's credits"
        case .inboxRead: return "read your customers' support messages"
        case .inboxReply: return "reply to your customers' support messages"
        }
    }
}

/// What an app expects of its server key — see `GemmeinServer(…, expects:)`.
public struct KeyExpectations: Sendable {
    public var collections: [String: KeyAccessLevel]
    public var capabilities: [KeyCapability]

    public init(collections: [String: KeyAccessLevel] = [:], capabilities: [KeyCapability] = []) {
        self.collections = collections
        self.capabilities = capabilities
    }
}

private let keyVerbOrder = ["read", "write", "delete"]

private func keyVerbs(_ level: String?) -> Set<String> {
    guard let level else { return [] }
    return Set(level.split(separator: "-").map(String.init).filter { keyVerbOrder.contains($0) })
}

private func keyVerbWords(_ verbs: [String]) -> String {
    let words = verbs.map { $0 == "delete" ? "delete from" : $0 }
    if words.count <= 1 { return words.first ?? "" }
    return "\(words.dropLast().joined(separator: ", ")) and \(words.last!)"
}

/// What `expects` wants that the key lacks, and what the key holds beyond it.
func compareKeyAccess(_ expects: KeyExpectations, allCollections: Bool, collections: [String: String], capabilities: [String]) -> (missing: [String], extra: [String]) {
    var missing: [String] = []
    var extra: [String] = []
    let held = allCollections ? [:] : collections
    for name in Set(expects.collections.keys).union(held.keys).sorted() {
        let want = keyVerbs(expects.collections[name]?.rawValue)
        let have = allCollections ? Set(keyVerbOrder) : keyVerbs(collections[name])
        let short = keyVerbOrder.filter { want.contains($0) && !have.contains($0) }
        let over = keyVerbOrder.filter { have.contains($0) && !want.contains($0) }
        if !short.isEmpty { missing.append("this key cannot \(keyVerbWords(short)) \(name), which the app needs") }
        if !over.isEmpty && !allCollections { extra.append("this key can also \(keyVerbWords(over)) \(name), which the app doesn't need") }
    }
    if allCollections { extra.append("this key reaches every collection, present and future (a full key) — the app names the collections it needs") }
    let wantCaps = Set(expects.capabilities.map(\.rawValue))
    let haveCaps = Set(capabilities)
    for cap in KeyCapability.allCases {
        if wantCaps.contains(cap.rawValue) && !haveCaps.contains(cap.rawValue) { missing.append("this key cannot \(cap.words), which the app needs") }
        if haveCaps.contains(cap.rawValue) && !wantCaps.contains(cap.rawValue) { extra.append("this key can also \(cap.words), which the app doesn't need") }
    }
    return (missing, extra)
}

/// A key's access, read ONCE per process per (apiURL, key) — its scopes are
/// fixed at mint, so a server building a client per request still asks
/// whoami once. A failed read is dropped so the next call asks again.
actor KeyAccessCache {
    static let shared = KeyAccessCache()
    private var reads: [String: Task<[String: JSONValue]?, Error>] = [:]

    func access(apiURL: URL, secretKey: String, session: URLSession) async throws -> [String: JSONValue]? {
        let key = "\(apiURL.absoluteString)\u{0}\(secretKey)"
        if let existing = reads[key] { return try await existing.value }
        let task = Task<[String: JSONValue]?, Error> {
            let request = makeRequest(makeURL(apiURL, "/manage/whoami"), method: "GET", headers: ["x-app-key": secretKey, "x-client-info": GemmeinSwift.clientInfo], body: nil)
            let (data, response) = try await transported(apiURL) { try await session.data(for: request) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw readErrorBody(data, status: status) }
            return JSONCodec.decode(data)?.object?["access"]?.object
        }
        reads[key] = task
        do { return try await task.value } catch { reads[key] = nil; throw error }
    }
}

/// Asks once; a mismatch is remembered, a failed check is not.
actor KeyCheck {
    private let expects: KeyExpectations
    private let apiURL: URL
    private let secretKey: String
    private let session: URLSession
    private var passed = false
    private var refused: GemmeinError?

    init(expects: KeyExpectations, apiURL: URL, secretKey: String, session: URLSession) {
        self.expects = expects
        self.apiURL = apiURL
        self.secretKey = secretKey
        self.session = session
    }

    func ensure() async throws {
        if passed { return }
        if let refused { throw refused }
        guard let access = try await KeyAccessCache.shared.access(apiURL: apiURL, secretKey: secretKey, session: session) else {
            let error = GemmeinError(status: 0, code: "key_scope_mismatch", message: "this is not a server key — `expects` checks a server key (Secret keys in the dashboard); a key the CLI holds after `npx gemmein login` acts as you and is never an app's key", missing: [], extra: [])
            refused = error
            throw error
        }
        var held: [String: String] = [:]
        for (name, level) in access["collections"]?.object ?? [:] { if let l = level.string { held[name] = l } }
        let caps = (access["capabilities"]?.array ?? []).compactMap(\.string)
        let (missing, extra) = compareKeyAccess(expects, allCollections: access["allCollections"]?.bool == true, collections: held, capabilities: caps)
        if missing.isEmpty && extra.isEmpty { passed = true; return }
        let levelWords: [KeyAccessLevel: String] = [.read: "reads only", .readWrite: "reads and writes", .readWriteDelete: "reads, writes and deletes"]
        var wanted = expects.collections.keys.sorted().map { "\($0) \(levelWords[expects.collections[$0]!]!)" }
        wanted += expects.capabilities.map(\.words)
        let error = GemmeinError(
            status: 0,
            code: "key_scope_mismatch",
            message: "the server key doesn't match what the app expects: \((missing + extra).joined(separator: "; ")). Make a key with exactly \(wanted.isEmpty ? "nothing" : wanted.joined(separator: "; ")) (dashboard → Secret keys → Create a secret key), put it where this one is, and revoke this one",
            missing: missing,
            extra: extra
        )
        refused = error
        throw error
    }
}
