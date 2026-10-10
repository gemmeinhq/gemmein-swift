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
    /// OPEN FIELDS: YOUR own marks — for each "count once per person" field,
    /// whether you counted it; for each "per person flag", your yes/no.
    public let mine: [String: Bool]
    /// OPEN FIELDS: on a secret-key read of one record, who set each
    /// "per person flag" (first 100).
    public let flaggedBy: [String: [String]]
    /// MANY RECIPIENTS: everyone a direct record was sent to, in order, when
    /// it named more than one.
    public let recipients: [String]?

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
        mine = (json["mine"]?.object ?? [:]).compactMapValues { $0.bool }
        flaggedBy = (json["flaggedBy"]?.object ?? [:]).mapValues { ($0.array ?? []).compactMap { $0.string } }
        recipients = json["recipients"]?.array?.compactMap { $0.string }
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
    /// With `ListOptions(count: true)`: how many records the filters admit,
    /// exact up to 10,000. nil when not asked, or when `totalAtLeast` is set.
    public let total: Int?
    /// With `ListOptions(count: true)`, past 10,000: show "10,000+".
    public let totalAtLeast: Int?

    init(json: [String: JSONValue]) {
        records = (json["records"]?.array ?? []).compactMap { $0.object.map { GemmeinRecord(json: $0) } }
        cursor = json["cursor"]?.string
        hasMore = json["hasMore"]?.bool ?? false
        deleted = (json["deleted"]?.array ?? []).compactMap { $0.string }
        watermark = json["watermark"]?.string
        total = json["total"]?.int
        totalAtLeast = json["totalAtLeast"]?.int
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
    /// Add the total to the answer (`total`, or `totalAtLeast` past 10,000) —
    /// same rule, filters and search as the page. Not with `since`.
    public var count: Bool
    /// Only records written by this person: "me" or a user id. Shared,
    /// community, public_read, direct only (403 author_not_visible elsewhere).
    public var author: String?

    public init(
        limit: Int? = nil,
        sort: ListSort? = nil,
        where filter: [String: JSONValue]? = nil,
        cursor: String? = nil,
        search: String? = nil,
        expand: [String]? = nil,
        since: String? = nil,
        count: Bool = false,
        author: String? = nil
    ) {
        self.limit = limit
        self.sort = sort
        self.where = filter
        self.cursor = cursor
        self.search = search
        self.expand = expand
        self.since = since
        self.count = count
        self.author = author
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
        if count { pairs.append(("count", "true")) }
        if let author { pairs.append(("author", author)) }
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
    /// "trialing", "active" or "cancelled".
    public let status: String
    /// ISO time the free trial ends, while trialing.
    public var trialEndsAt: String? = nil
    /// ISO time the subscription ends, when it is set to cancel.
    public var endsAt: String? = nil
}

/// The app owner's Stripe customer portal for the signed-in subscriber.
public struct ManageLink: Sendable, Equatable {
    public let url: String
}

public struct CheckoutSession: Sendable, Equatable {
    public let url: String
    public let plan: String
}

/// ONE CATALOG: a product the app sells, as `payments.products()` answers
/// it. Payments → Products in the dashboard IS the catalog; your own words
/// and pictures for each item live in your code, keyed by `name`.
public struct CatalogProduct: Sendable, Equatable {
    /// The name `payments.buy(_:)` takes.
    public let name: String
    /// Minor units (1500 = 15.00) and a lower-case ISO currency.
    public let price: CatalogPrice
    /// What the buyer receives: "file", "link" or "none".
    public let delivers: String
    /// Credits one purchase adds to the buyer's balance.
    public let credits: Int?
    /// The access the purchase unlocks (`access:<slug>`).
    public let unlocks: [String]
}

/// ONE CATALOG: a plan, as `subscriptions.plans()` answers it.
public struct CatalogPlan: Sendable, Equatable {
    /// The name `subscriptions.checkout(plan:)` takes.
    public let name: String
    /// The plan everyone starts on — never bought; its price is 0.
    public let free: Bool
    /// Minor units; the free plan's currency is the first paid plan's (nil
    /// when none is sold) and its period is nil.
    public let price: CatalogPrice
    /// Credits granted each period (the free plan: each calendar month).
    public let creditsPerPeriod: Int?
    /// The free plan's welcome credits, granted once.
    public let creditsOnce: Int?
    /// The access the plan unlocks while active (`access:<slug>`).
    public let unlocks: [String]
}

public struct CatalogPrice: Sendable, Equatable {
    public let amountMinor: Int
    public let currency: String?
    /// "day", "week", "month" or "year" on a paid plan; nil on a product and the free plan.
    public let period: String?
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

/// What `account.export()` returns: the whole export document, typed field
/// for field as the JS `AccountExport`, plus `document`, the JSON exactly as
/// Gemmein sent it (`jsonData()` is the file a person saves). It opens with
/// `about`, the cover: what it is, the app, when, which door, the sections,
/// what is left out and why, and the person's rights. The sections
/// are `records`, `marks`, `files`, `purchases`, `subscription`, `credits`,
/// `access`, `aiCalls`, `runs`, `emails`, `support`, `sessions`, `signIns`
/// and `limits`. `limits.truncated` names every section something was left
/// out of (past its cap, or the shared byte budget) — empty when whole.
public struct AccountExport: Sendable, Equatable {
    /// The document's top-level keys, in the order the JS type declares them.
    public static let keys = ["exportVersion", "about", "exportedAt", "app", "person", "records", "recordCount", "marks", "files", "purchases", "subscription", "credits", "access", "aiCalls", "runs", "emails", "support", "sessions", "signIns", "limits"]

    /// The cover (GDPR Art. 15(1) supplementary information).
    public struct About: Sendable, Equatable {
        /// A category the export leaves out, and why.
        public struct Omission: Sendable, Equatable {
            public let what: String
            public let why: String
        }
        public let what: String
        /// The app's name.
        public let app: String?
        public let generatedAt: String
        /// "self" (the person's own `account.export()`) or "owner" (the dashboard).
        public let door: String
        public let producedBy: String
        public let sections: [String]
        /// Where the caps are (`limits`).
        public let limits: String
        public let notIncluded: [Omission]
        /// The app's Terms of Service link, when it gave one.
        public let termsUrl: String?
        /// The address the app's owner is reached at, when it has one.
        public let ownerContact: String?
        /// The person's rights, in one line.
        public let rights: String
    }
    public struct App: Sendable, Equatable {
        public let appId: String
        public let environmentId: String
    }
    public struct Person: Sendable, Equatable {
        public let id: String
        public let email: String
        public let createdAt: String
        public let lastSignInAt: String?
        public let suspendedAt: String?
        public let invitedAt: String?
    }
    /// A record they wrote (`relation` "author") or that names them ("recipient").
    public struct Record: Sendable, Equatable {
        public let id: String
        public let relation: String
        public let data: [String: JSONValue]
        public let to: String?
        public let recipients: [String]?
        public let from: String?
        public let createdAt: String
        public let updatedAt: String
    }
    /// Their own like or flag (an open field).
    public struct Mark: Sendable, Equatable {
        public let recordId: String
        public let field: String
        public let createdAt: String
    }
    /// A file they uploaded (`relation` "uploader") or are named a reader of
    /// ("reader"). A private file's `url` expires at `urlExpiresAt` (5
    /// minutes); a file anyone can read has a permanent `url` and no
    /// `urlExpiresAt`.
    public struct File: Sendable, Equatable {
        public let ref: String
        public let collection: String
        public let relation: String
        public let name: String?
        public let contentType: String
        public let sizeBytes: Int?
        public let createdAt: String
        public let url: String
        public let urlExpiresAt: String?
    }
    /// The same summary `purchases.mine()` answers, with its payment reference.
    public struct Purchase: Sendable, Equatable {
        public let item: String
        public let kind: String
        public let paymentRef: String?
        public let amountMinor: Int?
        public let currency: String?
        public let refundedMinor: Int
        /// "paid", "part_refunded" or "refunded".
        public let status: String
        public let grants: [String]
        public let paidAt: String
    }
    public struct Subscription: Sendable, Equatable {
        public let plan: String
        public let status: String
        public let since: String
        public let lastEventAt: String?
    }
    public struct Credits: Sendable, Equatable {
        public struct Balance: Sendable, Equatable {
            public let balance: Int
            public let reserved: Int
            /// The credits that expire next, and when; nil when none do.
            public let expiringCredits: Int?
            public let expiringAt: String?
        }
        public struct Grant: Sendable, Equatable {
            public let id: String
            public let amount: Int
            public let remaining: Int
            public let source: String
            public let expiresAt: String?
            public let expiredAt: String?
            public let createdAt: String
        }
        public struct Reservation: Sendable, Equatable {
            public let id: String
            public let amount: Int
            public let consumed: Int?
            public let status: String
            public let expiresAt: String
            public let createdAt: String
            public let closedAt: String?
        }
        public struct LedgerEntry: Sendable, Equatable {
            public let id: String
            public let kind: String
            public let delta: Int
            public let balanceAfter: Int
            public let sourceType: String
            public let createdAt: String
        }
        public let balance: Balance
        public let grants: [Grant]
        public let reservations: [Reservation]
        public let ledger: [LedgerEntry]
    }
    public struct Access: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let ref: String
        public let sourceType: String
        public let startsAt: String
        public let expiresAt: String?
        public let revokedAt: String?
        public let createdAt: String
    }
    public struct Email: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let sentTo: String?
        public let sentAt: String
        public let skippedReason: String?
    }
    /// A conversation with the app's support inbox, matched on their sign-in address.
    public struct SupportThread: Sendable, Equatable {
        public struct Message: Sendable, Equatable {
            /// "from_person" or "to_person".
            public let direction: String
            public let subject: String
            public let text: String
            /// Attachment names.
            public let attachments: [String]
            public let at: String
        }
        public let subject: String
        public let startedAt: String
        public let lastMessageAt: String
        public let messages: [Message]
    }
    public struct Session: Sendable, Equatable {
        public let id: String
        public let createdAt: String
        public let expiresAt: String
        public let revokedAt: String?
    }
    public struct SignIn: Sendable, Equatable {
        public let event: String
        public let at: String
        public let allowed: Bool
        public let ip: String?
    }
    public struct Limits: Sendable, Equatable {
        /// Each section's cap.
        public struct Caps: Sendable, Equatable {
            public static let keys = ["records", "files", "marks", "purchases", "aiCalls", "runs", "creditLedger", "emails", "sessions", "signIns", "support"]
            public let records: Int
            public let files: Int
            public let marks: Int
            public let purchases: Int
            public let aiCalls: Int
            public let runs: Int
            public let creditLedger: Int
            public let emails: Int
            public let sessions: Int
            public let signIns: Int
            public let support: Int
        }
        public let caps: Caps
        /// The UTF-8 byte budget records, AI calls, runs and support messages share.
        public let textBudgetBytes: Int
        /// Every section something was left out of — empty when the export is whole.
        public let truncated: [String]
    }

    public let exportVersion: Int
    public let about: About
    public let exportedAt: String
    public let app: App
    public let person: Person
    /// By collection name.
    public let records: [String: [Record]]
    public let recordCount: Int
    public let marks: [Mark]
    public let files: [File]
    public let purchases: [Purchase]
    public let subscription: Subscription?
    public let credits: Credits
    public let access: [Access]
    /// The same records `ai.calls()` returns — never the tool's prompt.
    public let aiCalls: [AiCallRecord]
    /// The same view `runs` returns (result files are in `files`).
    public let runs: [Run]
    public let emails: [Email]
    public let support: [SupportThread]
    public let sessions: [Session]
    public let signIns: [SignIn]
    public let limits: Limits
    /// The full export, exactly as Gemmein sent it.
    public let document: [String: JSONValue]

    init(json: [String: JSONValue]) {
        document = json
        func objects(_ v: JSONValue?) -> [[String: JSONValue]] { (v?.array ?? []).compactMap { $0.object } }
        func strings(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap { $0.string } }
        exportVersion = json["exportVersion"]?.int ?? 0
        let ab = json["about"]?.object ?? [:]
        about = About(what: ab["what"]?.string ?? "", app: ab["app"]?.string, generatedAt: ab["generatedAt"]?.string ?? "",
                      door: ab["door"]?.string ?? "", producedBy: ab["producedBy"]?.string ?? "", sections: strings(ab["sections"]),
                      limits: ab["limits"]?.string ?? "",
                      notIncluded: objects(ab["notIncluded"]).map { .init(what: $0["what"]?.string ?? "", why: $0["why"]?.string ?? "") },
                      termsUrl: ab["termsUrl"]?.string, ownerContact: ab["ownerContact"]?.string, rights: ab["rights"]?.string ?? "")
        exportedAt = json["exportedAt"]?.string ?? ""
        let a = json["app"]?.object ?? [:]
        app = App(appId: a["appId"]?.string ?? "", environmentId: a["environmentId"]?.string ?? "")
        let p = json["person"]?.object ?? [:]
        person = Person(id: p["id"]?.string ?? "", email: p["email"]?.string ?? "", createdAt: p["createdAt"]?.string ?? "",
                        lastSignInAt: p["lastSignInAt"]?.string, suspendedAt: p["suspendedAt"]?.string, invitedAt: p["invitedAt"]?.string)
        records = (json["records"]?.object ?? [:]).mapValues { list in
            objects(list).map { r in
                Record(id: r["id"]?.string ?? "", relation: r["relation"]?.string ?? "", data: r["data"]?.object ?? [:],
                       to: r["to"]?.string, recipients: r["recipients"]?.array.map { $0.compactMap { $0.string } }, from: r["from"]?.string,
                       createdAt: r["createdAt"]?.string ?? "", updatedAt: r["updatedAt"]?.string ?? "")
            }
        }
        recordCount = json["recordCount"]?.int ?? 0
        marks = objects(json["marks"]).map { Mark(recordId: $0["recordId"]?.string ?? "", field: $0["field"]?.string ?? "", createdAt: $0["createdAt"]?.string ?? "") }
        files = objects(json["files"]).map { f in
            File(ref: f["ref"]?.string ?? "", collection: f["collection"]?.string ?? "", relation: f["relation"]?.string ?? "",
                 name: f["name"]?.string, contentType: f["contentType"]?.string ?? "", sizeBytes: f["sizeBytes"]?.int,
                 createdAt: f["createdAt"]?.string ?? "", url: f["url"]?.string ?? "", urlExpiresAt: f["urlExpiresAt"]?.string)
        }
        purchases = objects(json["purchases"]).map { x in
            Purchase(item: x["item"]?.string ?? "", kind: x["kind"]?.string ?? "", paymentRef: x["paymentRef"]?.string,
                     amountMinor: x["amountMinor"]?.int, currency: x["currency"]?.string, refundedMinor: x["refundedMinor"]?.int ?? 0,
                     status: x["status"]?.string ?? "", grants: strings(x["grants"]), paidAt: x["paidAt"]?.string ?? "")
        }
        subscription = json["subscription"]?.object.map { x in
            Subscription(plan: x["plan"]?.string ?? "", status: x["status"]?.string ?? "", since: x["since"]?.string ?? "", lastEventAt: x["lastEventAt"]?.string)
        }
        let c = json["credits"]?.object ?? [:]
        let b = c["balance"]?.object ?? [:]
        let expiring = b["expiring"]?.object
        credits = Credits(
            balance: .init(balance: b["balance"]?.int ?? 0, reserved: b["reserved"]?.int ?? 0, expiringCredits: expiring?["credits"]?.int, expiringAt: expiring?["at"]?.string),
            grants: objects(c["grants"]).map { g in
                .init(id: g["id"]?.string ?? "", amount: g["amount"]?.int ?? 0, remaining: g["remaining"]?.int ?? 0, source: g["source"]?.string ?? "",
                      expiresAt: g["expiresAt"]?.string, expiredAt: g["expiredAt"]?.string, createdAt: g["createdAt"]?.string ?? "")
            },
            reservations: objects(c["reservations"]).map { r in
                .init(id: r["id"]?.string ?? "", amount: r["amount"]?.int ?? 0, consumed: r["consumed"]?.int, status: r["status"]?.string ?? "",
                      expiresAt: r["expiresAt"]?.string ?? "", createdAt: r["createdAt"]?.string ?? "", closedAt: r["closedAt"]?.string)
            },
            ledger: objects(c["ledger"]).map { e in
                .init(id: e["id"]?.string ?? "", kind: e["kind"]?.string ?? "", delta: e["delta"]?.int ?? 0, balanceAfter: e["balanceAfter"]?.int ?? 0,
                      sourceType: e["sourceType"]?.string ?? "", createdAt: e["createdAt"]?.string ?? "")
            }
        )
        access = objects(json["access"]).map { x in
            Access(id: x["id"]?.string ?? "", kind: x["kind"]?.string ?? "", ref: x["ref"]?.string ?? "", sourceType: x["sourceType"]?.string ?? "",
                   startsAt: x["startsAt"]?.string ?? "", expiresAt: x["expiresAt"]?.string, revokedAt: x["revokedAt"]?.string, createdAt: x["createdAt"]?.string ?? "")
        }
        aiCalls = objects(json["aiCalls"]).map { AiCallRecord(json: $0) }
        runs = objects(json["runs"]).map { Run(json: $0) }
        emails = objects(json["emails"]).map { x in
            Email(id: x["id"]?.string ?? "", kind: x["kind"]?.string ?? "", sentTo: x["sentTo"]?.string, sentAt: x["sentAt"]?.string ?? "", skippedReason: x["skippedReason"]?.string)
        }
        support = objects(json["support"]).map { t in
            SupportThread(subject: t["subject"]?.string ?? "", startedAt: t["startedAt"]?.string ?? "", lastMessageAt: t["lastMessageAt"]?.string ?? "",
                          messages: objects(t["messages"]).map { m in
                              .init(direction: m["direction"]?.string ?? "", subject: m["subject"]?.string ?? "", text: m["text"]?.string ?? "",
                                    attachments: strings(m["attachments"]), at: m["at"]?.string ?? "")
                          })
        }
        sessions = objects(json["sessions"]).map { x in
            Session(id: x["id"]?.string ?? "", createdAt: x["createdAt"]?.string ?? "", expiresAt: x["expiresAt"]?.string ?? "", revokedAt: x["revokedAt"]?.string)
        }
        signIns = objects(json["signIns"]).map { x in
            SignIn(event: x["event"]?.string ?? "", at: x["at"]?.string ?? "", allowed: x["allowed"]?.bool ?? false, ip: x["ip"]?.string)
        }
        let l = json["limits"]?.object ?? [:]
        let k = l["caps"]?.object ?? [:]
        limits = Limits(
            caps: .init(records: k["records"]?.int ?? 0, files: k["files"]?.int ?? 0, marks: k["marks"]?.int ?? 0, purchases: k["purchases"]?.int ?? 0,
                        aiCalls: k["aiCalls"]?.int ?? 0, runs: k["runs"]?.int ?? 0, creditLedger: k["creditLedger"]?.int ?? 0, emails: k["emails"]?.int ?? 0,
                        sessions: k["sessions"]?.int ?? 0, signIns: k["signIns"]?.int ?? 0, support: k["support"]?.int ?? 0),
            textBudgetBytes: l["textBudgetBytes"]?.int ?? 0,
            truncated: strings(l["truncated"])
        )
    }

    /// The document as pretty-printed JSON bytes — the file a person saves.
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: document.mapValues { $0.foundationValue }, options: [.prettyPrinted, .sortedKeys])
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
    /// What the person was answered, only when the tool records calls.
    /// There is no prompt: the request a tool sends is the owner's — the
    /// back office keeps it, a person never sees it.
    public let answer: String?
    /// What was metered: "call", "tokens", "seconds", "images" or
    /// "characters", and the count the charge came from. Nil on a call from
    /// before unit prices.
    public let units: String?
    public let unitCount: Double?
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
        answer = json["answer"]?.string
        units = json["units"]?.string
        unitCount = json["unitCount"]?.double
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
    /// Set when nothing was sent because the address bounced for good
    /// ("address_bounced") or its owner marked this app's mail as spam
    /// ("address_complained"). `sent` is false; don't retry.
    public let notSent: String?
    /// The sentence for `notSent` ("not sent: address bounced" / "not sent:
    /// address marked as spam").
    public let message: String?

    init(json: [String: JSONValue]) {
        sent = json["sent"]?.bool ?? false
        deduped = json["deduped"]?.bool
        id = json["id"]?.string
        threadId = json["threadId"]?.string
        replyRail = json["replyRail"]?.bool
        recorded = json["recorded"]?.bool
        notSent = json["notSent"]?.string
        message = json["message"]?.string
    }
}

