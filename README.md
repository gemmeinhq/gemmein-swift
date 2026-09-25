# GemmeinSwift

The Gemmein SDK for Swift — the same HTTP contract and the same method names
as `@gemmein/sdk`, in Swift idiom. Sign-in, your app's collections, files,
subscriptions, one-off payments, credits and the AI route, for iOS 17+ and
macOS 14+. No dependencies.

## Install

Swift Package Manager — in Xcode, **File → Add Package Dependencies**, or in a
`Package.swift`:

```swift
.package(url: "https://github.com/gemmeinhq/gemmein-swift.git", from: "0.10.0")
```

## Sign in

Two calls: send the code, verify the code. The session is stored in the
Keychain, so relaunching the app keeps the person signed in.

```swift
import GemmeinSwift

let g = try Gemmein(appKey: "pk_live_…")

try await g.auth.sendEmailCode("person@example.com")
// …the person types the eight digits you emailed them…
let session = try await g.auth.verifyEmailCode(email: "person@example.com", code: code)

let me = try await g.auth.currentUser()   // never throws for session state
```

## Your app's data

```swift
let notes = try g.collection("notes")

let note = try await notes.create(["title": "Ran", "done": false])
let page = try await notes.list(ListOptions(limit: 20, sort: .newest))
try await notes.update(note.id, ["done": true], ifVersion: note.version)
try await notes.delete(note.id)
```

Your fields always live under `data` — `note.data["title"]?.string`. Everything
else on a record is server-derived and read-only.

A record body is `[String: JSONValue]`. A **literal** needs no ceremony
(`["title": "Ran", "done": false, "seats": 4]`); a **variable** needs its case:

```swift
try await notes.create(["title": .string(typed), "seats": .int(count)])
```

## Every signature

The same method names as `@gemmein/sdk`, so a table is the fastest way to see
what Swift wants. Argument labels are as written here; everything that leaves
the device is `async throws` and throws `GemmeinError`.

### The client

| Method | Signature | Returns |
|---|---|---|
| `Gemmein.init` | `init(appKey: String, apiURL: URL = defaultAPIURL, tokenStore: TokenStore? = nil, platform: String? = nil, session: URLSession = .shared) throws` | `Gemmein` |
| `g.collection(_:intent:)` | `func collection(_ name: String, intent: String? = nil) throws -> CollectionClient` | `CollectionClient` |

`g.auth`, `g.storage`, `g.subscriptions`, `g.payments`, `g.purchases`,
`g.account`, `g.files`, `g.credits`, `g.ai` and `g.tokenStore` are properties.

### `g.auth`

| Method | Signature | Returns |
|---|---|---|
| `sendEmailCode(_:)` | `func sendEmailCode(_ email: String) async throws` | `Void` |
| `verifyEmailCode(email:code:)` | `func verifyEmailCode(email: String, code: String) async throws -> AuthSession` | `AuthSession` — `token`, `expiresAt`, `user` |
| `logout()` | `func logout() async throws` | `Void` — idempotent |
| `currentUser()` | `func currentUser() async throws -> CurrentUser` | `CurrentUser` — `authenticated`, `userId`, `email`, `storeAccountToken` |

### `g.collection(_:)`

| Method | Signature | Returns |
|---|---|---|
| `create(_:key:for:published:)` | `@discardableResult func create(_ data: [String: JSONValue], key: String? = nil, for recipient: String? = nil, published: Bool? = nil) async throws -> GemmeinRecord` | `GemmeinRecord` |
| `list(_:)` | `func list(_ options: ListOptions = ListOptions()) async throws -> ListResult` | `ListResult` — `records`, `cursor`, `hasMore`, `deleted`, `watermark` |
| `get(_:expand:)` | `func get(_ id: String, expand: [String] = []) async throws -> GemmeinRecord` | `GemmeinRecord` |
| `update(_:_:ifVersion:published:)` | `@discardableResult func update(_ id: String, _ data: [String: JSONValue], ifVersion: Int? = nil, published: Bool? = nil) async throws -> GemmeinRecord` | `GemmeinRecord` |
| `delete(_:)` | `func delete(_ id: String) async throws` | `Void` |
| `upload(_:name:contentType:for:)` | `func upload(_ data: Data, name: String = "upload", contentType: String = "", for recipient: String? = nil) async throws -> UploadedFile` | `UploadedFile` — `id`, `ref` (`file:<uuid>`), `contentType`, `sizeBytes: Int` |
| `count(where:search:)` | `func count(where filter: [String: JSONValue]? = nil, search: String? = nil) async throws -> Int` | `Int` — how many records this person could list, under the same rule, scope and filters |
| `stats(_:where:search:)` | `func stats(_ field: String, where filter: [String: JSONValue]? = nil, search: String? = nil) async throws -> RecordStats` | `RecordStats` — `count`, `sum`, `avg`, `min`, `max` (nil when no record held a number) |
| `watch(every:where:search:limit:onChange:)` | `func watch(every: TimeInterval? = nil, where filter: [String: JSONValue]? = nil, search: String? = nil, limit: Int? = nil, onChange: @escaping @Sendable (WatchDelta) -> Void) -> Watcher` | `Watcher` — not `async`; end it with `watcher.stop()` |

