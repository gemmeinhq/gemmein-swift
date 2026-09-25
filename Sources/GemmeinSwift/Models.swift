import Foundation

// Everything here is read off the engine's own answer. Missing optional
// fields are absent, never invented — an engine that does not carry a field
// leaves it nil, and that reads as "not carried", never as a value.

/// A stored record. Your app's fields ALWAYS live under `data`
/// (`record.data["title"]`, never `record["title"]`). Everything else is
/// server-derived and read-only — never store your own userId/role/owner
/// fields inside `data`; the server already knows who owns what.
public struct GemmeinRecord: Sendable, Equatable {
    public let id: String
    /// Your fields, exactly as you created them.
    public let data: [String: JSONValue]
    public let createdAt: String
    public let updatedAt: String
    /// Who owns this record — set by the server from the signed-in session.
    /// `nil` for app-owned records no user session created (purchase receipts
    /// written by the payment webhook, records the owner adds from the
    /// dashboard). Guard before using it.
    public let ownerUserId: String?
    public let collectionId: String
    public let appId: String
    public let environmentId: String
    /// Monotonic edit counter (+1 per update). Pass the version you read back
    /// as `update(id, data, ifVersion: record.version)` and a stale save gets
    /// a 409 `conflict` instead of silently clobbering someone else's edit.
    public let version: Int
    /// The create-if-absent key this record was created with, when one was used.
    public let key: String?
    /// The recipient (addressed/direct collections) — set by the server from
    /// the create's `for:`, never from data.
    public let audienceUserId: String?
    /// Draft state on the public rules — a server column, never a data field.
    public let published: Bool
    /// "server" when your server's secret key created this record (e.g. a
    /// direct message imported from a person) — show it as sent by the
    /// server. nil when a person (or the dashboard) wrote it.
    public let writtenBy: String?
    /// Linked records you asked to expand, per field — only what you could
    /// read directly; unreadable or deleted targets are nil.
    public let expand: [String: GemmeinRecord?]
    /// Present (true) only when a keyed create was YOUR OWN retry — you got
    /// the record you already made.
    public let existing: Bool?

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        data = json["data"]?.object ?? [:]
        createdAt = json["createdAt"]?.string ?? ""
        updatedAt = json["updatedAt"]?.string ?? ""
        ownerUserId = json["ownerUserId"]?.string
        collectionId = json["collectionId"]?.string ?? ""
        appId = json["appId"]?.string ?? ""
        environmentId = json["environmentId"]?.string ?? ""
        version = json["version"]?.int ?? 0
        key = json["key"]?.string
        audienceUserId = json["audienceUserId"]?.string
        published = json["published"]?.bool ?? true
        writtenBy = json["writtenBy"]?.string
        var expanded: [String: GemmeinRecord?] = [:]
        for (field, value) in json["expand"]?.object ?? [:] {
            // updateValue, not subscript assignment: an unreadable or deleted
            // target is null, and a null must stay a PRESENT nil — dropping
            // the key would read as "you never asked to expand this field".
            expanded.updateValue(value.object.map { GemmeinRecord(json: $0) }, forKey: field)
        }
        expand = expanded
        existing = json["existing"]?.bool
    }
}

/// One page of records. When `hasMore` is true, pass `cursor` to `list()` for
/// the next page.
public struct ListResult: Sendable, Equatable {
    public let records: [GemmeinRecord]
    public let cursor: String?
    public let hasMore: Bool
    /// On a delta read (`since`), ids of records deleted after that instant —
    /// ids only, and only ones your rule scope admitted.
    public let deleted: [String]
    /// The instant to pass as the next `since`. Deliberately lags the server
    /// clock, so a change can be delivered twice but never silently missed —
    /// apply records by id.
    public let watermark: String?

    init(json: [String: JSONValue]) {
        records = (json["records"]?.array ?? []).compactMap { $0.object.map { GemmeinRecord(json: $0) } }
        cursor = json["cursor"]?.string
        hasMore = json["hasMore"]?.bool ?? false
        deleted = (json["deleted"]?.array ?? []).compactMap { $0.string }
        watermark = json["watermark"]?.string
    }
}

