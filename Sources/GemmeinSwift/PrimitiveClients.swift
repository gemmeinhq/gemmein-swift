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
    /// card: the app owner's Stripe customer portal, with their email filled
    /// in. Throws 409 `portal_not_set_up` until the owner pastes the portal
    /// link on Payments. Open the url yourself.
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