`ListOptions(limit:sort:where:cursor:search:expand:since:)` — all optional.
`sort` is `ListSort`: `.newest`, `.oldest`, `.updated`.
`where` is the same on `list`, `watch`, `count` and `stats`: a literal is an exact match; an object of operators narrows it — `eq` `ne` `gt` `gte` `lt` `lte` `in` `nin` `contains` `startsWith` `exists` (`["amount": ["gte": .int(10)], "status": ["in": ["paid", "sent"]]]`). Up to 5 fields, 1 to 3 operators each, all AND.

### The primitives

| Method | Signature | Returns |
|---|---|---|
| `g.files.link(_:intent:)` | `func link(_ ref: String, intent: LinkIntent? = nil) async throws -> FileLink` | `FileLink` — **`url` is a `String`**; pass it through `URL(string:)` for `AsyncImage`. `intent` is `.inline` or `.download` |
| `g.credits.balance()` | `func balance() async throws -> Int` | **`Int`** — the balance itself, not a wrapper |
| `g.purchases.mine()` | `func mine() async throws -> [Purchase]` | `[Purchase]` — `item`, `kind`, `amountMinor: Int?`, `currency: String?`, `refundedMinor: Int`, `status`, `grants: [String]`, `paidAt`, `delivery: Purchase.Delivery?` (`.gemmeinFile(String)` / `.externalURL(String)`) |
| `g.subscriptions.mine()` | `func mine() async throws -> Subscription?` | `Subscription?` — `plan`, `status`; `nil` when they never paid |
| `g.subscriptions.checkout(plan:)` | `func checkout(plan: String? = nil) async throws -> CheckoutSession` | `CheckoutSession` — `url`, `plan`. Nothing redirects; open the url yourself |
| `g.payments.buy(_:item:)` | `func buy(_ product: String, item: String? = nil) async throws -> PaymentSession` | `PaymentSession` — `url`, `product`, `item` |
| `g.account.delete()` | `func delete() async throws -> JSONValue?` | `JSONValue?` — discardable |

### `g.ai`

| Method | Signature | Returns |
|---|---|---|
| `run(_:inputs:stream:)` | `func run(_ tool: String, inputs: [String: JSONValue] = [:], stream: Bool = false) async throws -> AiResponse` | `AiResponse` |
| `runText(_:inputs:)` | `func runText(_ tool: String, inputs: [String: JSONValue] = [:]) async throws -> String` | `String` — the label is **`inputs:`** |
| `calls(limit:before:)` | `func calls(limit: Int? = nil, before: String? = nil) async throws -> AiCallPage` | `AiCallPage` — `calls`, `nextCursor` |
| `chat(_:provider:tool:)` | `func chat(_ body: [String: JSONValue], provider: AiProvider? = nil, tool: String? = nil) async throws -> AiResponse` | `AiResponse` |
| `text(_:provider:tool:)` | `func text(_ body: [String: JSONValue], provider: AiProvider? = nil, tool: String? = nil) async throws -> String` | `String` |

`AiResponse` carries `status: Int`, `headers`, `ok: Bool`,
`creditsRemaining: Int?`, `refunded: Bool`, `tool: String?`, `isFake: Bool`,
`data() async throws -> Data`, and two streams: `lines()` and `events()`, both
`AsyncThrowingStream<String, Error>`.

### `GemmeinServer`

