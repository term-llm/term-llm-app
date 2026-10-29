import Foundation

// MARK: - Wire models (term-llm `GET /v1/sessions`, `PATCH /v1/sessions/…`)

/// One row of an agent's conversation listing: the same `webSessionEntry` the
/// web sidebar reads. Times are unix milliseconds. Every field but `id` is
/// optional so older nodes decode.
struct AgentSessionEntry: Codable, Sendable, Equatable {
    let id: String
    let number: Int64?
    let name: String?
    let short_title: String?
    let long_title: String?
    let project_name: String?
    let archived: Bool?
    let pinned: Bool?
    let pin_order: Int64?
    let created_at: Int64?
    let last_message_at: Int64?
    let message_count: Int?
    let attention_store_instance_id: String?
    let attention_seq: Int64?
    let attention_unseen: Bool?
    let parent_session_id: String?

    init(id: String, number: Int64? = nil, name: String? = nil, short_title: String? = nil, long_title: String? = nil,
         project_name: String? = nil, archived: Bool? = nil, pinned: Bool? = nil, pin_order: Int64? = nil,
         created_at: Int64? = nil, last_message_at: Int64? = nil, message_count: Int? = nil,
         attention_store_instance_id: String? = nil, attention_seq: Int64? = nil, attention_unseen: Bool? = nil,
         parent_session_id: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.short_title = short_title
        self.long_title = long_title; self.project_name = project_name; self.archived = archived
        self.pinned = pinned; self.pin_order = pin_order; self.created_at = created_at
        self.last_message_at = last_message_at; self.message_count = message_count
        self.attention_store_instance_id = attention_store_instance_id; self.attention_seq = attention_seq
        self.attention_unseen = attention_unseen; self.parent_session_id = parent_session_id
    }
}

/// A page of the listing. Pinned sessions lead in their saved order, then the
/// rest by activity. `next_cursor` is absent on the last page and on nodes
/// that predate paging (they answer a bounded snapshot).
struct AgentSessionPage: Codable, Sendable, Equatable {
    let sessions: [AgentSessionEntry]
    let next_cursor: String?

    init(sessions: [AgentSessionEntry], next_cursor: String? = nil) {
        self.sessions = sessions
        self.next_cursor = next_cursor
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
    let short_title: String?
    let long_title: String?
    let archived: Bool?
    let pinned: Bool?
    let pin_order: Int64?
}

/// `PATCH /v1/sessions/pinned-order` answer: every pinned session in rank order.
struct PinnedSessionOrder: Codable, Sendable, Equatable {
    struct Position: Codable, Sendable, Equatable {
        let id: String
        let pin_order: Int64
    }
    let pinned: [Position]
}

// MARK: - Protocol

/// One agent's conversation history and its metadata edits. Hubs reach the
/// node through their validated proxy; a Direct Node answers for itself and
/// ignores `node_id`.
protocol HubSessionBrowsing: Sendable {
    func list_sessions(node_id: String, limit: Int, cursor: String?) async throws -> AgentSessionPage
    func update_session(node_id: String, session_id: String, patch: AgentSessionPatch) async throws -> AgentSessionPatchResult
    func reorder_pinned_sessions(node_id: String, session_ids: [String]) async throws -> PinnedSessionOrder
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
