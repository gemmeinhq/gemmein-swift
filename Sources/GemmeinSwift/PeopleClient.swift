import Foundation

/// BLOCKS + FOLLOWS: what the signed-in person may know of their relationship
/// with one other person. `blocking` is THEIR OWN block — whether the other
/// person blocked them is never told.
public struct PersonRelationship: Sendable, Equatable {
    public let userId: String
    public let following: Bool
    public let followsYou: Bool
    /// They follow each other.
    public let friends: Bool
    public let blocking: Bool
    /// PRIVATE ACCOUNTS: your follow request waits for them / theirs waits for you.
    public let requested: Bool
    public let requestedYou: Bool
    /// Their account is private: a follow is a request they accept.
    public let `private`: Bool
    /// Their profile numbers (`relationship` only) — nil between two people blocked either way.
    public let counts: ProfileCounts?

    init(json: [String: JSONValue]) {
        userId = json["userId"]?.string ?? ""
        following = json["following"]?.bool ?? false
        followsYou = json["followsYou"]?.bool ?? false
        friends = json["friends"]?.bool ?? false
        blocking = json["blocking"]?.bool ?? false
        requested = json["requested"]?.bool ?? false
        requestedYou = json["requestedYou"]?.bool ?? false
        `private` = json["private"]?.bool ?? false
        counts = json["counts"]?.object.map { ProfileCounts(followers: $0["followers"]?.int ?? 0, following: $0["following"]?.int ?? 0) }
    }
}

/// A person's profile numbers, as any signed-in person sees them.
public struct ProfileCounts: Sendable, Equatable {
    public let followers: Int
    public let following: Int
}

/// One person on a people list: their id, and when the follow (or block)
/// began — for friends, when they became mutual.
public struct PersonEdge: Sendable, Equatable {
    public let userId: String
    public let since: String

    init(json: [String: JSONValue]) {
        userId = json["userId"]?.string ?? ""
        since = json["since"]?.string ?? ""
    }
}

/// One page of a people list. When `hasMore` is true, pass `cursor` for the next page.
public struct PeoplePage: Sendable, Equatable {
    public let people: [PersonEdge]
    public let cursor: String?
    public let hasMore: Bool

    init(json: [String: JSONValue]) {
        people = (json["people"]?.array ?? []).compactMap { $0.object.map { PersonEdge(json: $0) } }
        cursor = json["cursor"]?.string
        hasMore = json["hasMore"]?.bool ?? false
    }
}

/// The person's own totals, and whether their account is private.
public struct PeopleCounts: Sendable, Equatable {
    public let following: Int
    public let followers: Int
    public let blocked: Int
    /// Follow requests waiting for you.
    public let requests: Int
    public let `private`: Bool
}

/// The answer to `setPrivate`: the setting, and how many waiting requests
/// turning private off accepted.
public struct PrivacySetting: Sendable, Equatable {
    public let `private`: Bool
    public let accepted: Int
}

