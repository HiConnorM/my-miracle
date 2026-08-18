import Foundation

/// Everything the product does with posts.
///
/// A protocol so feature models can be driven against a fake — the whole
/// prayer → answered → miracle journey is testable without a network (rule 17).
nonisolated protocol PostRepository: Sendable {
    func create(_ draft: PostDraft, idempotencyKey: String) async throws(AppError) -> Post
    func post(id: String) async throws(AppError) -> Post
    func journal(after cursor: String?) async throws(AppError) -> PostPage
    func feed(after cursor: String?) async throws(AppError) -> PostPage
    func delete(id: String) async throws(AppError)

    func pray(for postID: String) async throws(AppError) -> PrayerResponseResult
    func withdrawPrayer(for postID: String) async throws(AppError) -> PrayerResponseResult

    func updates(for postID: String) async throws(AppError) -> [PostUpdate]
    func addUpdate(to postID: String, body: String) async throws(AppError) -> PostUpdate

    /// Converts a prayer into a miracle. One transactional call — never a sequence of
    /// writes from here (rule 10).
    func markAnswered(
        prayerID: String,
        miracle: PostDraft,
        idempotencyKey: String
    ) async throws(AppError) -> Post
}

nonisolated struct HTTPPostRepository: PostRepository {
    private let client: any APIClient

    init(client: any APIClient) {
        self.client = client
    }

    func create(_ draft: PostDraft, idempotencyKey: String = UUID().uuidString) async throws(AppError) -> Post {
        struct Body: Encodable, Sendable {
            let type: String
            let body: String
            let visibility: String
            let anonymous: Bool
        }
        let normalized = draft.normalized

        return try await client.send(
            APIRequest<Post>(
                method: .post,
                path: "/v1/posts",
                body: try APICoding.encode(
                    Body(
                        type: normalized.type.rawValue,
                        body: normalized.body,
                        visibility: normalized.visibility.rawValue,
                        anonymous: normalized.anonymous
                    )
                ),
                idempotencyKey: idempotencyKey
            )
        )
    }

    func post(id: String) async throws(AppError) -> Post {
        try await client.send(APIRequest<Post>.get("/v1/posts/\(id)"))
    }

    func journal(after cursor: String?) async throws(AppError) -> PostPage {
        try await client.send(APIRequest<PostPage>.get("/v1/me/journal", query: cursorQuery(cursor)))
    }

    func feed(after cursor: String?) async throws(AppError) -> PostPage {
        try await client.send(APIRequest<PostPage>.get("/v1/feed", query: cursorQuery(cursor)))
    }

    func delete(id: String) async throws(AppError) {
        _ = try await client.send(
            APIRequest<EmptyResponse>(method: .delete, path: "/v1/posts/\(id)")
        )
    }

    func pray(for postID: String) async throws(AppError) -> PrayerResponseResult {
        try await client.send(
            APIRequest<PrayerResponseResult>(
                method: .post,
                path: "/v1/posts/\(postID)/prayers",
                // Praying twice is a no-op server-side, so no idempotency key is needed —
                // the uniqueness constraint already makes a retry harmless.
                idempotencyKey: nil
            )
        )
    }

    func withdrawPrayer(for postID: String) async throws(AppError) -> PrayerResponseResult {
        try await client.send(
            APIRequest<PrayerResponseResult>(
                method: .delete,
                path: "/v1/posts/\(postID)/prayers"
            )
        )
    }

    func updates(for postID: String) async throws(AppError) -> [PostUpdate] {
        struct Page: Decodable, Sendable { let items: [PostUpdate] }
        return try await client.send(
            APIRequest<Page>.get("/v1/posts/\(postID)/updates")
        ).items
    }

    func addUpdate(to postID: String, body: String) async throws(AppError) -> PostUpdate {
        struct Body: Encodable, Sendable { let body: String }
        return try await client.send(
            APIRequest<PostUpdate>(
                method: .post,
                path: "/v1/posts/\(postID)/updates",
                body: try APICoding.encode(Body(body: body))
            )
        )
    }

    func markAnswered(
        prayerID: String,
        miracle: PostDraft,
        idempotencyKey: String = UUID().uuidString
    ) async throws(AppError) -> Post {
        struct Body: Encodable, Sendable {
            let body: String
            let visibility: String
            let anonymous: Bool
        }
        let normalized = miracle.normalized

        return try await client.send(
            APIRequest<Post>(
                method: .post,
                path: "/v1/posts/\(prayerID)/answer",
                body: try APICoding.encode(
                    Body(
                        body: normalized.body,
                        visibility: normalized.visibility.rawValue,
                        anonymous: normalized.anonymous
                    )
                ),
                idempotencyKey: idempotencyKey
            )
        )
    }

    private func cursorQuery(_ cursor: String?) -> [URLQueryItem] {
        cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
    }
}