public enum ListSort: String, Sendable {
    case newest, oldest, updated
}

/// The options `list()` and `watch()` share with the JS SDK, field for field.
public struct ListOptions: Sendable {
    public var limit: Int?
    public var sort: ListSort?
    /// Filter on your `data` fields: a literal is an exact match
    /// (`["done": false]`); an object of operators narrows it —
    /// `eq` `ne` `gt` `gte` `lt` `lte` `in` `nin` `contains` `startsWith`
    /// `exists` (`["amount": ["gte": 10], "status": ["in": ["paid", "sent"]]]`).
    /// Up to 5 fields, 1 to 3 operators each, all AND.
    public var `where`: [String: JSONValue]?
    /// Opaque page cursor from a previous `ListResult`.
    public var cursor: String?
    /// Free-text search across your `data` fields.
    public var search: String?
    /// Link fields to embed (up to 3) — each expanded record is only what YOU
    /// could have read directly.
    public var expand: [String]?
    /// Everything changed OR deleted after this instant, oldest change first.
    /// Pass the `watermark` from the previous answer. Incompatible with `sort`.
    public var since: String?

    public init(
        limit: Int? = nil,
        sort: ListSort? = nil,
        where filter: [String: JSONValue]? = nil,
        cursor: String? = nil,
        search: String? = nil,
        expand: [String]? = nil,
        since: String? = nil
    ) {
        self.limit = limit
        self.sort = sort
        self.where = filter
        self.cursor = cursor
        self.search = search
        self.expand = expand
        self.since = since
    }

    /// The query string, exactly as the JS SDK writes it.
    var queryPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let limit { pairs.append(("limit", String(limit))) }
        if let sort { pairs.append(("sort", sort.rawValue)) }
        if let filter = self.where { pairs.append(("where", JSONCodec.string(filter))) }
        if let cursor { pairs.append(("cursor", cursor)) }
        if let search { pairs.append(("search", search)) }
        if let expand, !expand.isEmpty { pairs.append(("expand", expand.joined(separator: ","))) }
        if let since { pairs.append(("since", since)) }
        return pairs
    }
}

/// The answer to `stats(_:where:search:)`: `count` is how many records held
/// a number in the field; the four are nil when none did. A sum past 2^53
/// arrives as its decimal text in `sumText`.
public struct RecordStats: Sendable, Equatable {
    public let count: Int
    public let sum: Double?
    public let avg: Double?
    public let min: Double?
    public let max: Double?
    public let sumText: String?

    init(json: [String: JSONValue]) {
        count = json["count"]?.int ?? 0
        sum = json["sum"]?.double
        avg = json["avg"]?.double
        min = json["min"]?.double
        max = json["max"]?.double
        sumText = json["sum"]?.string
    }
}

/// Answer to "who is signed in right now?". `authenticated == false` simply
/// means "no one" — this call never throws for session state, so it is safe
/// unguarded at launch. It is deliberately silent about the why: signed out,
/// suspended and erased all read the same. Build the signed-out screen for
/// all three.
public struct CurrentUser: Sendable, Equatable {
    public let authenticated: Bool
    public let userId: String?
    public let email: String?
    /// The store account token, when the engine carries one. Hand it to
    /// RevenueCat as the app user id. An engine that does not send it leaves
    /// this nil — read that as "not carried", never as "no account".
    public let storeAccountToken: String?

    init(json: [String: JSONValue]) {
        authenticated = json["authenticated"]?.bool ?? false
        userId = json["userId"]?.string
        email = json["email"]?.string
        storeAccountToken = json["storeAccountToken"]?.string
    }
}

public struct AuthUser: Sendable, Equatable {
    public let id: String
    public let email: String
    /// Present on a test session; absent on the ordinary email-code sign-in.
    public let role: String?
}

public struct AuthSession: Sendable, Equatable {
    public let token: String
    public let expiresAt: String
    public let user: AuthUser
}

