# Changelog — GemmeinSwift

All notable changes to the Swift SDK are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
semver.

`GemmeinSwift` tracks `@gemmein/sdk`'s major.minor: a feature that lands in
one lands in the other in the same release, the SDK parity law is a test
rather than a habit, and the release check refuses a build whose version does
not match the npm SDK's. Read the JS SDK's
[`CHANGELOG.md`](../sdk/CHANGELOG.md) for the engine behind each release.

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
