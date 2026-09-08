import XCTest
@testable import GemmeinSwift

/// RING 1 — the wire, with no engine anywhere.
///
/// Every assertion here is held to the JS SDK's own request: the method, the
/// path, the query string and the body keys and values, read straight out of
/// `packages/sdk/src/index.ts`. A Swift client that speaks a different wire is
/// not the same SDK, whatever its method names say.
final class WireTests: XCTestCase {
    let apiURL = URL(string: "http://api.test")!
    let appKey = "pk_test_abcdefghijklmnop_extra"

    /// What every request from the app client must carry.
    var expectedClientInfo: String { "gemmein-swift/\(GemmeinSwift.version) \(GemmeinSwift.platform)" }

    func client(token: String? = nil) throws -> (Gemmein, MemoryTokenStore) {
        let store = MemoryTokenStore(token: token)
        let g = try Gemmein(appKey: appKey, apiURL: apiURL, tokenStore: store, session: StubURLProtocol.session())
        return (g, store)
    }

    func assertBaseHeaders(_ captured: StubURLProtocol.Captured, session: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(captured.headers["x-app-key"], appKey, "x-app-key identifies the app on every call", file: file, line: line)
        XCTAssertEqual(captured.headers["x-client-info"], expectedClientInfo, file: file, line: line)
        if let session {
            XCTAssertEqual(captured.headers["authorization"], "Bearer \(session)", file: file, line: line)
        } else {
            XCTAssertNil(captured.headers["authorization"], "no session, no authorization header", file: file, line: line)
        }
    }

    // ── auth ─────────────────────────────────────────────────────────────

