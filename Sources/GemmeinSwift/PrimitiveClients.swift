import Foundation

/// The signed-in customer's own purchase history, read from Gemmein's
/// immutable commercial record rather than from your data — so a buyer keeps
/// proof of what they paid for even when you keep no receipts collection.
public final class PurchasesClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Everything this customer has paid for, newest first, with refunds
    /// already applied. Throws `GemmeinError` (401) when nobody is signed in.
    // route: GET /auth/purchases
    public func mine() async throws -> [Purchase] {
        let body = try requireObject(try await runtimeRequest(config, "/auth/purchases"), "purchases")
        return (body["purchases"]?.array ?? []).compactMap { $0.object.map { Purchase(json: $0) } }
    }
}

/// Turn a stored file reference into a URL you can actually use.
///
///     let link = try await g.files.link(record.data["poster"]!.string!)
///     imageView.load(link.url)
///
/// If the collection is one anyone can read you get a permanent, cacheable
/// URL. If it isn't you get one that works for a couple of minutes and is
/// re-checked against who you are, what the collection's rule says, whether
/// the file is yours, and whether you still hold whatever the collection
/// requires. Don't store what this returns — store the reference and call this
/// again.
public final class FilesClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// One call for every file, whichever collection it lives in. Documents
    /// always download — link them with `intent: .download`.
    // route: GET /files/{ref}/link
    public func link(_ ref: String, intent: LinkIntent? = nil) async throws -> FileLink {
        let query = intent == .download ? "?intent=download" : ""
        let body = try requireObject(
            try await runtimeRequest(config, "/files/\(percentEncodeComponent(ref))/link\(query)"),
            "a file link"
        )
        return FileLink(json: body)
    }
}

/// The subscription primitive, self-service side. Gemmein keeps exactly one
/// subscription per customer — created by the payment itself, updated by
/// Stripe's signed webhooks, overridable by the owner in their dashboard. The
/// client surface is deliberately read-plus-checkout only: there is no client
/// write path to plan or status, by design.
public final class SubscriptionsClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// The signed-in person's subscription — gate features with
    /// `try await g.subscriptions.mine()?.plan == "pro"`. Nil when payments
    /// are off or this person has never paid; throws `GemmeinError` (401) when
    /// nobody is signed in.
    // route: GET /auth/subscription
    public func mine() async throws -> Subscription? {
        let body = try requireObject(try await runtimeRequest(config, "/auth/subscription"), "a subscription")
        guard let sub = body["subscription"]?.object else { return nil }
        return Subscription(plan: sub["plan"]?.string ?? "", status: sub["status"]?.string ?? "", trialEndsAt: sub["trialEndsAt"]?.string, endsAt: sub["endsAt"]?.string)
    }

    /// The plans this app sells, in the order the dashboard shows them — for
    /// a pricing page. Payments → Plans IS the list: never keep plans in a
    /// collection. Only what can be bought right now is listed, plus the free
    /// plan (price 0). No sign-in needed. Each plan's own words and pictures
    /// live in your code, keyed by `name`; start a purchase with
    /// `checkout(plan:)`.
    // route: GET /catalog
    public func plans() async throws -> [CatalogPlan] {
        let body = try requireObject(try await runtimeRequest(config, "/catalog"), "the catalog")
        return (body["plans"]?.array ?? []).compactMap { $0.object }.map { p in
            let credits = p["credits"]?.object
            return CatalogPlan(
                name: p["name"]?.string ?? "",
                free: p["free"]?.bool ?? false,
                price: catalogPrice(p["price"]),
                creditsPerPeriod: credits?["perPeriod"]?.int,
                creditsOnce: credits?["once"]?.int,
                unlocks: (p["unlocks"]?.array ?? []).compactMap { $0.string }
            )
        }
    }

    /// Start a Stripe checkout for a plan — Gemmein mints the URL with the
    /// signed-in buyer and the plan already wired in (never build checkout
    /// URLs yourself). Plans need a signed-in user; products can be bought
    /// signed out. This RETURNS the URL and never opens it: on iOS you
    /// decide, and the right answer is usually `ASWebAuthenticationSession` or
    /// `SFSafariViewController`. Omit `plan` to buy the app's paid plan.
    // route: GET /auth/checkout
    public func checkout(plan: String? = nil) async throws -> CheckoutSession {
        let query = plan.map { "?plan=\(percentEncodeComponent($0))" } ?? ""
        let body = try requireObject(try await runtimeRequest(config, "/auth/checkout\(query)"), "a checkout")
        return CheckoutSession(url: body["url"]?.string ?? "", plan: body["plan"]?.string ?? "")
    }

    /// Where the signed-in subscriber changes plan, cancels or updates their
    /// card: a Stripe customer portal session Gemmein opens for this member,
    /// set up from the app's plans. Throws 409 `no_subscription` (never paid
    /// for a plan) or `portal_unavailable`. Open the url yourself.
    // route: GET /auth/subscription/manage
    public func manage() async throws -> ManageLink {
        let body = try requireObject(try await runtimeRequest(config, "/auth/subscription/manage"), "a manage link")
        return ManageLink(url: body["url"]?.string ?? "")
    }
}

