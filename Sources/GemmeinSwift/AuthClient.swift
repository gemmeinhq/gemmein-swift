import Foundation

/// Sign-in, by email code. Two calls: send the code, verify the code.
public final class AuthClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Send the person an eight-digit code. Nothing is returned — the next
    /// step is `verifyEmailCode`.
    // route: POST /auth/email/start
    public func sendEmailCode(_ email: String) async throws {
        _ = try await runtimeRequest(
            config,
            "/auth/email/start",
            method: "POST",
            body: try JSONCodec.encode(["email": email]),
            extraHeaders: ["content-type": "application/json"]
        )
    }

    /// Exchange the code for a session. The session is stored (the Keychain by
    /// default), so every later call is authorised and a relaunch keeps them
    /// signed in.
    ///
    /// If the store refuses the write this throws
    /// `secure_store_unavailable` — W10 row 9c. The session exists on the
    /// server whatever the phone managed to keep, so an app that would rather
    /// run than stop can catch that one code and build a client with a
    /// `MemoryTokenStore` instead: sign-in works, and ends with the process.
    // route: POST /auth/email/verify
    public func verifyEmailCode(email: String, code: String) async throws -> AuthSession {
        let answer = try await runtimeRequest(
            config,
            "/auth/email/verify",
            method: "POST",
            body: try JSONCodec.encode(["email": email, "code": code]),
            extraHeaders: ["content-type": "application/json"]
        )
        guard let body = answer?.object, let token = body["token"]?.string else {
            throw GemmeinError(status: 0, code: "invalid_response", message: "Gemmein auth response did not include a session token")
        }
        try await config.tokenStore.set(token)
        let user = body["user"]?.object ?? [:]
        return AuthSession(
            token: token,
            expiresAt: body["expiresAt"]?.string ?? "",
            user: AuthUser(id: user["id"]?.string ?? "", email: user["email"]?.string ?? "", role: user["role"]?.string)
        )
    }

    /// Sign out. Even if the network call fails the stored session is cleared —
    /// the person asked to be signed out.
    // route: POST /auth/logout
    public func logout() async throws {
        do {
            _ = try await runtimeRequest(config, "/auth/logout", method: "POST")
            await endSession(config, .signedOut)
        } catch {
            await endSession(config, .signedOut)
            // W10 row 9: logout is IDEMPOTENT. The commonest way this
            // round-trip fails is `401 auth_expired` — the owner already
            // signed this person out everywhere from the console, which is
            // the remedy for a stolen phone. The session IS ended, so that
            // answer is the outcome asked for; throwing there made an app
            // that did everything right show an error for a success. Every
            // other failure still throws, and the token store is cleared
            // either way.
            if let gemmein = error as? GemmeinError, gemmein.status == 401, gemmein.code == "auth_expired" { return }
            throw error
        }
    }

    /// "Who is signed in right now?" — never throws for session state, so it
    /// is safe unguarded at launch. The stored token is deliberately NOT
    /// cleared on `authenticated == false`: that answer also covers a
    /// SUSPENDED person, whose session is intact and restored on unsuspend.
    // route: GET /auth/current-user
    public func currentUser() async throws -> CurrentUser {
        let answer = CurrentUser(json: try requireObject(try await runtimeRequest(config, "/auth/current-user"), "current-user"))
        // F34 (b): a session that ENDED (expired, or signed out elsewhere) is
        // gone for good — the token clears and onSignedOut fires. Suspension
        // carries no `ended`, so a suspended person's token is kept.
        if !answer.authenticated, let ended = answer.ended {
            await endSession(config, ended == "expired" ? .expired : .revoked)
        }
        return answer
    }

    /// F34 (b): hear when the person is signed out — however it happened:
    /// here, from another of their devices, by the owner, or the session
    /// expired. The token is already cleared when this fires, so route to
    /// your sign-in screen from here. Returns a closure that stops listening.
    // route: none
    @discardableResult
    public func onSignedOut(_ listener: @escaping @Sendable (SignedOutEvent) -> Void) -> @Sendable () -> Void {
        config.signedOut.add(listener)
    }

    /// F34: the person's signed-in devices, newest first. A sign-in ADDS a
    /// device (up to 10; the oldest is signed out when an 11th signs in).
    // route: GET /auth/devices
    public func devices() async throws -> [Device] {
        let body = try requireObject(try await runtimeRequest(config, "/auth/devices"), "devices")
        return (body["devices"]?.array ?? []).compactMap { $0.object }.map { Device(json: $0) }
    }

    /// F34: sign ONE device out, by the id from `devices()`. Signing out the
    /// current device signs this app out (the token clears, onSignedOut
    /// fires). An id that is not one of theirs is `device_not_found`.
    /// Signing out ANOTHER device needs a recent sign-in (10 minutes); past
    /// that the first call throws `confirm_required` and Gemmein emails a
    /// confirm code — call again with `code:`.
    // route: POST /auth/devices/sign-out
    public func signOutDevice(_ id: String, code: String? = nil) async throws {
        let current = (try? await devices())?.first(where: { $0.current })?.id
        var payload = ["id": id]
        if let code { payload["code"] = code }
        _ = try await runtimeRequest(
            config,
            "/auth/devices/sign-out",
            method: "POST",
            body: try JSONCodec.encode(payload),
            extraHeaders: ["content-type": "application/json"]
        )
        if current == id { await endSession(config, .signedOut) }
    }

    /// F34: "Sign out everywhere" — every device, this one included. The
    /// token clears and onSignedOut fires.
    // route: POST /auth/sign-out-everywhere
    public func signOutEverywhere() async throws {
        do {
            _ = try await runtimeRequest(config, "/auth/sign-out-everywhere", method: "POST")
            await endSession(config, .signedOut)
        } catch {
            await endSession(config, .signedOut)
            if let gemmein = error as? GemmeinError, gemmein.status == 401, gemmein.code == "auth_expired" || gemmein.code == "session_required" { return }
            throw error
        }
    }
}
