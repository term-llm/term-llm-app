import Foundation

// MARK: - Wire models (term-llm `GET /v1/sessions`, `PATCH /v1/sessions/…`)

/// One row of an agent's conversation listing: the same `webSessionEntry` the
/// web sidebar reads. Times are unix milliseconds. Every field but `id` is
/// optional so older nodes decode.
struct AgentSessionEntry: Codable, Sendable, Equatable {
    let id: String
    let number: Int64?
    let name: String?
    let shortTitle: String?
    let longTitle: String?
    let projectName: String?
    let archived: Bool?
    let pinned: Bool?
    let pinOrder: Int64?
    let createdAt: Int64?
    let lastMessageAt: Int64?
    let messageCount: Int?
    let attentionStoreInstanceID: String?
    let attentionSeq: Int64?
    let attentionUnseen: Bool?
    let parentSessionID: String?

    enum CodingKeys: String, CodingKey {
        case id, number, name
        case shortTitle = "short_title"
        case longTitle = "long_title"
        case projectName = "project_name"
        case archived, pinned
        case pinOrder = "pin_order"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case messageCount = "message_count"
        case attentionStoreInstanceID = "attention_store_instance_id"
        case attentionSeq = "attention_seq"
        case attentionUnseen = "attention_unseen"
        case parentSessionID = "parent_session_id"
    }

    init(id: String, number: Int64? = nil, name: String? = nil, shortTitle: String? = nil, longTitle: String? = nil,
         projectName: String? = nil, archived: Bool? = nil, pinned: Bool? = nil, pinOrder: Int64? = nil,
         createdAt: Int64? = nil, lastMessageAt: Int64? = nil, messageCount: Int? = nil,
         attentionStoreInstanceID: String? = nil, attentionSeq: Int64? = nil, attentionUnseen: Bool? = nil,
         parentSessionID: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.shortTitle = shortTitle
        self.longTitle = longTitle; self.projectName = projectName; self.archived = archived
        self.pinned = pinned; self.pinOrder = pinOrder; self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt; self.messageCount = messageCount
        self.attentionStoreInstanceID = attentionStoreInstanceID; self.attentionSeq = attentionSeq
        self.attentionUnseen = attentionUnseen; self.parentSessionID = parentSessionID
    }
}

/// A page of the listing. Pinned sessions lead in their saved order, then the
/// rest by activity. `next_cursor` is absent on the last page and on nodes
/// that predate paging (they answer a bounded snapshot).
struct AgentSessionPage: Codable, Sendable, Equatable {
    let sessions: [AgentSessionEntry]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case sessions
        case nextCursor = "next_cursor"
    }

    init(sessions: [AgentSessionEntry], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// `PATCH /v1/sessions/{id}` body. Nil fields are omitted, so one request
/// changes exactly one thing.
struct AgentSessionPatch: Encodable, Sendable, Equatable {
    var name: String?
    var archived: Bool?
    var pinned: Bool?
}

/// The node's view of the session after a metadata PATCH.
struct AgentSessionPatchResult: Codable, Sendable, Equatable {
    let id: String
    let name: String?
    let shortTitle: String?
    let longTitle: String?
    let archived: Bool?
    let pinned: Bool?
    let pinOrder: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name
        case shortTitle = "short_title"
        case longTitle = "long_title"
        case archived, pinned
        case pinOrder = "pin_order"
    }
}

/// `PATCH /v1/sessions/pinned-order` answer: every pinned session in rank order.
struct PinnedSessionOrder: Codable, Sendable, Equatable {
    struct Position: Codable, Sendable, Equatable {
        let id: String
        let pinOrder: Int64

        enum CodingKeys: String, CodingKey {
            case id
            case pinOrder = "pin_order"
        }
    }
    let pinned: [Position]
}

// MARK: - Protocol

/// One agent's conversation history and its metadata edits. Hubs reach the
/// node through their validated proxy; a Direct Node answers for itself and
/// ignores `nodeID`.
protocol HubSessionBrowsing: Sendable {
    func listSessions(nodeID: String, limit: Int, cursor: String?) async throws -> AgentSessionPage
    func updateSession(nodeID: String, sessionID: String, patch: AgentSessionPatch) async throws -> AgentSessionPatchResult
    func reorderPinnedSessions(nodeID: String, sessionIDs: [String]) async throws -> PinnedSessionOrder
}

enum AgentSessionQuery {
    static let maximumLimit = 100
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Every project's sessions (`scope=all`), paged with an explicit limit.
    /// The cursor is opaque server text; strict encoding keeps `+`, `=`, `&`
    /// and `/` from changing how the node parses the query.
    static func percentEncoded(limit: Int, cursor: String?) -> String {
        var query = "scope=all&limit=\(min(max(limit, 1), maximumLimit))"
        if let cursor, !cursor.isEmpty {
            query += "&cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        return query
    }

    /// Session IDs become one path segment; refuse anything that could
    /// escape it rather than trusting percent-encoding through a proxy.
    static func isSafeSessionID(_ id: String) -> Bool {
        SessionSearchQuery.isSafeNodeID(id)
    }
}