/// The one-off purchase primitive — things, not plans (plans are
/// `subscriptions`).
public final class PaymentsClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// The products this app sells, in the order the dashboard shows them —
    /// for a storefront. Payments → Products IS the catalog: never keep
    /// products in a collection. Only what can be bought right now is
    /// listed. No sign-in needed. Each product's own words and pictures live
    /// in your code, keyed by `name`; start a purchase with `buy(_:)`.
    // route: GET /catalog
    public func products() async throws -> [CatalogProduct] {
        let body = try requireObject(try await runtimeRequest(config, "/catalog"), "the catalog")
        return (body["products"]?.array ?? []).compactMap { $0.object }.map { p in
            CatalogProduct(
                name: p["name"]?.string ?? "",
                price: catalogPrice(p["price"]),
                delivers: p["delivers"]?.string ?? "none",
                credits: p["credits"]?.int,
                unlocks: (p["unlocks"]?.array ?? []).compactMap { $0.string }
            )
        }
    }

    /// Buy a one-off product. RETURNS the URL and never opens it. The optional
    /// `item` note names WHAT is being bought when one product covers many
    /// things: `buy("premium license", item: "beat_37")`. A completed payment
    /// writes a receipt record addressed to the buyer; gate downloads on that
    /// receipt, never on the redirect coming back. Products can be bought
    /// signed out: the buyer gives Stripe Checkout their email, and the
    /// purchase is theirs the first time they sign in with it (plans need
    /// sign-in); only an `item` note
    /// needs a signed-in buyer. Gemmein emails the buyer a Library link by
    /// default.
    // route: GET /auth/pay
    public func buy(_ product: String, item: String? = nil) async throws -> PaymentSession {
        var pairs = [("product", product)]
        if let item { pairs.append(("item", item)) }
        let body = try requireObject(try await runtimeRequest(config, "/auth/pay?\(formURLEncode(pairs))"), "a payment")
        return PaymentSession(url: body["url"]?.string ?? "", product: body["product"]?.string ?? "", item: body["item"]?.string)
    }
}

/// The signed-in person's own account — self-service, one deliberate power.
public final class AccountClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Self-service erasure — the "delete my account" screen. Every app it
    /// APPLIES to needs one (GDPR right to erasure; Apple 5.1.1(v) requires it
    /// for any app with account creation). Server-side this is the full
    /// cascade: sessions revoked, the person's records and files deleted,
    /// their subscription row removed. Irreversible — put a real confirm in
    /// front of it. The stored session is cleared here.
    // route: POST /auth/delete-account
    @discardableResult
    public func delete() async throws -> JSONValue? {
        let answer = try await runtimeRequest(config, "/auth/delete-account", method: "POST")
        await config.tokenStore.clear()
        return answer
    }

    /// Self-service data export — the "download my data" button (GDPR right
    /// of access and portability). Returns ONE JSON document of everything
    /// this person holds in the app: their profile, every record they wrote
    /// or that names them (grouped by collection), their files as download
    /// links that expire in minutes, purchases, subscription, credits and
    /// their ledger, access grants, AI calls and runs, emails the app sent
    /// them, sessions and sign-ins. It holds what the person may read under
    /// the app's rules — nothing another person keeps private. Once every
    /// 30 days, counted from the last export; another inside that window throws
    /// `export_rate_limited` (429) with `resetAt` and a sentence giving the
    /// date. (The owner's dashboard export counts separately, once a day.)
    ///
    ///     let export = try await g.account.export()
    ///     let bytes = try export.jsonData()   // hand these to a share sheet
    // route: GET /auth/export-account
    public func export() async throws -> AccountExport {
        AccountExport(json: try requireObject(try await runtimeRequest(config, "/auth/export-account"), "an account export"))
    }
}

