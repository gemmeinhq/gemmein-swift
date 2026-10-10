# Changelog — GemmeinSwift

All notable changes to the Swift SDK are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
semver.

`GemmeinSwift` tracks `@gemmein/sdk`'s major.minor: a feature that lands in
one lands in the other in the same release, the SDK parity law is a test
rather than a habit, and the release check refuses a build whose version does
not match the npm SDK's. Read the JS SDK's
[`CHANGELOG.md`](../sdk/CHANGELOG.md) for the engine behind each release.

## [Unreleased]

## [0.17.0] — 2026-10-10

Pinned to `@gemmein/sdk` 0.17.0 and engine 0.22.1.

- `AiCallRecord.prompt` is removed, as in the JS SDK: the request a tool
  sends is the owner's, and the back office keeps it. `answer` stays.
- `g.account.export()` — `AccountClient.export()`, the JS SDK's member data
  export: `GET /auth/export-account`, returning `AccountExport` (the headline
  fields plus the whole `document`; `jsonData()` gives the bytes to save). A
  second export within 30 days throws `GemmeinError` `export_rate_limited`
  (429), with `resetAt` and `ownerContact` (the app's support address, or nil).
  `AccountExport.about` is the document's cover: what it is, the app, when,
  which door, the sections, what is left out and why, and the person's rights.
- `upload(_:name:contentType:for:)` takes `for: [String]` — a group attachment
  on a direct collection that up to 20 named people can link, the JS
  `upload(file, { for: [ids] })`. The single-`String` form is unchanged.
- `g.runs` — `RunsClient`, the JS SDK's `g.runs` in Swift: `start(_:inputs:key:)`
  starts a run on an image, audio or video tool (202, credits reserved at the
  tool's ceiling), `get(_:)`, `list(since:limit:)` (a `String` or a `Date`),
  `cancel(_:)`, and `watch(_:intervalMs:onUpdate:)`, which polls from 2 s,
  backing off ×1.5 to 10 s, until the run ends. Cancelling the calling `Task`
  throws `GemmeinError` `aborted` (status 0), as an aborted `signal` does in
  JS.
- `Run`, `RunStatus`, `RunResult`, `RunResultFile` and `RunHandoff`, field for
  field with the JS `Run`. A status this build does not know arrives as
  `RunStatus.other(String)` and is treated as open.

## [0.16.0] — 2026-10-07

Pinned to `@gemmein/sdk` 0.16.0 and engine 0.22.0.

- `collection(name).open(id)` → `OpenFieldsClient` with `count(field, 1 | -1)`,
  `set(field, value)` and `flag(field, on)`, each returning the record.
- `GemmeinRecord.mine` (your own counts and flags), `flaggedBy` (on a
  secret-key read of one record, who set each flag) and `recipients`.
- `ListOptions(count: true)` fills `ListResult.total` (exact up to 10,000) or
  `totalAtLeast`; `ListOptions(author:)` takes `"me"` or a user id.
- `create(_:key:for:published:)` and the server client's
  `create(_:for:from:key:)` take a list of up to 20 recipients for one direct
  record.
- `upload()` takes audio up to 100 MB and video up to 500 MB per file (25 MB
  and 50 MB in Development); `ai.run()` takes an upload's ref as a file input
  for the kinds the tool ticks.

## [0.15.0] — 2026-10-04

Pinned to `@gemmein/sdk` 0.15.0 and engine 0.21.0.

- `Subscription` carries `trialEndsAt` and `endsAt` (ISO times, `nil` when
  not set); `status` is `"trialing"`, `"active"` or `"cancelled"`.
- `subscriptions.manage()` → `ManageLink { url }`: the app owner's Stripe
  customer portal for the signed-in subscriber — change plan, cancel, update
  the card. Open the url yourself. Throws 409 `portal_not_set_up` until the
  owner pastes the portal link on Payments.
- `payments.buy()` works signed out for a product; the buyer's purchase is
  theirs the first time they sign in with the email they gave Stripe
  Checkout. Plans need sign-in.
- `NotifyResult.notSent` (`"address_bounced"` / `"address_complained"`) and
  `NotifyResult.message`: set, with `sent == false`, when the engine did not
  mail an address that bounced for good or reported the app's mail as spam.
  Same fields as `@gemmein/sdk`'s `notify()` result.

## [0.14.0] — 2026-10-03

Pinned to `@gemmein/sdk` 0.14.0 and engine 0.20.0.

- `payments.products()` → `[CatalogProduct]` and `subscriptions.plans()` →
  `[CatalogPlan]` (with `CatalogPrice`): what the app sells, read without
  signing in. Keep each item's words and pictures in your app, keyed by `name`.

## [0.13.1] — 2026-10-03

Pinned to `@gemmein/sdk` 0.13.4 and engine 0.19.0.

Docs only. `CollectionClient`'s doc comment links the dashboard's Collections
guide (https://docs.gemmein.com/console/collections) instead of copying the
dashboard's click path, so a dashboard change never makes the package's docs
wrong. No API change.

## [0.13.0] — 2026-09-25

Pinned to `@gemmein/sdk` 0.13.0 and engine 0.14.0.

The owner and the app are separate, and secret keys write. `AiClient.upload(_:_:name:contentType:)` takes a customer's audio for a transcribe tool and returns a sealed reference for `run`. `GemmeinServer` collections gain `create(_:for:from:key:published:)` and `delete(_:)`, limited by the key's scopes, and `GemmeinServer` refuses to run on iOS, tvOS, watchOS and visionOS (`secret_key_in_client`). `GemmeinRecord.writtenBy` is `"server"` on a record a secret key created. Read the JS SDK's 0.13.0 entry for the engine behind each change.

## [0.12.0] — 2026-09-20

Pinned to `@gemmein/sdk` 0.12.0 and engine 0.13.0.

The release where a tool can run on the founder's own pipeline (`docs/DECISION-PIPELINE-PROVIDER.md`). Nothing in the Swift surface changes: `g.ai.run` behaves as before; a run on a pipeline tool is started and read through the same doors. The JS SDK's new `pipelines.handle` is a server-side helper for the pipeline's own host and is a named dormant surface here (the parity check knows it by name). Version travels with the JS SDK, as the law says.

## [0.11.0] — 2026-09-15

Pinned to `@gemmein/sdk` 0.11.0 and engine 0.12.0.

### Added

- `count(where:search:)` and `stats(_:where:search:)` on the collection
  client — how many records this person could list, and `{ count, sum, avg,
  min, max }` over the records whose field holds a number — by the parity law
  (the JS SDK's RUNTIME phase 5 surface).
- `where` takes, per field, a literal or an object of operators: `eq` / `ne`,
  `gt` / `gte` / `lt` / `lte`, `in` / `nin`, `contains` / `startsWith`,
  `exists` — up to 5 fields, 1..3 operators per field, all AND; the cloud
  answers `invalid_filter` (400) outside the grammar.

## [0.10.0] — 2026-09-08

First release. Born pinned to `@gemmein/sdk` 0.10.0 and engine 0.11.0.

### Added

- **The whole client surface, in Swift idiom** — `Gemmein(appKey:)` with
  `auth`, `collection(_:)`, files, subscriptions, one-off payments, credits
  and the AI route (`ai.chat`, `ai.run`, and their text and streaming forms),
  for iOS 17+ and macOS 14+. Foundation and Security only: no dependencies, so
  an app adds the package and ships.
- **The same method names as `@gemmein/sdk`, held there by a test.** A parity
  check reads the JS SDK's own method registry, holds every Swift client class
  to it, and resolves every method to a route the engine serves — a method
  that exists on one SDK and not the other fails the build, not a review.
- **`GemmeinServer`** — the compute gate on this rail too: `verifySession`,
  person holdings, grants and revokes, credits, invites and notify, behind a
  secret key that never belongs in an app bundle.
- **`KeychainTokenStore`** — the session in the iOS Keychain, asked for with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so it cannot survive a
  restore onto a device the person never had, keyed per app key.
  `MemoryTokenStore` is the alternative that never persists and never throws.
- **`storeAccountToken` on the current user** — the opaque per-person id for
  the app stores. Hand it to RevenueCat as the app user id (or to Apple as
  `appAccountToken`), and a store webhook resolves to exactly one person
  through a relay's `person_token`, without your app key or the person's email
  ever entering a third party's ledger.
- **`x-client-info: gemmein-swift/<version> ios`** on every request, so a
  build can be attributed in the key-usage ledger from day one.

### The three laws it was born with

- **A token store that cannot keep the session says so.** `TokenStore.set` is
  `throws`; `KeychainTokenStore.set` throws `GemmeinError`
  `secure_store_unavailable` carrying the OSStatus and
  `SecCopyErrorMessageString`'s words for it. Found by driving the reference
  app on an unsigned simulator build, where an app with no
  `application-identifier` entitlement has no keychain access group and every
  write is refused: the store used to swallow it, so the app signed in, stored
  nothing, and reported itself signed out one line later with nothing anywhere
  saying why. `get()` and `clear()` stay lenient — an unreadable store means
  signed out, which every app already handles.
- **A transport failure is typed.** A request that never reaches Gemmein — no
  network, no DNS, an `apiUrl` pointing at nothing — is a `GemmeinError`
  `network_unreachable` (status 0) carrying the underlying error, never a raw
  `URLError` the caller has to pattern-match.
- **`auth.logout()` is idempotent.** A `401 auth_expired` — the owner already
  signed this person out everywhere — returns rather than throwing, because
  the session being gone is the outcome logout asked for. Every other failure
  still throws, and the token store is cleared either way.
