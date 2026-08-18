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
    /// Whether the viewer has bookmarked this. Private to them — saving is not a like, and
    /// the author is never told (docs/product-spec.md).
    var isSaved: Bool = false

    init(
        id: String,
        type: PostType,
        body: String,
        visibility: PostVisibility,
        status: PostStatus,
        createdAt: Date,
        updatedAt: Date,
        answeredAt: Date? = nil,
        version: Int,
        prayerResponseCount: Int,
        commentCount: Int,
        updateCount: Int,
        displayProfile: DisplayProfile?,
        isMine: Bool,
        hasPrayed: Bool,
        link: PostLink? = nil,
        isSaved: Bool = false
    ) {
        self.id = id
        self.type = type
        self.body = body
        self.visibility = visibility
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.answeredAt = answeredAt
        self.version = version
        self.prayerResponseCount = prayerResponseCount
        self.commentCount = commentCount
        self.updateCount = updateCount
        self.displayProfile = displayProfile
        self.isMine = isMine
        self.hasPrayed = hasPrayed
        self.link = link
        self.isSaved = isSaved
    }

    /// `isSaved` and `link` are only sent by the post-detail route, not by list endpoints.
    /// A synthesized decoder would reject a list payload for the missing key — a property
    /// default applies to the memberwise initializer, never to decoding.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(PostType.self, forKey: .type)
        body = try container.decode(String.self, forKey: .body)
        visibility = try container.decode(PostVisibility.self, forKey: .visibility)
        status = try container.decode(PostStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        answeredAt = try container.decodeIfPresent(Date.self, forKey: .answeredAt)
        version = try container.decode(Int.self, forKey: .version)
        prayerResponseCount = try container.decode(Int.self, forKey: .prayerResponseCount)
        commentCount = try container.decode(Int.self, forKey: .commentCount)
        updateCount = try container.decode(Int.self, forKey: .updateCount)
        displayProfile = try container.decodeIfPresent(DisplayProfile.self, forKey: .displayProfile)
        isMine = try container.decode(Bool.self, forKey: .isMine)
        hasPrayed = try container.decode(Bool.self, forKey: .hasPrayed)
        link = try container.decodeIfPresent(PostLink.self, forKey: .link)
        isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
    }

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