| Method | Signature | Returns |
|---|---|---|
| `GemmeinServer.init` | `init(secretKey: String, apiURL: URL = defaultAPIURL, session: URLSession = .shared) throws` | `GemmeinServer` |
| `collection(_:)` | `func collection(_ name: String) throws -> ServerCollectionClient` | `get(_:)`, `list(_:)`, `update(_:_:)` |
| `verifySession(_:)` | `func verifySession(_ token: String) async throws -> PersonHoldings` | `PersonHoldings` — `person`, `holdings` |
| `holdings(_:)` | `func holdings(_ personId: String) async throws -> PersonHoldings` | `PersonHoldings` |
| `grantAccess(_:entitlement:source:expiresAt:reason:)` | `@discardableResult func grantAccess(_ personId: String, entitlement: String, source: ManualGrantSource? = nil, expiresAt: String? = nil, reason: String? = nil) async throws -> GrantResult` | `GrantResult` — `grant`, `holdings` |
| `revokeAccess(_:_:reason:)` | `@discardableResult func revokeAccess(_ personId: String, grantId: String, reason: String? = nil) async throws -> GrantResult` | `GrantResult` |
| `invitePerson(_:)` | `func invitePerson(_ email: String) async throws -> InviteResult` | `InviteResult` — `person`, `created: Bool` |
| `spendCredits(_:amount:reason:key:)` | `@discardableResult func spendCredits(_ personId: String, amount: Int? = nil, reason: String, key: String? = nil) async throws -> SpendCreditsResult` | `SpendCreditsResult` — `spent`, `deduped`, `balanceBefore`, `balanceAfter`, `event` |
| `notify(_:subject:text:kind:key:)` | `func notify(_ personId: String, subject: String, text: String, kind: NotifyKind? = nil, key: String? = nil) async throws -> NotifyResult` | `NotifyResult` |
| `testSession(_:)` | `func testSession(_ email: String) async throws -> AuthSession` | `AuthSession` — development only |

`Holdings` is `access: [String]`, `grants: [Grant]`, `credits: Int?`.
`ManualGrantSource`: `.manual`, `.trial`, `.promotion`, `.migration`.

### The session store

`TokenStore` is a protocol: `func get() async -> String?`,
`func set(_ token: String) async throws`, `func clear() async`. Only `set`
throws. `KeychainTokenStore(appKey:)` is the default;
`MemoryTokenStore(token:)` is for tests and for the app that catches
`secure_store_unavailable`.

## The client policy

**The public key identifies the app; the session authorises the person;
verified domains are for browsers.** Ship the `pk_…` key in your app — that is
what it is for. `GemmeinServer` ships in this package for Swift that runs on a server. It takes a
secret key (`sk_…`), and a secret key never belongs in an app bundle — the `Gemmein`
client refuses one, and `GemmeinServer` itself refuses to start inside anything
its users install (`secret_key_in_client`): every iOS, tvOS, watchOS and
visionOS app, and on macOS an `.app`, an app extension (`.appex`), an XPC
service (`.xpc`) or a helper shipped inside an app bundle. A plain executable
on macOS or Linux — Vapor, Hummingbird, a command-line job, `swift run` — is a
server, and runs.

## Store purchases

`currentUser()` carries `storeAccountToken` — hand it to RevenueCat as the app
user id, so a purchase made in the App Store lands on the same person Gemmein
knows.

```swift
if let token = try await g.auth.currentUser().storeAccountToken {
    Purchases.configure(withAPIKey: revenueCatKey, appUserID: token)
}
```

## Refusals

Everything this package throws is a `GemmeinError`: the server's own `code`,
the server's own sentence (it always names the next action), plus `resetAt` on
a rate limit and `requires` on a `403 entitlement_required`. There are no
client-side rules the server already owns.

A few codes are the device's own, not the server's, and carry `status: 0` —
there was no HTTP answer to take a status from:

| code | what happened |
|---|---|
| `network_unreachable` | the request never reached Gemmein — no connection, no route, an `apiURL` pointing at nothing |
| `secure_store_unavailable` | the session could not be **stored**. `verifyEmailCode` throws this rather than returning a session the phone will lose; the OSStatus is in the message. On a simulator it is usually an unsigned build, which has no keychain access group — sign it, ad-hoc is enough. Reading the store stays lenient: unreadable means signed out, never a crash |
| `invalid_app_key` / `missing_app_key` | the key is a secret key, or is not a `pk_…` at all — refused before a request exists |

```swift
do {
    _ = try await g.collection("vault").list()
} catch let error as GemmeinError where error.code == "entitlement_required" {
    showUpgradeScreen(unlockedBy: error.requires)
}
```

## Tests

```
swift test                  # ring 1 — the wire, no engine
scripts/swift-contract.sh   # ring 3 — the same loop against a local engine
```
