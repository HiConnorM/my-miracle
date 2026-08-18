import Foundation

nonisolated enum PostType: String, Codable, Sendable, CaseIterable {
    case prayer, miracle, gratitude, testimony

    var title: String {
        switch self {
        case .prayer: "Prayer"
        case .miracle: "Miracle"
        case .gratitude: "Gratitude"
        case .testimony: "Testimony"
        }
    }

    var symbol: String {
        switch self {
        case .prayer: "hands.and.sparkles"
        case .miracle: "sparkle"
        case .gratitude: "leaf"
        case .testimony: "text.quote"
        }
    }
}

nonisolated enum PostVisibility: String, Codable, Sendable, CaseIterable, Identifiable {
    case privateOnly = "private"
    case followers
    case publicFeed = "public"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateOnly: "Only me"
        case .followers: "People I share with"
        case .publicFeed: "Anyone"
        }
    }

    var explanation: String {
        switch self {
        case .privateOnly: "Kept in your journal. Nobody else can see it."
        case .followers: "Shared with people who follow you."
        case .publicFeed: "Anyone on My Miracles can see and pray."
        }
    }

    var symbol: String {
        switch self {
        case .privateOnly: "lock"
        case .followers: "person.2"
        case .publicFeed: "globe"
        }
    }

    /// Anonymity is meaningless without an audience, and the server rejects the
    /// combination — so the composer hides the toggle rather than offering an invalid state.
    var allowsAnonymity: Bool { self != .privateOnly }
}

nonisolated enum PostStatus: String, Codable, Sendable {
    case active, answered, archived, removed
}

nonisolated struct DisplayProfile: Codable, Sendable, Equatable, Hashable {
    let username: String
    let displayName: String
    var avatarKey: String?
}

/// A post as the client sees it.
///
/// There is no author field, and there must never be one. `displayProfile` is who the post
/// is *shown* as; `nil` means anonymous. The real author lives only in the Worker's
/// database (rules 8 and 9) — see `docs/database.md`.
nonisolated struct Post: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let type: PostType
    let body: String
    let visibility: PostVisibility
    var status: PostStatus
    let createdAt: Date
    let updatedAt: Date
    var answeredAt: Date?
    let version: Int
    var prayerResponseCount: Int
    var commentCount: Int
    var updateCount: Int
    var displayProfile: DisplayProfile?
    /// True for one's own posts, including those published anonymously.
    let isMine: Bool
    var hasPrayed: Bool
    /// The other half of an answered story. Absent when there is none, or when the linked
    /// post is not visible to this viewer.
    var link: PostLink?

    var isAnonymous: Bool { displayProfile == nil }
    var isAnsweredPrayer: Bool { type == .prayer && status == .answered }
    /// Only an open prayer of one's own can be answered.
    var canBeAnswered: Bool { isMine && type == .prayer && status == .active }
    var acceptsPrayer: Bool { visibility != .privateOnly && status != .removed }
}

nonisolated struct PostLink: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let type: PostType
    let excerpt: String
    let createdAt: Date
}

nonisolated struct PostUpdate: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let body: String
    let createdAt: Date
}

nonisolated struct PostPage: Codable, Sendable, Equatable {
    let items: [Post]
    var nextCursor: String?
}

nonisolated struct PrayerResponseResult: Codable, Sendable, Equatable {
    let prayerResponseCount: Int
    let hasPrayed: Bool
}

/// What the composer produces.
nonisolated struct PostDraft: Sendable, Equatable {
    var type: PostType
    var body: String
    var visibility: PostVisibility
    var anonymous: Bool

    init(
        type: PostType = .prayer,
        body: String = "",
        visibility: PostVisibility = .privateOnly,
        anonymous: Bool = false
    ) {
        self.type = type
        self.body = body
        self.visibility = visibility
        self.anonymous = anonymous
    }

    /// Anonymity cannot survive a switch to private, so it is cleared rather than left in
    /// a state the server would reject.
    var normalized: PostDraft {
        var copy = self
        copy.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visibility.allowsAnonymity { copy.anonymous = false }
        return copy
    }

    var isSendable: Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 5000
    }
}