/// The signed-in person's own credits — so an app can draw its own meter.
public final class CreditsClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// The balance RIGHT NOW, server-resolved — the number that refuses at
    /// zero, never client math. Session required (`session_required`, 401).
    // route: GET /auth/credits
    public func balance() async throws -> Int {
        let body = try requireObject(try await runtimeRequest(config, "/auth/credits"), "a credit balance")
        return body["balance"]?.int ?? 0
    }
}

/// THREE JOBS — your app calls a relay by name (its trigger is `{ "kind": "app_call" }`).
/// This is how a user's ACTION costs credits: the relay's first action, `spend_credits`,
/// takes the signed-in person's OWN credits before anything is written — or refuses with
/// `credits_exhausted` (402) and nothing else runs — then its other actions run. An iPhone
/// app holds no key; the person is whoever is signed in, never a field you send.
///
///     let result = try await g.relays.call("book-class", input: ["class": .string(id)], key: tapId)
///
/// Pass `key` so a retry after a dropped connection answers the SAME run — never a second
/// charge. If what the charge pays for fails the credits are refunded and it throws
/// `relay_failed`; once that is done the charge stands (a later step retries).
/// Refusals throw GemmeinError with `code`: session_required · credits_exhausted ·
/// not_callable · call_in_progress (ask again with the same key) · call_not_finished ·
/// input_too_large · too_many_calls · daily_cap ·
/// relay_failed · relay_paused.
public final class RelaysClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    // route: POST /relays/{name}/call
    public func call(_ name: String, input: JSONValue = .null, key: String? = nil) async throws -> RelayCallResult {
        var fields: [String: JSONValue] = ["input": input]
        if let key { fields["key"] = .string(key) }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        let body = try requireObject(try await runtimeRequest(config, "/relays/\(encoded)/call", method: "POST", body: try JSONCodec.encode(fields), extraHeaders: ["content-type": "application/json"]), "a relay call")
        // 202: the first call with this key is still working — ask again with the SAME key.
        if body["code"]?.string == "call_in_progress" {
            throw GemmeinError(status: 202, code: "call_in_progress", message: body["message"]?.string ?? "still working — ask again with the same key")
        }
        let records: [RelayCallRecord] = (body["records"]?.array ?? []).compactMap { item in
            guard let o = item.object, let collection = o["collection"]?.string, let id = o["id"]?.string else { return nil }
            return RelayCallRecord(collection: collection, id: id)
        }
        return RelayCallResult(runId: body["run"]?.object?["id"]?.string ?? "", spent: body["spent"]?.int, balance: body["balance"]?.int, records: records, deduped: body["deduped"]?.bool ?? false)
    }
}

/// One record a relay call wrote.
public struct RelayCallRecord: Sendable {
    public let collection: String
    public let id: String
}

/// What a relay call answers: what it charged (0 on a deduped retry; nil when the relay
/// charges nothing), the balance after, and the records the relay wrote.
public struct RelayCallResult: Sendable {
    public let runId: String
    public let spent: Int?
    public let balance: Int?
    public let records: [RelayCallRecord]
    public let deduped: Bool
}

/// Your app's collections.
public final class StorageClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// `g.storage.collection("notes")` — the same client `g.collection(_:)`
    /// hands back.
    // route: none
    public func collection(_ name: String, intent: String? = nil) throws -> CollectionClient {
        try assertCollectionName(name)
        return CollectionClient(config: config, name: name, intent: intent)
    }
}

/// ONE CATALOG: a catalog price off the wire.
func catalogPrice(_ value: JSONValue?) -> CatalogPrice {
    let o = value?.object
    return CatalogPrice(amountMinor: o?["amountMinor"]?.int ?? 0, currency: o?["currency"]?.string, period: o?["period"]?.string)
}