/// What `notify` is for. `account` (a new sign-in, an access change, a billing
/// problem) skips the per-person cap — a security notice must never lose to
/// five order emails.
public enum NotifyKind: String, Sendable {
    case event, account
}

// ── runs (job tools) ─────────────────────────────────────────────────────

/// A run's state. Open: `queued` · `running`. Ended: `succeeded` · `failed`
/// · `cancelled` · `expired`. A state this build does not know arrives as
/// `.other` and is treated as open.
public enum RunStatus: Sendable, Equatable {
    case queued, running, succeeded, failed, cancelled, expired
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "queued": self = .queued
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "expired": self = .expired
        default: self = .other(raw)
        }
    }

    /// `succeeded` · `failed` · `cancelled` · `expired` — `watch` stops here.
    public var isEnded: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .expired: return true
        case .queued, .running, .other: return false
        }
    }
}

/// One output of a succeeded run — a sealed file on the person.
public struct RunResultFile: Sendable, Equatable {
    public let ref: String
    public let contentType: String
    public let sizeBytes: Int
    /// A short-lived signed URL minted for THIS answer — neither a ref nor a
    /// URL is proof of access; call `runs.get` again when it lapses.
    public let url: String?
    public let urlExpiresAt: String?

    init(json: [String: JSONValue]) {
        ref = json["ref"]?.string ?? ""
        contentType = json["contentType"]?.string ?? ""
        sizeBytes = json["sizeBytes"]?.int ?? 0
        url = json["url"]?.string
        urlExpiresAt = json["urlExpiresAt"]?.string
    }
}

