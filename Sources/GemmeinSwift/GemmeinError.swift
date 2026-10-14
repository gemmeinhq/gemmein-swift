import Foundation

/// Every refusal, from anywhere in this package.
///
/// Thin by law: the SDK owns no rules the server already owns. `code` is the
/// server's own code, `message` is the server's own sentence (it always names
/// the next action), and nothing else from a refusal body is surfaced.
/// `status` is `0` for the handful of refusals the SDK itself raises before a
/// request exists (a missing key, a bad collection name) — the same convention
/// the JS SDK uses.
public struct GemmeinError: Error, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let message: String
    /// Present on 429 — when the limit resets; wait until then and retry.
    public let resetAt: String?
    /// Present on `429 export_rate_limited` from `account.export()` when the
    /// 30-day window refused it: the address the person can reach the app's
    /// owner at to ask for their data (the app's support inbox address). Nil
    /// when the app has none — show "contact the app's owner" then.
    public let ownerContact: String?
    /// Present on `403 entitlement_required` — the plan's or product's own key
    /// (`access:<slug>`). Show your upgrade screen and send the customer to
    /// checkout. A collection unlocked by several plans names ONE key here.
    public let requires: String?
    /// Present on `key_scope_mismatch` (`GemmeinServer(…, expects:)`): what
    /// the app expects that the key cannot do, one plain sentence each.
    public let missing: [String]?
    /// Present on `key_scope_mismatch`: what the key can do beyond what the
    /// app expects — a key too broad is refused like one too narrow.
    public let extra: [String]?
    /// The code's own page — `https://docs.gemmein.com/errors/<code>`. On
    /// refusals in Development and to secret keys; never on an answer to the
    /// Live app key. Copied as the server sent it; the SDK's own refusals
    /// (status 0) carry none.
    public let docs: String?

    public init(status: Int, code: String, message: String, resetAt: String? = nil, ownerContact: String? = nil, requires: String? = nil, missing: [String]? = nil, extra: [String]? = nil, docs: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.resetAt = resetAt
        self.ownerContact = ownerContact
        self.requires = requires
        self.missing = missing
        self.extra = extra
        self.docs = docs
    }
}

extension GemmeinError: LocalizedError {
    public var errorDescription: String? { message }
}

extension GemmeinError: CustomStringConvertible {
    public var description: String { "GemmeinError(\(status) \(code)): \(message)" }
}

/// One parser for every refusal body, so a 403 `entitlement_required` reads
/// the same on the collection path and on the runtime clients — the promise
/// the docs make on BOTH.
func readErrorBody(_ data: Data, status: Int) -> GemmeinError {
    guard let value = JSONCodec.decode(data), let body = value.object else {
        return GemmeinError(status: status, code: "request_failed", message: "Gemmein request failed: \(status)")
    }
    let code = body["code"]?.string ?? body["error"]?.string ?? "request_failed"
    return GemmeinError(
        status: status,
        code: code,
        message: body["message"]?.string ?? "Gemmein request failed: \(status)",
        // Copied only when the server sent it as a string — never invented
        // here, and nothing else from the body becomes SDK surface.
        resetAt: body["resetAt"]?.string,
        ownerContact: body["ownerContact"]?.string,
        requires: body["requires"]?.string,
        docs: body["docs"]?.string
    )
}