public struct Purchase: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        /// Resolve the ref with `files.link(ref, intent: .download)` — the
        /// purchase itself is the authorization, re-checked on every mint.
        case gemmeinFile(String)
        case externalURL(String)
    }

    public let item: String
    /// "purchase" or "subscription", as the engine reported it.
    public let kind: String
    /// MINOR UNITS (pence, cents) with the currency alongside, exactly as the
    /// payment provider reported them. Formatting is yours; rounding here
    /// would quietly lose money.
    public let amountMinor: Int?
    public let currency: String?
    public let refundedMinor: Int
    /// "paid", "part_refunded" or "refunded".
    public let status: String
    public let grants: [String]
    public let paidAt: String
    public let delivery: Delivery?

    init(json: [String: JSONValue]) {
        item = json["item"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        amountMinor = json["amountMinor"]?.int
        currency = json["currency"]?.string
        refundedMinor = json["refundedMinor"]?.int ?? 0
        status = json["status"]?.string ?? ""
        grants = (json["grants"]?.array ?? []).compactMap { $0.string }
        paidAt = json["paidAt"]?.string ?? ""
        if let d = json["delivery"]?.object {
            switch d["type"]?.string {
            case "gemmein_file": delivery = d["file"]?.string.map { .gemmeinFile($0) }
            case "external_url": delivery = d["url"]?.string.map { .externalURL($0) }
            default: delivery = nil
            }
        } else {
            delivery = nil
        }
    }
}

public struct FileLink: Sendable, Equatable {
    public let ref: String
    public let url: String
    /// Absent when the collection is public — those links don't expire.
    public let expiresAt: String?
    public let contentType: String
    public let sizeBytes: Int?
    public let name: String?

    init(json: [String: JSONValue]) {
        ref = json["ref"]?.string ?? ""
        url = json["url"]?.string ?? ""
        expiresAt = json["expiresAt"]?.string
        contentType = json["contentType"]?.string ?? ""
        sizeBytes = json["sizeBytes"]?.int
        name = json["name"]?.string
    }
}

/// What `files.link` is for: `.inline` shows the file, `.download` sends it as
/// an attachment under its own name (always use this for documents).
public enum LinkIntent: String, Sendable {
    case inline, download
}

public struct Subscription: Sendable, Equatable {
    public let plan: String
    /// "active" or "cancelled".
    public let status: String
}

public struct CheckoutSession: Sendable, Equatable {
    public let url: String
    public let plan: String
}

public struct PaymentSession: Sendable, Equatable {
    public let url: String
    public let product: String
    public let item: String?
}

public struct UploadedFile: Sendable, Equatable {
    public let id: String
    /// `file:<uuid>` — a reference, not a URL. Store THIS. To show or download
    /// the file, call `files.link(ref)`.
    public let ref: String
    public let contentType: String
    public let sizeBytes: Int

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        ref = json["ref"]?.string ?? ""
        contentType = json["contentType"]?.string ?? ""
        sizeBytes = json["sizeBytes"]?.int ?? 0
    }
}

/// One of the person's own AI calls, as `ai.calls()` lists them.
public struct AiCallRecord: Sendable, Equatable {
    public let id: String
    public let tool: String
    public let kind: String
    public let provider: String
    public let model: String?
    public let tokensIn: Int?
    public let tokensOut: Int?
    public let credits: Int
    /// "ok", "refused", "provider_error", "unreachable", "client_closed" or
    /// "stream_ended".
    public let outcome: String
    public let refusalCode: String?
    public let latencyMs: Int?
    public let prompt: String?
    public let answer: String?
    public let createdAt: String

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        tool = json["tool"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        provider = json["provider"]?.string ?? ""
        model = json["model"]?.string
        tokensIn = json["tokensIn"]?.int
        tokensOut = json["tokensOut"]?.int
        credits = json["credits"]?.int ?? 0
        outcome = json["outcome"]?.string ?? ""
        refusalCode = json["refusalCode"]?.string
        latencyMs = json["latencyMs"]?.int
        prompt = json["prompt"]?.string
        answer = json["answer"]?.string
        createdAt = json["createdAt"]?.string ?? ""
    }
}

public struct AiCallPage: Sendable, Equatable {
    public let calls: [AiCallRecord]
    public let nextCursor: String?
}

public enum AiProvider: String, Sendable {
    case openai, anthropic, google
}

