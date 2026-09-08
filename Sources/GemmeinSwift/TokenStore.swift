import Foundation
#if canImport(Security)
import Security
#endif

/// Where the person's session lives between launches.
///
/// The session token authorises the person. Hand it to the Keychain
/// (`KeychainTokenStore`, the default on Apple platforms) so a relaunch keeps
/// them signed in, or to `MemoryTokenStore` when you want the session to die
/// with the process.
///
/// **`set` throws; `get` and `clear` do not.** W10 row 9c, found by driving
/// the reference app on an unsigned simulator build: a store that cannot
/// PERSIST the session has broken the one promise it exists for — the person
/// signs in and is signed out again on the next launch — so it says so, in a
/// sentence, at the moment of the write. Reading is lenient in the other
/// direction: a store that cannot be READ means nobody is signed in, which is
/// a state every app already handles, and a crash at launch is worse than a
/// sign-in screen. Clearing is lenient for the same reason — the person asked
/// to be signed out, and a store with nothing readable in it is the outcome
/// they asked for.
public protocol TokenStore: AnyObject, Sendable {
    func get() async -> String?
    func set(_ token: String) async throws
    func clear() async
}

/// The session lives for this process only.
///
/// The lock is never taken from an `async` body. `NSLock.lock()` / `unlock()`
/// are `noasync` API — a suspension while the lock is held can resume on
/// another thread and unlock a lock this thread never took — so the whole
/// critical section lives in the two synchronous helpers below and the
/// protocol's async methods do nothing but call them.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) { self.token = token }

    public func get() async -> String? { read() }

    /// Never throws — memory is always writable. `TokenStore.set` is
    /// `throws` and a non-throwing method satisfies it, so a caller holding a
    /// `MemoryTokenStore` has a `try` that can never fire.
    public func set(_ token: String) async { write(token) }

    public func clear() async { write(nil) }

    // ── the critical section, synchronous by construction ────────────────

    private func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    private func write(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        token = value
    }
}

/// The default on Apple platforms: the session in the Keychain, so relaunching
/// the app keeps the person signed in.
///
/// `kSecClassGenericPassword`, service `com.gemmein.sdk`, and one account per
/// app key — derived exactly the way the browser SDK derives its storage key
/// (`gemmein_session_` + the key's first 20 characters), so two Gemmein apps
/// on one device never share a token. The item is
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: it needs the device
/// unlocked, and it never travels to a backup or another device.
///
/// Reads and clears are guarded — a Keychain that refuses (no entitlement in
/// a command-line host, a locked device) degrades to "signed out", never to a
/// crash. A WRITE the Keychain refuses throws `secure_store_unavailable`: see
/// the note on `set`.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    /// The Keychain service every Gemmein session is filed under.
    public static let service = "com.gemmein.sdk"

    /// This store's Keychain account. Public so a host app can see exactly
    /// which item it owns — it is a name, never the token.
    public let account: String

    public init(appKey: String) {
        self.account = KeychainTokenStore.accountName(forAppKey: appKey)
    }

    /// `gemmein_session_<first 20 characters of the app key>` — the browser
    /// SDK's derivation, character for character, so the two surfaces name the
    /// same app the same way.
    public static func accountName(forAppKey appKey: String) -> String {
        "gemmein_session_\(String(appKey.prefix(20)))"
    }

    public func get() async -> String? {
        #if canImport(Security)
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Store the session — or say why it could not be stored.
    ///
    /// W10 row 9c, found by driving the reference app.
    /// `CODE_SIGNING_ALLOWED = NO` builds an app with no entitlements, and an
    /// app with no `application-identifier` entitlement has no keychain
    /// access group: every `SecItemAdd` comes back `errSecMissingEntitlement`
    /// (-34018). This method used to discard that status, so the app signed
    /// in, stored nothing, and reported itself signed out one line later with
    /// nothing anywhere saying why. The OSStatus now travels out in the
    /// sentence, with the fix beside it.
    ///
    /// The session itself is real either way — it was minted server-side and
    /// `verifyEmailCode` never gets to return it — so an app that would
    /// rather run than stop can catch this and rebuild its client with a
    /// `MemoryTokenStore`: the person stays signed in until the process ends.
    public func set(_ token: String) async throws {
        #if canImport(Security)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainTokenStore.refusal(updated) }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainTokenStore.refusal(added) }
        #else
        throw GemmeinError(
            status: 0,
            code: "secure_store_unavailable",
            message: "The session could not be stored in the Keychain (this platform has no Security framework) "
                + "— pass a tokenStore of your own, or MemoryTokenStore to keep the session for this process only"
        )
        #endif
    }

    public func clear() async {
        #if canImport(Security)
        _ = SecItemDelete(baseQuery() as CFDictionary)
        #endif
    }

    #if canImport(Security)
    /// The one sentence a refused write reads as. The OSStatus is named as a
    /// number AND, where the system has words for it, in the system's own
    /// words: `SecCopyErrorMessageString` is the text Console.app prints, so
    /// searching for the sentence lands on the same page the number does.
    static func refusal(_ status: OSStatus) -> GemmeinError {
        let described = SecCopyErrorMessageString(status, nil) as String? ?? "no description"
        return GemmeinError(
            status: 0,
            code: "secure_store_unavailable",
            message: "The session could not be stored in the Keychain (OSStatus \(status): \(described)) "
                + "— on the simulator this is an unsigned build with no keychain access group; "
                + "sign the app (ad-hoc is enough)"
        )
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainTokenStore.service,
            kSecAttrAccount as String: account
        ]
    }
    #endif
}
