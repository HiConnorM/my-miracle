import Foundation

nonisolated struct PersonSummary: Codable, Sendable, Equatable, Identifiable, Hashable {
    let username: String
    let displayName: String
    var avatarKey: String?
    var bio: String?
    var isFollowing: Bool = false

    var id: String { username }

    var displayProfile: DisplayProfile {
        DisplayProfile(username: username, displayName: displayName, avatarKey: avatarKey)
    }
}

nonisolated struct ProfileDetail: Codable, Sendable, Equatable {
    let username: String
    let displayName: String
    var avatarKey: String?
    var bio: String?
    let createdAt: Date
    let isMe: Bool
    var isFollowing: Bool

    // Note what is absent: follower and following counts. There are no public popularity
    // metrics (rule 13), so there is nowhere for one to be displayed even by accident.

    var displayProfile: DisplayProfile {
        DisplayProfile(username: username, displayName: displayName, avatarKey: avatarKey)
    }
}

/// A short note of support on a post.
///
/// Named for what it is rather than for the table it lives in — and `Comment` is taken by
/// Swift Testing, which is a fair hint that the product word is the better one.
nonisolated struct Encouragement: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let body: String
    let createdAt: Date
    var isMine: Bool = false
    var author: DisplayProfile?
}

nonisolated enum ReportCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case harassment
    case sexual
    case graphic
    case spam
    case scam
    case selfHarm = "self_harm"
    case impersonation
    case medicalMisinformation = "medical_misinformation"
    case privacy
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .harassment: "Harassment or bullying"
        case .sexual: "Sexual content"
        case .graphic: "Graphic content"
        case .spam: "Spam"
        case .scam: "Scam or fraud"
        case .selfHarm: "Someone may be in danger"
        case .impersonation: "Pretending to be someone else"
        case .medicalMisinformation: "Dangerous medical advice"
        case .privacy: "Shares private information"
        case .other: "Something else"
        }
    }
}

/// Profiles, following, comments, saving and finding people.
nonisolated protocol SocialRepository: Sendable {
    func profile(username: String) async throws(AppError) -> ProfileDetail
    func timeline(username: String, cursor: String?) async throws(AppError) -> PostPage
    func follow(username: String) async throws(AppError)
    func unfollow(username: String) async throws(AppError)
    func block(username: String) async throws(AppError)

    func comments(for postID: String) async throws(AppError) -> [Encouragement]
    func addComment(to postID: String, body: String) async throws(AppError) -> Encouragement
    func deleteComment(id: String) async throws(AppError)

    func save(postID: String) async throws(AppError)
    func unsave(postID: String) async throws(AppError)
    func saved(cursor: String?) async throws(AppError) -> PostPage

    func searchPeople(query: String) async throws(AppError) -> [PersonSummary]
    func report(
        subjectType: String,
        subjectID: String,
        category: ReportCategory,
        details: String?
    ) async throws(AppError)
}

nonisolated struct HTTPSocialRepository: SocialRepository {
    private let client: any APIClient

    init(client: any APIClient) {
        self.client = client
    }

    func profile(username: String) async throws(AppError) -> ProfileDetail {
        try await client.send(APIRequest<ProfileDetail>.get("/v1/profiles/\(username)"))
    }

    func timeline(username: String, cursor: String?) async throws(AppError) -> PostPage {
        try await client.send(
            APIRequest<PostPage>.get(
                "/v1/profiles/\(username)/posts",
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            )
        )
    }

    func follow(username: String) async throws(AppError) {
        struct Body: Encodable, Sendable { let username: String }
        _ = try await client.send(
            APIRequest<FollowResult>(
                method: .post,
                path: "/v1/follows",
                body: try APICoding.encode(Body(username: username))
            )
        )
    }

    func unfollow(username: String) async throws(AppError) {
        _ = try await client.send(
            APIRequest<FollowResult>(method: .delete, path: "/v1/follows/\(username)")
        )
    }

    func block(username: String) async throws(AppError) {
        struct Body: Encodable, Sendable { let username: String }
        _ = try await client.send(
            APIRequest<BlockResult>(
                method: .post,
                path: "/v1/blocks",
                body: try APICoding.encode(Body(username: username))
            )
        )
    }

    func comments(for postID: String) async throws(AppError) -> [Encouragement] {
        struct Page: Decodable, Sendable { let items: [Encouragement] }
        return try await client.send(
            APIRequest<Page>.get("/v1/posts/\(postID)/comments")
        ).items
    }

    func addComment(to postID: String, body: String) async throws(AppError) -> Encouragement {
        struct Body: Encodable, Sendable { let body: String }
        return try await client.send(
            APIRequest<Encouragement>(
                method: .post,
                path: "/v1/posts/\(postID)/comments",
                body: try APICoding.encode(Body(body: body))
            )
        )
    }

    func deleteComment(id: String) async throws(AppError) {
        _ = try await client.send(
            APIRequest<EmptyResponse>(method: .delete, path: "/v1/comments/\(id)")
        )
    }

    func save(postID: String) async throws(AppError) {
        _ = try await client.send(
            APIRequest<SaveResult>(method: .post, path: "/v1/posts/\(postID)/save")
        )
    }

    func unsave(postID: String) async throws(AppError) {
        _ = try await client.send(
            APIRequest<SaveResult>(method: .delete, path: "/v1/posts/\(postID)/save")
        )
    }

    func saved(cursor: String?) async throws(AppError) -> PostPage {
        try await client.send(
            APIRequest<PostPage>.get(
                "/v1/me/saved",
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
            )
        )
    }

    func searchPeople(query: String) async throws(AppError) -> [PersonSummary] {
        struct Page: Decodable, Sendable { let items: [PersonSummary] }
        return try await client.send(
            APIRequest<Page>.get("/v1/people", query: [URLQueryItem(name: "q", value: query)])
        ).items
    }

    func report(
        subjectType: String,
        subjectID: String,
        category: ReportCategory,
        details: String?
    ) async throws(AppError) {
        struct Body: Encodable, Sendable {
            let subjectType: String
            let subjectId: String
            let category: String
            let details: String?
        }
        _ = try await client.send(
            APIRequest<ReportResult>(
                method: .post,
                path: "/v1/reports",
                body: try APICoding.encode(
                    Body(
                        subjectType: subjectType,
                        subjectId: subjectID,
                        category: category.rawValue,
                        details: details
                    )
                )
            )
        )
    }
}

nonisolated struct FollowResult: Decodable, Sendable { let following: Bool }
nonisolated struct BlockResult: Decodable, Sendable { let blocked: Bool }
nonisolated struct SaveResult: Decodable, Sendable { let saved: Bool }
nonisolated struct ReportResult: Decodable, Sendable { let submitted: Bool }