/// BLOCKS + FOLLOWS: the signed-in person's own follows and blocks. Follows
/// are one-way — anyone follows anyone; `friends` are people who follow each
/// other (worked out when asked, never stored). A block works both ways:
/// neither person sees the other's records (posts, profile, messages) in any
/// collection while signed in, any follow between them ends, and neither can
/// follow or message the other — whoever blocked, the refusal is the same
/// sentence (`person_unavailable`, 403). Unblocking does not bring a follow
/// back.
///
///     try await g.people.follow(post.ownerUserId!)
///     let feed = try await g.collection("posts").list(ListOptions(author: "following"))
///     try await g.people.block(userId)
///
/// Bounded like the JS SDK: 5,000 follows and 1,000 blocks per person
/// (`follow_limit` / `block_limit`), 200 follow and 60 block changes an hour
/// (`too_many_changes`); cloud Development lower (`development_capped`).
/// Session required (`session_required`, 401).
public final class PeopleClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Follow someone (a second follow changes nothing).
    // route: POST /auth/people/{id}/follow
    @discardableResult
    public func follow(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "follow", method: "POST")
    }

    /// Stop following someone — their followers-only posts leave at once.
    // route: DELETE /auth/people/{id}/follow
    @discardableResult
    public func unfollow(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "follow", method: "DELETE")
    }

    /// Block someone: both ways, every collection; any follow between you ends.
    // route: POST /auth/people/{id}/block
    @discardableResult
    public func block(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "block", method: "POST")
    }

    /// Lift your own block (a follow does not come back).
    // route: DELETE /auth/people/{id}/block
    @discardableResult
    public func unblock(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "block", method: "DELETE")
    }

    /// Your relationship with one person.
    // route: GET /auth/people/{id}
    public func relationship(_ userId: String) async throws -> PersonRelationship {
        PersonRelationship(json: try requireObject(try await runtimeRequest(config, "/auth/people/\(percentEncodeComponent(userId))"), "a relationship"))
    }

    /// The people you follow, newest first.
    // route: GET /auth/people
    public func following(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("following", limit: limit, cursor: cursor)
    }

    /// The people who follow you, newest first.
    // route: GET /auth/people
    public func followers(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("followers", limit: limit, cursor: cursor)
    }

    /// People you follow who follow you back, newest mutual first.
    // route: GET /auth/people
    public func friends(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("friends", limit: limit, cursor: cursor)
    }

    /// The people you blocked, newest first (never who blocked you).
    // route: GET /auth/people
    public func blocked(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("blocked", limit: limit, cursor: cursor)
    }

    /// Your own totals — following, followers, blocked, follow requests waiting for you — and whether your account is private.
    // route: GET /auth/people
    public func counts() async throws -> PeopleCounts {
        let body = try requireObject(try await runtimeRequest(config, "/auth/people"), "people counts")
        return PeopleCounts(following: body["following"]?.int ?? 0, followers: body["followers"]?.int ?? 0, blocked: body["blocked"]?.int ?? 0,
                            requests: body["requests"]?.int ?? 0, private: body["private"]?.bool ?? false)
    }

    /// Another person's followers (or yours) — never anyone blocked with you; a private account's only to the people it accepted (`person_private`, 403).
    // route: GET /auth/people
    public func followersOf(_ userId: String, limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("followers", limit: limit, cursor: cursor, of: userId)
    }

    /// The people another person follows (or you) — the same rules as followersOf.
    // route: GET /auth/people
    public func followingOf(_ userId: String, limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("following", limit: limit, cursor: cursor, of: userId)
    }

    /// PRIVATE ACCOUNTS: follow requests waiting for you, newest first.
    // route: GET /auth/people
    public func requests(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("requests", limit: limit, cursor: cursor)
    }

    /// Your own follow requests still waiting, newest first (unfollow withdraws one).
    // route: GET /auth/people
    public func requested(limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        try await page("requested", limit: limit, cursor: cursor)
    }

    /// Accept a follow request: they follow you from now on.
    // route: POST /auth/people/{id}/accept
    @discardableResult
    public func accept(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "accept", method: "POST")
    }

    /// Decline a follow request (they aren't told; they may ask again).
    // route: POST /auth/people/{id}/decline
    @discardableResult
    public func decline(_ userId: String) async throws -> PersonRelationship {
        try await edge(userId, "decline", method: "POST")
    }

    /// Make your account private — a follow becomes a request you accept, and your posts and files (on community, shared, public_read and admin_write) reach only the people you accepted — or public again, which accepts every request waiting. At most 10 switches an hour.
    // route: PUT /auth/people/privacy
    @discardableResult
    public func setPrivate(_ on: Bool) async throws -> PrivacySetting {
        let body = try requireObject(
            try await runtimeRequest(config, "/auth/people/privacy", method: "PUT", body: try JSONCodec.encode(["private": on]), extraHeaders: ["content-type": "application/json"]),
            "a privacy setting"
        )
        return PrivacySetting(private: body["private"]?.bool ?? false, accepted: body["accepted"]?.int ?? 0)
    }

    private func edge(_ userId: String, _ kind: String, method: String) async throws -> PersonRelationship {
        PersonRelationship(json: try requireObject(
            try await runtimeRequest(config, "/auth/people/\(percentEncodeComponent(userId))/\(kind)", method: method),
            "a relationship"
        ))
    }

    private func page(_ list: String, limit: Int?, cursor: String?, of: String? = nil) async throws -> PeoplePage {
        var pairs: [(String, String)] = [("list", list)]
        if let of { pairs.append(("of", of)) }
        if let limit { pairs.append(("limit", String(limit))) }
        if let cursor, !cursor.isEmpty { pairs.append(("cursor", cursor)) }
        return PeoplePage(json: try requireObject(try await runtimeRequest(config, "/auth/people?\(formURLEncode(pairs))"), "a people page"))
    }
}