/// A succeeded run's outputs: sealed files on the person and/or the text the
/// provider answered.
public struct RunResult: Sendable, Equatable {
    public let files: [RunResultFile]
    public let text: String?
}

/// A pipeline (`provider: "external"`) run's own hand-off. `attempts` counts
/// the signed POSTs sent to the tool's URL; `acknowledgedAt` is set once one
/// answered 2xx; `lastError` is the most recent delivery problem.
public struct RunHandoff: Sendable, Equatable {
    public let attempts: Int
    public let acknowledgedAt: String?
    public let lastError: String?
}

/// A RUN — what a job tool (generate · transcribe) answers with. Reserved at
/// the ceiling when it is created, ended one of four ways.
public struct Run: Sendable, Equatable {
    public let id: String
    public let tool: String
    /// "generate" or "transcribe".
    public let kind: String
    public let status: RunStatus
    /// 0…100 when the provider says, else nil.
    public let progress: Int?
    /// The app's own key for the run, when it sent one.
    public let key: String?
    /// The ceiling held at creation — never changes once the run exists.
    public let reserved: Int
    /// What is STILL held right now: `reserved` while open, 0 once ended.
    public let held: Int
    /// What it cost once ended (nil while open).
    public let charged: Int?
    /// "call", "tokens", "seconds", "images" or "characters".
    public let units: String
    public let unitCount: Double?
    /// Nil until succeeded.
    public let result: RunResult?
    /// A pipeline's own untyped output, verbatim. Nil until succeeded, or
    /// when none was sent.
    public let data: JSONValue?
    /// Why it failed or expired; nil otherwise.
    public let error: String?
    public let createdAt: String
    public let updatedAt: String
    public let endedAt: String?
    /// Nil for every provider but `external`.
    public let handoff: RunHandoff?

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        tool = json["tool"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        status = RunStatus(json["status"]?.string ?? "")
        progress = json["progress"]?.int
        key = json["key"]?.string
        reserved = json["reserved"]?.int ?? 0
        held = json["held"]?.int ?? 0
        charged = json["charged"]?.int
        units = json["units"]?.string ?? ""
        unitCount = json["unitCount"]?.double
        if let r = json["result"]?.object {
            result = RunResult(
                files: (r["files"]?.array ?? []).compactMap { $0.object.map { RunResultFile(json: $0) } },
                text: r["text"]?.string
            )
        } else {
            result = nil
        }
        if let d = json["data"], !d.isNull { data = d } else { data = nil }
        error = json["error"]?.string
        createdAt = json["createdAt"]?.string ?? ""
        updatedAt = json["updatedAt"]?.string ?? ""
        endedAt = json["endedAt"]?.string
        if let h = json["handoff"]?.object {
            handoff = RunHandoff(attempts: h["attempts"]?.int ?? 0, acknowledgedAt: h["acknowledgedAt"]?.string, lastError: h["lastError"]?.string)
        } else {
            handoff = nil
        }
    }
}