// ── the gate's shapes (secret key) ───────────────────────────────────────

public struct GatePerson: Sendable, Equatable {
    public let id: String
    public let email: String
    public let role: String
    /// Carried by `holdings()` and `invitePerson()`; nil where the answer does
    /// not name it.
    public let suspended: Bool?
    /// `invitePerson()` only: true until they sign in for the first time.
    public let invited: Bool?

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        email = json["email"]?.string ?? ""
        role = json["role"]?.string ?? ""
        suspended = json["suspended"]?.bool
        invited = json["invited"]?.bool
    }
}

public struct Grant: Sendable, Equatable {
    public let id: String
    /// `access:<slug>` — the plan's or product's own key.
    public let entitlement: String
    /// "subscription", "purchase", "manual", "trial", "promotion",
    /// "migration" or "relay".
    public let source: String
    public let startsAt: String
    public let expiresAt: String?
    /// Present on the grant returned by `revokeAccess` — set once, never edited.
    public let revokedAt: String?

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        entitlement = json["entitlement"]?.string ?? ""
        source = json["source"]?.string ?? ""
        startsAt = json["startsAt"]?.string ?? ""
        expiresAt = json["expiresAt"]?.string
        revokedAt = json["revokedAt"]?.string
    }
}

/// What a person holds RIGHT NOW — never what they pay. `credits` is nil on an
/// engine that does not carry it; read that as "not carried", never as zero.
public struct Holdings: Sendable, Equatable {
    public let access: [String]
    public let grants: [Grant]
    public let credits: Int?

    init(json: [String: JSONValue]) {
        access = (json["access"]?.array ?? []).compactMap { $0.string }
        grants = (json["grants"]?.array ?? []).compactMap { $0.object.map { Grant(json: $0) } }
        credits = json["credits"]?.object?["balance"]?.int
    }
}

/// The sources a secret key may create by hand. `purchase` and `subscription`
/// are deliberately absent: money-made access comes only from Stripe.
public enum ManualGrantSource: String, Sendable {
    case manual, trial, promotion, migration
}

public struct PersonHoldings: Sendable, Equatable {
    public let person: GatePerson
    public let holdings: Holdings
}

public struct GrantResult: Sendable, Equatable {
    public let grant: Grant
    public let holdings: Holdings
}

public struct InviteResult: Sendable, Equatable {
    public let person: GatePerson
    /// True on the call that made them (HTTP 201); false on every later fetch.
    public let created: Bool
}

/// `spendCredits`'s answer: `spent` is the amount taken (0 on a deduped
/// repeat); `event` is the ledger line — the same one on a repeat.
public struct SpendCreditsResult: Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public let id: String
        public let reason: String?
        public let actor: String
    }

    public let spent: Int
    public let deduped: Bool
    public let balanceBefore: Int
    public let balanceAfter: Int
    public let event: Event

    init(json: [String: JSONValue]) {
        spent = json["spent"]?.int ?? 0
        deduped = json["deduped"]?.bool ?? false
        balanceBefore = json["balance"]?.object?["before"]?.int ?? 0
        balanceAfter = json["balance"]?.object?["after"]?.int ?? 0
        let e = json["event"]?.object ?? [:]
        event = Event(id: e["id"]?.string ?? "", reason: e["reason"]?.string, actor: e["actor"]?.string ?? "")
    }
}

public struct NotifyResult: Sendable, Equatable {
    public let sent: Bool
    public let deduped: Bool?
    public let id: String?
    public let threadId: String?
    /// Whether a customer's reply will land in your Inbox.
    public let replyRail: Bool?
    public let recorded: Bool?

    init(json: [String: JSONValue]) {
        sent = json["sent"]?.bool ?? false
        deduped = json["deduped"]?.bool
        id = json["id"]?.string
        threadId = json["threadId"]?.string
        replyRail = json["replyRail"]?.bool
        recorded = json["recorded"]?.bool
    }
}

/// What `notify` is for. `account` (a new sign-in, an access change, a billing
/// problem) skips the per-person cap — a security notice must never lose to
/// five order emails.
public enum NotifyKind: String, Sendable {
    case event, account
}
