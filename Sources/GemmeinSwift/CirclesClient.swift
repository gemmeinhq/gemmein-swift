import Foundation

/// CIRCLES: one circle as a member sees it (named apart from SwiftUI's `Circle`).
public struct CircleInfo: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The person who runs it (adds, removes, disbands).
    public let createdBy: String
    public let members: Int
    /// "creator" or "member".
    public let you: String
    public let createdAt: String

    init(json: [String: JSONValue]) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        createdBy = json["createdBy"]?.string ?? ""
        members = json["members"]?.int ?? 0
        you = json["you"]?.string ?? ""
        createdAt = json["createdAt"]?.string ?? ""
    }
}

/// One page of circles. When `hasMore` is true, pass `cursor` for the next page.
public struct CirclesPage: Sendable, Equatable {
    public let circles: [CircleInfo]
    public let cursor: String?
    public let hasMore: Bool

    init(json: [String: JSONValue]) {
        circles = (json["circles"]?.array ?? []).compactMap { $0.object.map { CircleInfo(json: $0) } }
        cursor = json["cursor"]?.string
        hasMore = json["hasMore"]?.bool ?? false
    }
}

/// What leaving a circle answers.
public struct CircleLeft: Sendable, Equatable {
    public let circleId: String
    /// The member who runs it now, when its creator left.
    public let transferredTo: String?
}

/// CIRCLES: small groups a person makes — close friends, a team, a family.
/// No roles: the person who creates a circle adds and removes its members;
/// every member reads the circle's posts and its member list, and may leave.
/// Post to a circle with `create(data, visibility: .circle(circle.id))`
/// (community and shared); upload its files with the same visibility. Only
/// the circle's CURRENT members read them — removing someone, or their
/// leaving, ends it at once. The creator leaving names a member to take over
/// (`leave(id, transferTo:)`) or disbands it. A block takes each person out
/// of the other's circles.
///
///     let close = try await g.circles.create("Close friends")
///     try await g.circles.add(close.id, friendId)
///
/// Bounded like the JS SDK: members per circle by the app's plan (50; 250 on
/// Live; 1,000 on Growing — `circle_full`), 100 circles per person
/// (`circle_limit`), 300 circle changes an hour (`too_many_changes`).
public final class CirclesClient: @unchecked Sendable {
    private let config: ClientConfig

    init(config: ClientConfig) { self.config = config }

    /// Make a circle — you are its creator and first member.
    // route: POST /auth/circles
    public func create(_ name: String) async throws -> CircleInfo {
        CircleInfo(json: try requireObject(
            try await runtimeRequest(config, "/auth/circles", method: "POST", body: try JSONCodec.encode(["name": name]), extraHeaders: ["content-type": "application/json"]),
            "a circle"
        ))
    }

    /// The circles you are in, newest first.
    // route: GET /auth/circles
    public func list(limit: Int? = nil, cursor: String? = nil) async throws -> CirclesPage {
        CirclesPage(json: try requireObject(try await runtimeRequest(config, "/auth/circles\(query(limit: limit, cursor: cursor))"), "a circles page"))
    }

    /// One circle you are in.
    // route: GET /auth/circles/{id}
    public func get(_ circleId: String) async throws -> CircleInfo {
        CircleInfo(json: try requireObject(try await runtimeRequest(config, "/auth/circles/\(percentEncodeComponent(circleId))"), "a circle"))
    }

    /// A circle's members, newest first (never anyone blocked with you).
    // route: GET /auth/circles/{id}/members
    public func members(_ circleId: String, limit: Int? = nil, cursor: String? = nil) async throws -> PeoplePage {
        PeoplePage(json: try requireObject(try await runtimeRequest(config, "/auth/circles/\(percentEncodeComponent(circleId))/members\(query(limit: limit, cursor: cursor))"), "a people page"))
    }

    /// Add someone to your circle (its creator only).
    // route: POST /auth/circles/{id}/members/{person}
    @discardableResult
    public func add(_ circleId: String, _ userId: String) async throws -> CircleInfo {
        try await member(circleId, userId, method: "POST")
    }

    /// Take someone out of your circle (its creator only) — their access ends at once.
    // route: DELETE /auth/circles/{id}/members/{person}
    @discardableResult
    public func remove(_ circleId: String, _ userId: String) async throws -> CircleInfo {
        try await member(circleId, userId, method: "DELETE")
    }

    /// Leave a circle. Its creator names a member to take it over: `transferTo`.
    // route: POST /auth/circles/{id}/leave
    @discardableResult
    public func leave(_ circleId: String, transferTo: String? = nil) async throws -> CircleLeft {
        let payload: [String: Any] = transferTo.map { ["transferTo": $0] } ?? [:]
        let body = try requireObject(
            try await runtimeRequest(config, "/auth/circles/\(percentEncodeComponent(circleId))/leave", method: "POST", body: try JSONCodec.encode(payload), extraHeaders: ["content-type": "application/json"]),
            "a circle"
        )
        return CircleLeft(circleId: body["circleId"]?.string ?? circleId, transferredTo: body["transferredTo"]?.string)
    }

    /// Disband your circle (its creator only) — its posts are then read by their authors alone.
    // route: DELETE /auth/circles/{id}
    public func disband(_ circleId: String) async throws {
        _ = try await runtimeRequest(config, "/auth/circles/\(percentEncodeComponent(circleId))", method: "DELETE")
    }

    private func member(_ circleId: String, _ userId: String, method: String) async throws -> CircleInfo {
        CircleInfo(json: try requireObject(
            try await runtimeRequest(config, "/auth/circles/\(percentEncodeComponent(circleId))/members/\(percentEncodeComponent(userId))", method: method),
            "a circle"
        ))
    }

    private func query(limit: Int?, cursor: String?) -> String {
        var pairs: [(String, String)] = []
        if let limit { pairs.append(("limit", String(limit))) }
        if let cursor, !cursor.isEmpty { pairs.append(("cursor", cursor)) }
        return pairs.isEmpty ? "" : "?\(formURLEncode(pairs))"
    }
}