    func testSendEmailCodeWritesTheSameRequestAsTheJSSDK() async throws {
        StubURLProtocol.queue([.init(status: 200, body: Data("{}".utf8))])
        let (g, _) = try client()
        try await g.auth.sendEmailCode("person@example.com")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].line, "POST /auth/email/start")
        XCTAssertEqual(sent[0].headers["content-type"], "application/json")
        assertBaseHeaders(sent[0], session: nil)
        XCTAssertEqual(sent[0].json as NSDictionary?, ["email": "person@example.com"] as NSDictionary)
    }

    func testVerifyEmailCodeStoresTheSessionAndEveryLaterCallCarriesIt() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"token":"gm_sess_1","expiresAt":"2026-10-01T00:00:00.000Z","user":{"id":"usr_1","email":"person@example.com"}}"#.utf8)),
            .init(body: Data(#"{"authenticated":true,"userId":"usr_1","email":"person@example.com","storeAccountToken":"sat_1"}"#.utf8))
        ])
        let (g, store) = try client()
        let session = try await g.auth.verifyEmailCode(email: "person@example.com", code: "123456")
        XCTAssertEqual(session.token, "gm_sess_1")
        XCTAssertEqual(session.user.id, "usr_1")
        let stored = await store.get()
        XCTAssertEqual(stored, "gm_sess_1", "the session is stored — that is what keeps a relaunch signed in")

        let me = try await g.auth.currentUser()
        XCTAssertTrue(me.authenticated)
        XCTAssertEqual(me.storeAccountToken, "sat_1", "the store account token is passed through, never synthesised")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "POST /auth/email/verify")
        XCTAssertEqual(sent[0].json as NSDictionary?, ["email": "person@example.com", "code": "123456"] as NSDictionary)
        XCTAssertEqual(sent[1].line, "GET /auth/current-user")
        assertBaseHeaders(sent[1], session: "gm_sess_1")
    }

    func testCurrentUserNeverThrowsForSessionStateAndNeverClearsTheToken() async throws {
        StubURLProtocol.queue([.init(body: Data(#"{"authenticated":false}"#.utf8))])
        let (g, store) = try client(token: "gm_sess_suspended")
        let me = try await g.auth.currentUser()
        XCTAssertFalse(me.authenticated)
        let stored = await store.get()
        XCTAssertEqual(stored, "gm_sess_suspended", "a suspended person's session survives — clearing it would make a reversible suspension permanent")
    }

    /// W10 row 9 — logout is IDEMPOTENT. `401 auth_expired` means the owner
    /// already signed this person out everywhere from the console: the
    /// session IS gone, which is the outcome logout asked for.
    func testLogoutSwallowsASessionThatWasAlreadyEnded() async throws {
        StubURLProtocol.queue([.init(status: 401, body: Data(#"{"code":"auth_expired","message":"this session has ended"}"#.utf8))])
        let (g, store) = try client(token: "gm_sess_1")
        try await g.auth.logout() // must not throw
        let stored = await store.get()
        XCTAssertNil(stored, "the token store is cleared either way")
    }

    func testLogoutClearsTheSessionEvenWhenTheCallFails() async throws {
        StubURLProtocol.queue([.init(status: 500, body: Data(#"{"code":"server_error","message":"nope"}"#.utf8))])
        let (g, store) = try client(token: "gm_sess_1")
        do {
            try await g.auth.logout()
            XCTFail("a 500 must reach the caller")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "server_error")
        }
        let stored = await store.get()
        XCTAssertNil(stored, "the person asked to be signed out")
    }

    // ── the transport, typed (W10 row 9) ─────────────────────────────────

    /// A refused connection never reaches `handleResponse`, so `URLSession`'s
    /// own `URLError` used to come out of the SDK unchanged. It is a
    /// `GemmeinError` now — the JS SDK's code and sentence, character for
    /// character.
    func testARefusedConnectionIsAGemmeinErrorNetworkUnreachable() async throws {
        StubURLProtocol.queue([.init(failure: URLError(.cannotConnectToHost))])
        let (g, _) = try client(token: "gm_sess_1")
        do {
            _ = try await g.collection("notes").list()
            XCTFail("nothing answered — this must not resolve")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "network_unreachable")
            XCTAssertEqual(error.status, 0, "the SDK's convention for 'no HTTP status applies'")
            XCTAssertEqual(error.message, "Gemmein could not be reached — check the connection and the apiUrl (api.test)")
        }
    }

    /// The streaming door reads bytes, not data — a second call site, wrapped
    /// the same way.
    func testAStreamingCallGetsTheSameTypedTransportFailure() async throws {
        StubURLProtocol.queue([.init(failure: URLError(.notConnectedToInternet))])
        let (g, _) = try client(token: "gm_sess_1")
        do {
            _ = try await g.ai.run("summarise", inputs: ["text": "x"], stream: true)
            XCTFail("nothing answered — this must not resolve")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "network_unreachable")
            XCTAssertEqual(error.status, 0)
        }
    }

    /// A cancel is the caller's own doing, so it stays what it was — the same
    /// law the JS SDK keeps for an `AbortError`.
    func testACancelIsNotDressedUpAsATransportFailure() {
        let cancelled = asTransportFailure(apiURL, URLError(.cancelled))
        XCTAssertNil(cancelled as? GemmeinError, "a cancel is not a Gemmein refusal")
        XCTAssertEqual((cancelled as? URLError)?.code, .cancelled)
        XCTAssertTrue(asTransportFailure(apiURL, CancellationError()) is CancellationError)
        let refusal = GemmeinError(status: 403, code: "denied", message: "no")
        XCTAssertEqual(asTransportFailure(apiURL, refusal) as? GemmeinError, refusal, "an already-typed refusal is not re-typed")
    }

    // ── collections ──────────────────────────────────────────────────────

    func testCreateCarriesKeyForAndPublishedAsQueryAndTheDataAsTheBody() async throws {
        StubURLProtocol.queue([.init(body: Data(#"{"id":"rec_1","data":{"title":"Ran"},"version":1,"published":false}"#.utf8))])
        let (g, _) = try client(token: "gm_sess_1")
        let record = try await g.collection("notes", intent: "one note per person")
            .create(["title": "Ran", "done": false, "seats": 4], key: "slot:2026-07-15", for: "usr_2", published: false)

        XCTAssertEqual(record.id, "rec_1")
        XCTAssertEqual(record.data["title"]?.string, "Ran")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "POST /storage/notes?key=slot%3A2026-07-15&for=usr_2&published=false")
        XCTAssertEqual(sent[0].headers["x-collection-intent"], "one note per person")
        XCTAssertEqual(sent[0].headers["content-type"], "application/json")
        assertBaseHeaders(sent[0], session: "gm_sess_1")
        XCTAssertEqual(sent[0].json as NSDictionary?, ["title": "Ran", "done": false, "seats": 4] as NSDictionary)
    }

    func testListWritesEveryOptionTheJSSDKWrites() async throws {
        StubURLProtocol.queue([.init(body: Data(#"{"records":[],"hasMore":false}"#.utf8))])
        let (g, _) = try client(token: "gm_sess_1")
        _ = try await g.collection("notes").list(ListOptions(
            limit: 25,
            sort: .updated,
            where: ["done": false],
            cursor: "cur_1",
            search: "hello world",
            expand: ["authorId", "albumId"],
            since: "2026-09-01T00:00:00.000Z"
        ))

        XCTAssertEqual(
            StubURLProtocol.captured[0].line,
            "GET /storage/notes?limit=25&sort=updated&where=%7B%22done%22%3Afalse%7D&cursor=cur_1&search=hello+world&expand=authorId%2CalbumId&since=2026-09-01T00%3A00%3A00.000Z"
        )
    }

    func testGetUpdateAndDelete() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"id":"rec_1","data":{},"version":3,"expand":{"authorId":null}}"#.utf8)),
            .init(body: Data(#"{"id":"rec_1","data":{"stock":4},"version":4}"#.utf8)),
            .init(status: 204, headers: [:], body: Data())
        ])
        let (g, _) = try client(token: "gm_sess_1")
        let notes = try g.collection("notes")

        let read = try await notes.get("rec 1", expand: ["authorId"])
        XCTAssertEqual(read.version, 3)
        XCTAssertTrue(read.expand.keys.contains("authorId"))

        _ = try await notes.update("rec_1", ["stock": ["decrement": 1, "floor": 0]], ifVersion: 3)
        try await notes.delete("rec_1")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "GET /storage/notes/rec%201?expand=authorId")
        XCTAssertEqual(sent[1].line, "PATCH /storage/notes/rec_1?ifVersion=3")
        XCTAssertEqual(
            sent[1].json as NSDictionary?,
            ["stock": ["decrement": 1, "floor": 0]] as NSDictionary,
            "an atomic op travels in value position — the server does the math on current state"
        )
        XCTAssertEqual(sent[2].line, "DELETE /storage/notes/rec_1")
    }

    func testAnInvalidCollectionNameIsRefusedBeforeARequestExists() async throws {
        StubURLProtocol.queue([])
        let (g, _) = try client()
        XCTAssertThrowsError(try g.collection("Notes")) { error in
            guard let error = error as? GemmeinError else { return XCTFail("not a GemmeinError") }
            XCTAssertEqual(error.code, "invalid_collection_name")
            XCTAssertEqual(error.status, 0, "status 0 is the SDK's own convention for \"no HTTP status applies\"")
        }
        XCTAssertEqual(StubURLProtocol.captured.count, 0)
    }

    func testUploadIsPresignThenStoreThenConfirm() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"fileId":"file_1","uploadUrl":"http://api.test/dev-upload?key=k","fields":{"Content-Type":"image/png"}}"#.utf8)),
            .init(status: 204, headers: [:], body: Data()),
            .init(body: Data(#"{"id":"file_1","ref":"file:01K","contentType":"image/png","sizeBytes":4}"#.utf8))
        ])
        let (g, _) = try client(token: "gm_sess_1")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let uploaded = try await g.collection("films").upload(bytes, name: "poster.png", contentType: "image/png", for: "usr_2")
        XCTAssertEqual(uploaded.ref, "file:01K")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "POST /storage/films/upload")
        XCTAssertEqual(
            sent[0].json as NSDictionary?,
            ["name": "poster.png", "size": 4, "contentType": "image/png", "for": "usr_2"] as NSDictionary,
            "the presign declares what it is about to send — a presign that declares nothing is refused"
        )
        XCTAssertEqual(sent[1].line, "POST /dev-upload?key=k")
        XCTAssertTrue(sent[1].headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let form = String(decoding: sent[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("name=\"Content-Type\""), "the presign's own fields ride the form")
        XCTAssertTrue(form.range(of: "name=\"file\"")!.lowerBound > form.range(of: "name=\"Content-Type\"")!.lowerBound,
                      "the file part must be LAST — the object store's own requirement")
        XCTAssertEqual(sent[2].line, "POST /storage/films/upload/file_1/confirm")
    }

    // ── the other primitives ─────────────────────────────────────────────

    func testFilesLinkSubscriptionsPaymentsCreditsAndPurchases() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"ref":"file:01K","url":"http://cdn.test/x","contentType":"application/pdf","expiresAt":"2026-09-07T12:00:00.000Z"}"#.utf8)),
            .init(body: Data(#"{"subscription":{"plan":"pro","status":"active"}}"#.utf8)),
            .init(body: Data(#"{"url":"https://checkout.stripe.test/c/1","plan":"pro"}"#.utf8)),
            .init(body: Data(#"{"url":"https://checkout.stripe.test/p/1","product":"premium license","item":"beat_37"}"#.utf8)),
            .init(body: Data(#"{"balance":42}"#.utf8)),
            .init(body: Data(#"{"purchases":[{"item":"poster","kind":"purchase","amountMinor":1200,"currency":"gbp","refundedMinor":0,"status":"paid","grants":["access:pro"],"paidAt":"2026-09-01T00:00:00.000Z","delivery":{"type":"gemmein_file","file":"file:01K"}}]}"#.utf8))
        ])
        let (g, _) = try client(token: "gm_sess_1")

        let link = try await g.files.link("file:01K", intent: .download)
        XCTAssertEqual(link.url, "http://cdn.test/x")
        XCTAssertEqual(link.expiresAt, "2026-09-07T12:00:00.000Z")

        let subscription = try await g.subscriptions.mine()
        XCTAssertEqual(subscription?.plan, "pro")

        let checkout = try await g.subscriptions.checkout(plan: "pro")
        XCTAssertEqual(checkout.url, "https://checkout.stripe.test/c/1", "checkout RETURNS the URL — opening it is the app's decision")

        let payment = try await g.payments.buy("premium license", item: "beat_37")
        XCTAssertEqual(payment.item, "beat_37")

        let balance = try await g.credits.balance()
        XCTAssertEqual(balance, 42)

        let purchases = try await g.purchases.mine()
        XCTAssertEqual(purchases.count, 1)
        XCTAssertEqual(purchases[0].amountMinor, 1200, "minor units, exactly as the provider reported them")
        XCTAssertEqual(purchases[0].delivery, .gemmeinFile("file:01K"))

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "GET /files/file%3A01K/link?intent=download")
        XCTAssertEqual(sent[1].line, "GET /auth/subscription")
        XCTAssertEqual(sent[2].line, "GET /auth/checkout?plan=pro")
        XCTAssertEqual(sent[3].line, "GET /auth/pay?product=premium+license&item=beat_37")
        XCTAssertEqual(sent[4].line, "GET /auth/credits")
        XCTAssertEqual(sent[5].line, "GET /auth/purchases")
        XCTAssertEqual(sent.count, 6, "one call each — nothing opens a browser, nothing polls")
    }

    func testAccountDeleteClearsTheSession() async throws {
        StubURLProtocol.queue([.init(body: Data(#"{"deleted":true}"#.utf8))])
        let (g, store) = try client(token: "gm_sess_1")
        _ = try await g.account.delete()
        let stored = await store.get()
        XCTAssertNil(stored)
        XCTAssertEqual(StubURLProtocol.captured[0].line, "POST /auth/delete-account")
    }

    // ── the AI route ─────────────────────────────────────────────────────

    func testChatSendsTheProvidersOwnBodyWithTheProviderAndToolTheJSSDKSends() async throws {
        StubURLProtocol.queue([.init(
            headers: ["content-type": "application/json", "x-gemmein-credits-remaining": "41", "x-gemmein-tool": "summarise"],
            body: Data(#"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#.utf8)
        )])
        let (g, _) = try client(token: "gm_sess_1")
        let answer = try await g.ai.chat(
            ["model": "gpt-4o-mini", "messages": [["role": "user", "content": "hi"]]],
            provider: .openai,
            tool: "summarise"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(answer.creditsRemaining, 41)
        XCTAssertEqual(answer.tool, "summarise")

        let sent = StubURLProtocol.captured[0]
        XCTAssertEqual(sent.line, "POST /ai/chat?tool=summarise")
        assertBaseHeaders(sent, session: "gm_sess_1")
        XCTAssertEqual(
            sent.json as NSDictionary?,
            ["provider": "openai", "model": "gpt-4o-mini", "messages": [["role": "user", "content": "hi"]]] as NSDictionary,
            "the provider rides the body; the rest is the provider's own request, untouched"
        )
    }

    func testRunSendsInputsAndStreamAndRunTextLiftsTheAnswer() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"choices":[{"message":{"content":"a fox outran a dog"}}]}"#.utf8))
        ])
        let (g, _) = try client(token: "gm_sess_1")
        let text = try await g.ai.runText("summarise", inputs: ["text": "the quick brown fox"])
        XCTAssertEqual(text, "a fox outran a dog")

        let sent = StubURLProtocol.captured[0]
        XCTAssertEqual(sent.line, "POST /ai/run/summarise")
        XCTAssertEqual(sent.json as NSDictionary?, ["inputs": ["text": "the quick brown fox"]] as NSDictionary)
    }

    func testRunWithStreamAddsStreamTrueAndCallsPagesWithLimitAndBefore() async throws {
        StubURLProtocol.queue([
            .init(body: Data("{}".utf8)),
            .init(body: Data(#"{"calls":[{"id":"aic_1","tool":"summarise","credits":3,"outcome":"ok"}],"nextCursor":"aic_0"}"#.utf8))
        ])
        let (g, _) = try client(token: "gm_sess_1")
        _ = try await g.ai.run("summarise", inputs: ["text": "x"], stream: true)
        let page = try await g.ai.calls(limit: 20, before: "aic_9")
        XCTAssertEqual(page.calls.first?.credits, 3)
        XCTAssertEqual(page.nextCursor, "aic_0")

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].json as NSDictionary?, ["inputs": ["text": "x"], "stream": true] as NSDictionary)
        XCTAssertEqual(sent[1].line, "GET /auth/ai-calls?limit=20&before=aic_9")
    }

    func testAStreamingAnswerArrivesAsTheChunksTheEngineWrote() async throws {
        let frames = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n",
            "data: [DONE]\n\n"
        ]
        StubURLProtocol.queue([.init(
            headers: ["content-type": "text/event-stream", "x-gemmein-credits-remaining": "40"],
            body: Data(),
            chunks: frames.map { Data($0.utf8) }
        )])
        let (g, _) = try client(token: "gm_sess_1")
        let answer = try await g.ai.run("summarise", inputs: ["text": "x"], stream: true)

        var assembled = ""
        for try await event in answer.events() {
            let json = try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            assembled += (delta?["content"] as? String) ?? ""
        }
        XCTAssertEqual(assembled, "Hello", "the chunks arrive in order and assemble to the answer; [DONE] is not one of them")
    }

    func testAProviderAnswerPastTheSpendComesBackUntouchedButAGemmeinRefusalThrows() async throws {
        // Past the spend: the engine stamped the balance, so this 400 is the
        // PROVIDER's own answer and must reach the caller as an answer.
        StubURLProtocol.queue([.init(
            status: 400,
            headers: ["content-type": "application/json", "x-gemmein-credits-remaining": "39"],
            body: Data(#"{"error":{"message":"model is overloaded"}}"#.utf8)
        )])
        let (g, _) = try client(token: "gm_sess_1")
        let answer = try await g.ai.chat(["model": "gpt-4o-mini"])
        XCTAssertFalse(answer.ok)
        XCTAssertEqual(answer.status, 400)

        // Before the spend: Gemmein's own refusal, typed.
        StubURLProtocol.queue([.init(
            status: 402,
            body: Data(#"{"code":"credits_exhausted","message":"this person has 0 credits — this call needs 3"}"#.utf8)
        )])
        do {
            _ = try await g.ai.chat(["model": "gpt-4o-mini"])
            XCTFail("a refusal before the spend must throw")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.status, 402)
            XCTAssertEqual(error.code, "credits_exhausted")
        }
    }

    // ── refusals ─────────────────────────────────────────────────────────

    func testARefusalBecomesTheServersCodeMessageAndNothingElse() async throws {
        StubURLProtocol.queue([.init(
            status: 403,
            body: Data(#"{"code":"entitlement_required","message":"this collection is unlocked by pro","action":"send them to checkout","requires":"access:pro","requiresAny":["access:pro","access:studio"]}"#.utf8)
        )])
        let (g, _) = try client(token: "gm_sess_1")
        do {
            _ = try await g.collection("vault").list()
            XCTFail("a 403 must throw")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.code, "entitlement_required")
            XCTAssertEqual(error.message, "this collection is unlocked by pro", "the server's sentence — it always names the next action")
            XCTAssertEqual(error.requires, "access:pro")
            XCTAssertNil(error.resetAt)
        }
    }

    func testARateLimitCarriesResetAtAndANonStringRequiresIsDropped() async throws {
        StubURLProtocol.queue([.init(
            status: 429,
            body: Data(#"{"code":"ai_capped","message":"20 calls a minute","resetAt":"2026-09-07T12:00:00.000Z","requires":["access:pro"]}"#.utf8)
        )])
        let (g, _) = try client(token: "gm_sess_1")
        do {
            _ = try await g.credits.balance()
            XCTFail("a 429 must throw")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "ai_capped")
            XCTAssertEqual(error.resetAt, "2026-09-07T12:00:00.000Z")
            XCTAssertNil(error.requires, "requires is never half-trusted — a non-string is dropped, not coerced")
        }
    }

    func testAnExpiredSessionIsTheOneRefusalThatClearsTheStoredToken() async throws {
        StubURLProtocol.queue([.init(status: 401, body: Data(#"{"code":"auth_expired","message":"sign in again"}"#.utf8))])
        let (g, store) = try client(token: "gm_sess_old")
        _ = try? await g.collection("notes").list()
        let stored = await store.get()
        XCTAssertNil(stored)
    }

    func testAWrongKeyRoutesTheBuilderToWhereAWorkingKeyComesFrom() async throws {
        StubURLProtocol.queue([.init(status: 401, body: Data(#"{"code":"invalid_app_key","message":"unknown app key"}"#.utf8))])
        let (g, _) = try client()
        do {
            _ = try await g.credits.balance()
            XCTFail("a 401 must throw")
        } catch let error as GemmeinError {
            XCTAssertTrue(error.message.contains("app.gemmein.com"), "the signpost, not a dead end")
        }
    }

    func testASecretKeyIsRefusedInTheAppClientAndAMissingOneIsASignpost() {
        XCTAssertThrowsError(try Gemmein(appKey: "sk_test_1", apiURL: apiURL, tokenStore: MemoryTokenStore(), session: StubURLProtocol.session())) { error in
            XCTAssertEqual((error as? GemmeinError)?.code, "invalid_app_key")
        }
        XCTAssertThrowsError(try Gemmein(appKey: "", apiURL: apiURL, tokenStore: MemoryTokenStore(), session: StubURLProtocol.session())) { error in
            XCTAssertEqual((error as? GemmeinError)?.code, "missing_app_key")
        }
    }

    // ── the gate (secret key) ────────────────────────────────────────────

    func testTheGateSendsTheSecretKeyAndItsOwnClientInfo() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"ok":true,"person":{"id":"usr_1","email":"a@b.test","role":"member"},"holdings":{"access":["access:pro"],"grants":[{"id":"gr_1","entitlement":"access:pro","source":"trial","startsAt":"2026-09-01T00:00:00.000Z","expiresAt":null}],"credits":{"balance":7}}}"#.utf8)),
            .init(body: Data(#"{"ok":true,"spent":5,"deduped":false,"balance":{"before":20,"after":15},"event":{"id":"cev_1","reason":"render:4k","actor":"jobs key"}}"#.utf8))
        ])
        let server = try GemmeinServer(secretKey: "sk_test_1", apiURL: apiURL, session: StubURLProtocol.session())

        let verified = try await server.verifySession("gm_sess_1")
        XCTAssertEqual(verified.person.id, "usr_1")
        XCTAssertEqual(verified.holdings.access, ["access:pro"])
        XCTAssertEqual(verified.holdings.credits, 7)

        let spend = try await server.spendCredits("usr_1", amount: 5, reason: "render:4k", key: "render:job_1")
        XCTAssertEqual(spend.spent, 5)
        XCTAssertEqual(spend.balanceAfter, 15)

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "POST /server/verify-session")
        XCTAssertEqual(sent[0].headers["x-app-key"], "sk_test_1")
        XCTAssertEqual(sent[0].headers["x-client-info"], "gemmein-swift/\(GemmeinSwift.version)",
                       "the gate reports the build, without a device platform — it does not run on one")
        XCTAssertEqual(sent[0].json as NSDictionary?, ["token": "gm_sess_1"] as NSDictionary)
        XCTAssertEqual(sent[1].line, "POST /server/people/usr_1/credits/spend")
        XCTAssertEqual(sent[1].json as NSDictionary?, ["amount": 5, "reason": "render:4k", "key": "render:job_1"] as NSDictionary)
    }

    func testTestSessionIsRefusedOnALiveKeyBeforeARequestExists() async throws {
        StubURLProtocol.queue([])
        let server = try GemmeinServer(secretKey: "sk_live_1", apiURL: apiURL, session: StubURLProtocol.session())
        do {
            _ = try await server.testSession("a@b.test")
            XCTFail("a live key must be refused here")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "test_session_forbidden_live")
        }
        XCTAssertEqual(StubURLProtocol.captured.count, 0, "nothing is dialled")
    }

    func testTheServerCollectionAndGrantDoors() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"records":[],"hasMore":false}"#.utf8)),
            .init(body: Data(#"{"ok":true,"grant":{"id":"gr_1","entitlement":"access:pro","source":"trial","startsAt":"2026-09-01T00:00:00.000Z","expiresAt":null},"holdings":{"access":["access:pro"],"grants":[],"credits":null}}"#.utf8)),
            .init(body: Data(#"{"person":{"id":"usr_9","email":"client@example.com","role":"member","invited":true,"suspended":false},"created":true}"#.utf8))
        ])
        let server = try GemmeinServer(secretKey: "sk_test_1", apiURL: apiURL, session: StubURLProtocol.session())
        _ = try await server.collection("orders").list(ListOptions(limit: 5))
        _ = try await server.grantAccess("usr_1", entitlement: "access:pro", source: .trial, expiresAt: "2026-10-01T00:00:00.000Z", reason: "7-day trial")
        let invited = try await server.invitePerson("client@example.com")
        XCTAssertEqual(invited.person.invited, true)
        XCTAssertTrue(invited.created)

        let sent = StubURLProtocol.captured
        XCTAssertEqual(sent[0].line, "GET /storage/orders?limit=5")
        XCTAssertEqual(sent[1].line, "POST /server/people/usr_1/grants")
        XCTAssertEqual(
            sent[1].json as NSDictionary?,
            ["entitlement": "access:pro", "source": "trial", "expiresAt": "2026-10-01T00:00:00.000Z", "reason": "7-day trial"] as NSDictionary
        )
        XCTAssertEqual(sent[2].line, "POST /server/people")
        XCTAssertEqual(sent[2].json as NSDictionary?, ["email": "client@example.com"] as NSDictionary)
    }

    /// W10 review row 14a — THE GATE'S OWN TRANSPORT. `GemmeinServer` ran
    /// `session.data(for:)` bare, so a refused connection came out of it as a
    /// raw `URLError`: the one corner of the package where
    /// `error as? GemmeinError` was nil, and the same gap row 9 closed on the
    /// client rail. Both rails, one seam, same commit — the parity law.
    func testAGemmeinServerCallOnARefusedConnectionIsNetworkUnreachable() async throws {
        StubURLProtocol.queue([.init(failure: URLError(.cannotConnectToHost))])
        let server = try GemmeinServer(secretKey: "sk_test_1", apiURL: apiURL, session: StubURLProtocol.session())
        do {
            _ = try await server.verifySession("gm_sess_1")
            XCTFail("nothing answered — this must not resolve")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "network_unreachable")
            XCTAssertEqual(error.status, 0, "the SDK's convention for 'no HTTP status applies'")
            XCTAssertEqual(error.message, "Gemmein could not be reached — check the connection and the apiUrl (api.test)",
                           "the JS SDK's sentence, character for character")
        }
    }

    /// A secret-key collection reads through its own request path, so it is a
    /// second call site and gets its own assertion.
    func testAServerCollectionOnARefusedConnectionIsNetworkUnreachable() async throws {
        StubURLProtocol.queue([.init(failure: URLError(.notConnectedToInternet))])
        let server = try GemmeinServer(secretKey: "sk_test_1", apiURL: apiURL, session: StubURLProtocol.session())
        do {
            _ = try await server.collection("orders").list()
            XCTFail("nothing answered — this must not resolve")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "network_unreachable")
            XCTAssertEqual(error.status, 0)
        }
    }

    // ── the constants the law pins ───────────────────────────────────────

    func testTheKeychainAccountIsDerivedTheWayTheBrowserSDKDerivesItsKey() {
        // BrowserTokenStore: `gemmein_session_${appKey.slice(0, 20)}`.
        XCTAssertEqual(KeychainTokenStore.accountName(forAppKey: appKey), "gemmein_session_pk_test_abcdefghijkl")
        XCTAssertEqual(KeychainTokenStore.accountName(forAppKey: appKey).count, "gemmein_session_".count + 20)
        XCTAssertEqual(KeychainTokenStore(appKey: appKey).account, KeychainTokenStore.accountName(forAppKey: appKey))
        XCTAssertEqual(KeychainTokenStore.service, "com.gemmein.sdk")
    }

    // ── W10 row 9c: a store that cannot persist says so ──────────────────

    /// The session was minted server-side; the phone could not keep it. The
    /// app used to be told nothing at all — it signed in and reported itself
    /// signed out one line later.
    func testAStoreThatCannotPersistTheSessionSurfacesSecureStoreUnavailable() async throws {
        StubURLProtocol.queue([
            .init(body: Data(#"{"token":"gm_sess_1","expiresAt":"2026-10-01T00:00:00.000Z","user":{"id":"usr_1","email":"person@example.com"}}"#.utf8))
        ])
        let store = RefusingTokenStore()
        let g = try Gemmein(appKey: appKey, apiURL: apiURL, tokenStore: store, session: StubURLProtocol.session())
        do {
            _ = try await g.auth.verifyEmailCode(email: "person@example.com", code: "123456")
            XCTFail("a store that cannot keep the session must not report a signed-in app")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "secure_store_unavailable")
            XCTAssertEqual(error.status, 0, "no HTTP status applies — the request succeeded")
        }
        XCTAssertEqual(StubURLProtocol.captured.count, 1, "the verify round-trip happened; only the write failed")
    }

    /// `MemoryTokenStore` is the documented way out, and it never throws —
    /// the non-throwing method satisfies the `throws` requirement.
    func testMemoryTokenStoreSatisfiesTheThrowingRequirementWithoutEverThrowing() async throws {
        let store: TokenStore = MemoryTokenStore()
        try await store.set("gm_sess_1")
        let stored = await store.get()
        XCTAssertEqual(stored, "gm_sess_1")
    }

    /// The real Keychain, on the host running `swift test` — a signed
    /// command-line host has an access group, so this round-trips for real:
    /// write, read back, clear, gone. A host without one refuses the WRITE
    /// with a sentence naming the OSStatus, which is the row itself; that is
    /// a SKIP, never a silent pass — the round trip is the assertion here.
    func testTheKeychainStoresTheSessionAndReadsItBack() async throws {
        let store = KeychainTokenStore(appKey: "pk_test_wiretests_row9c")
        await store.clear()
        do {
            try await store.set("gm_sess_keychain")
        } catch let error as GemmeinError {
            XCTAssertEqual(error.code, "secure_store_unavailable")
            XCTAssertEqual(error.status, 0)
            XCTAssertTrue(error.message.contains("OSStatus"), "the refusal names the status — \(error.message)")
            throw XCTSkip("this host's Keychain refuses the write: \(error.message)")
        }
        let stored = await store.get()
        XCTAssertEqual(stored, "gm_sess_keychain", "a Keychain that accepted the write reads it back")
        await store.clear()
        let cleared = await store.get()
        XCTAssertNil(cleared, "clear removes the item")
    }

    func testTheVersionTracksTheNpmSDKsMajorMinor() throws {
        // packages/swift/Tests/GemmeinSwiftTests/WireTests.swift → packages/sdk
        let here = URL(fileURLWithPath: #filePath)
        let packageJSON = here
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sdk/package.json")
        guard let data = try? Data(contentsOf: packageJSON) else {
            throw XCTSkip("packages/sdk/package.json is not beside this checkout — the release check pins it there")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let npm = (json?["version"] as? String) ?? ""
        func majorMinor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }
        XCTAssertEqual(majorMinor(GemmeinSwift.version), majorMinor(npm), "the SDKs travel together — the versions cannot drift")
    }

    func testTheClientInfoTagIsCleanedAndCappedTheWayTheLedgerReadsIt() {
        XCTAssertEqual(GemmeinSwift.clientInfo(platform: nil), "gemmein-swift/\(GemmeinSwift.version)")
        XCTAssertEqual(GemmeinSwift.clientInfo(platform: "expo ios"), "gemmein-swift/\(GemmeinSwift.version) expo-ios",
                       "a second space would split the ledger's field")
        XCTAssertEqual(GemmeinSwift.clientInfo(platform: "ios\nx-injected: 1"), "gemmein-swift/\(GemmeinSwift.version) ios-x-injected-1")
        XCTAssertEqual(GemmeinSwift.clientInfo(platform: "!!!"), "gemmein-swift/\(GemmeinSwift.version)")
        XCTAssertLessThanOrEqual(GemmeinSwift.clientInfo(platform: String(repeating: "a", count: 200)).count, 64,
                                 "a tag that arrives truncated attributes nothing")
    }
}

/// A token store the device refuses to write to — the unsigned-simulator
/// shape, without a simulator. `get` and `clear` stay lenient, exactly as
/// the protocol says they must.
final class RefusingTokenStore: TokenStore, @unchecked Sendable {
    func get() async -> String? { nil }

    func set(_ token: String) async throws {
        throw GemmeinError(
            status: 0,
            code: "secure_store_unavailable",
            message: "The session could not be stored in the Keychain (OSStatus -34018: A required entitlement isn't present.) "
                + "— on the simulator this is an unsigned build with no keychain access group; "
                + "sign the app (ad-hoc is enough)"
        )
    }

    func clear() async {}
}
