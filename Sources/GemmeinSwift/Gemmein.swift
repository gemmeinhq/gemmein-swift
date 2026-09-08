import Foundation

/// The client — two layers:
///
///  - `g.collection("notes")` — YOUR app's collections. Records, files, safety
///    rules. This is where your app's own data model lives.
///  - Business primitives Gemmein runs for you: `g.auth` (sign-in),
///    `g.subscriptions` (who's on which plan), `g.payments` (one-off
///    purchases), `g.purchases` (what they bought), `g.account` (the user's
///    own account), `g.files`, `g.credits`, `g.ai`. These are SELF-SERVICE
///    surfaces for the signed-in person — reads and hand-offs, never admin
///    powers. Managing other people's users, subscriptions or records happens
///    in the owner's dashboard (app.gemmein.com), on purpose.
///
/// The client policy: the public key identifies the app; the session
/// authorises the person; verified domains are for browsers.
public final class Gemmein: @unchecked Sendable {
    public let auth: AuthClient
    public let storage: StorageClient
    public let subscriptions: SubscriptionsClient
    public let payments: PaymentsClient
    public let purchases: PurchasesClient
    public let account: AccountClient
    public let files: FilesClient
    /// The signed-in person's own credit balance.
    public let credits: CreditsClient
    /// The AI route: OpenAI / Anthropic / Google on the owner's key.
    public let ai: AiClient

    /// Where the session lives. On Apple platforms the default is the
    /// Keychain, so a relaunch keeps the person signed in.
    public let tokenStore: TokenStore

    /// - Parameters:
    ///   - appKey: your app's PUBLIC key (`pk_…`). Secret keys (`sk_…`) are
    ///     refused here — they belong on a server, never in an app bundle.
    ///   - apiURL: the engine. Defaults to Gemmein's cloud; point it at your
    ///     local `gemmein dev` engine while you build.
    ///   - tokenStore: where the session lives. Defaults to the Keychain.
    ///   - platform: appended to `x-client-info`. Defaults to this OS.
    ///   - session: the `URLSession` every request goes through.
    public init(
        appKey: String,
        apiURL: URL = defaultAPIURL,
        tokenStore: TokenStore? = nil,
        platform: String? = nil,
        session: URLSession = .shared
    ) throws {
        if appKey.hasPrefix("sk_") {
            throw GemmeinError(
                status: 0,
                code: "invalid_app_key",
                message: "Secret keys (sk_) must not be used in the client SDK — use GemmeinServer instead"
            )
        }
        // The signpost: a build without a key gets routed, not stuck.
        if !appKey.hasPrefix("pk_") {
            throw GemmeinError(
                status: 0,
                code: "missing_app_key",
                message: "Gemmein needs your app key (it starts with \"pk_\"). Get one in 30 seconds: "
                    + "sign in at https://app.gemmein.com with an email code (free, no card) and "
                    + "copy the key from the Setup page. Then: Gemmein(appKey: \"pk_...\")"
            )
        }

        let store = tokenStore ?? KeychainTokenStore(appKey: appKey)
        let config = ClientConfig(
            apiURL: apiURL,
            appKey: appKey,
            tokenStore: store,
            clientInfo: GemmeinSwift.clientInfo(platform: platform ?? GemmeinSwift.platform),
            session: session
        )
        self.tokenStore = store
        self.auth = AuthClient(config: config)
        self.storage = StorageClient(config: config)
        self.subscriptions = SubscriptionsClient(config: config)
        self.payments = PaymentsClient(config: config)
        self.purchases = PurchasesClient(config: config)
        self.account = AccountClient(config: config)
        self.files = FilesClient(config: config)
        self.credits = CreditsClient(config: config)
        self.ai = AiClient(config: config)
    }

    /// Your app's data — `g.collection("notes")`. The canonical spelling;
    /// `g.storage.collection(name)` is the same client.
    ///
    /// `intent` (one sentence: what this collection is for and who should
    /// access it) travels with every call. Against a LOCAL gemmein dev
    /// runtime, an undeclared collection then reaches the human with your
    /// suggestion attached. The cloud ignores it.
    // route: none
    public func collection(_ name: String, intent: String? = nil) throws -> CollectionClient {
        try storage.collection(name, intent: intent)
    }
}
