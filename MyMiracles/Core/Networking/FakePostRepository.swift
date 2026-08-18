#if DEBUG
import Foundation

/// An in-memory stand-in for the Worker, faithful enough to drive the whole journey.
///
/// It enforces the rules the server enforces — ownership, one prayer response per person,
/// a prayer answered only once — so a test that passes here is testing the real behaviour
/// rather than a permissive mock. Compiled only in DEBUG.
nonisolated final class FakePostRepository: PostRepository, JournalRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var posts: [String: Post] = [:]
    private var updatesByPost: [String: [PostUpdate]] = [:]
    private var links: [String: PostLink] = [:]
    private var seenKeys: [String: String] = [:]

    /// Set to make the next call fail, for exercising error and offline paths.
    var nextFailure: AppError?
    private(set) var createCallCount = 0
    private(set) var answerCallCount = 0

    init(seed: [Post] = []) {
        for post in seed { posts[post.id] = post }
    }

    private func failIfScripted() throws(AppError) {
        if let failure = lock.withLock({ let f = nextFailure; nextFailure = nil; return f }) {
            throw failure
        }
    }

    func create(_ draft: PostDraft, idempotencyKey: String) async throws(AppError) -> Post {
        try failIfScripted()

        return lock.withLock {
            createCallCount += 1
            // Matches the Worker: a repeated key replays instead of writing again.
            if let existing = seenKeys[idempotencyKey], let post = posts[existing] {
                return post
            }

            let normalized = draft.normalized
            let post = Post(
                id: UUID().uuidString,
                type: normalized.type,
                body: normalized.body,
                visibility: normalized.visibility,
                status: .active,
                createdAt: Date(),
                updatedAt: Date(),
                answeredAt: nil,
                version: 1,
                prayerResponseCount: 0,
                commentCount: 0,
                updateCount: 0,
                displayProfile: normalized.anonymous
                    ? nil
                    : DisplayProfile(username: "connor", displayName: "Connor"),
                isMine: true,
                hasPrayed: false,
                link: nil
            )
            posts[post.id] = post
            seenKeys[idempotencyKey] = post.id
            return post
        }
    }

    func post(id: String) async throws(AppError) -> Post {
        try failIfScripted()
        let found: Post? = lock.withLock {
            guard var post = posts[id] else { return nil }
            post.link = links[id]
            return post
        }
        guard let found else { throw AppError(kind: .notFound) }
        return found
    }

    func journal(after cursor: String?) async throws(AppError) -> PostPage {
        try failIfScripted()
        return lock.withLock {
            PostPage(
                items: posts.values.sorted { $0.createdAt > $1.createdAt },
                nextCursor: nil
            )
        }
    }

    func feed(after cursor: String?) async throws(AppError) -> PostPage {
        try await journal(after: cursor)
    }

    // MARK: - JournalRepository
    //
    // The fake stands in for the whole Worker, so it serves the journal's filtered and
    // searchable view as well as plain post CRUD.

    func journal(
        filter: JournalFilter,
        search: String?,
        year: Int?,
        cursor: String?
    ) async throws(AppError) -> PostPage {
        try failIfScripted()
        return lock.withLock {
            var matched = posts.values.sorted { $0.createdAt > $1.createdAt }
            if let type = filter.postType { matched = matched.filter { $0.type == type } }
            if let search, !search.isEmpty {
                matched = matched.filter { $0.body.localizedCaseInsensitiveContains(search) }
            }
            if let year {
                matched = matched.filter {
                    Calendar.current.component(.year, from: $0.createdAt) == year
                }
            }
            return PostPage(items: matched, nextCursor: nil)
        }
    }

    func summary() async throws(AppError) -> JournalSummary {
        try failIfScripted()
        return lock.withLock {
            var byYear: [Int: Int] = [:]
            for entry in posts.values {
                byYear[Calendar.current.component(.year, from: entry.createdAt), default: 0] += 1
            }
            return JournalSummary(
                years: byYear.keys.sorted(by: >).map { .init(year: $0, total: byYear[$0]!) },
                total: posts.count
            )
        }
    }

    func delete(id: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock { _ = posts.removeValue(forKey: id) }
    }

    func pray(for postID: String) async throws(AppError) -> PrayerResponseResult {
        try failIfScripted()
        let result: PrayerResponseResult? = lock.withLock {
            guard var post = posts[postID] else { return nil }
            if !post.hasPrayed {
                post.hasPrayed = true
                post.prayerResponseCount += 1
                posts[postID] = post
            }
            return PrayerResponseResult(prayerResponseCount: post.prayerResponseCount, hasPrayed: true)
        }
        guard let result else { throw AppError(kind: .notFound) }
        return result
    }

    func withdrawPrayer(for postID: String) async throws(AppError) -> PrayerResponseResult {
        try failIfScripted()
        let result: PrayerResponseResult? = lock.withLock {
            guard var post = posts[postID] else { return nil }
            if post.hasPrayed {
                post.hasPrayed = false
                post.prayerResponseCount = max(post.prayerResponseCount - 1, 0)
                posts[postID] = post
            }
            return PrayerResponseResult(prayerResponseCount: post.prayerResponseCount, hasPrayed: false)
        }
        guard let result else { throw AppError(kind: .notFound) }
        return result
    }

    func updates(for postID: String) async throws(AppError) -> [PostUpdate] {
        try failIfScripted()
        return lock.withLock { updatesByPost[postID] ?? [] }
    }

    func addUpdate(to postID: String, body: String) async throws(AppError) -> PostUpdate {
        try failIfScripted()
        let update: PostUpdate? = lock.withLock {
            guard var post = posts[postID] else { return nil }
            let update = PostUpdate(id: UUID().uuidString, body: body, createdAt: Date())
            updatesByPost[postID, default: []].append(update)
            post.updateCount += 1
            posts[postID] = post
            return update
        }
        guard let update else { throw AppError(kind: .notFound) }
        return update
    }

    func markAnswered(
        prayerID: String,
        miracle: PostDraft,
        idempotencyKey: String
    ) async throws(AppError) -> Post {
        try failIfScripted()

        // The lock closure cannot throw a typed error, so the outcome is returned and
        // unwrapped outside it.
        enum Outcome { case created(Post), refused(AppError) }

        let outcome: Outcome = lock.withLock {
            answerCallCount += 1
            if let existing = seenKeys[idempotencyKey], let post = posts[existing] {
                return .created(post)
            }

            guard var prayer = posts[prayerID] else { return .refused(AppError(kind: .notFound)) }
            guard prayer.type == .prayer else { return .refused(AppError(kind: .unexpected)) }
            guard prayer.status == .active else { return .refused(AppError(kind: .conflict)) }

            let normalized = miracle.normalized
            let created = Post(
                id: UUID().uuidString,
                type: .miracle,
                body: normalized.body,
                visibility: normalized.visibility,
                status: .active,
                createdAt: Date(),
                updatedAt: Date(),
                answeredAt: nil,
                version: 1,
                prayerResponseCount: 0,
                commentCount: 0,
                updateCount: 0,
                displayProfile: normalized.anonymous
                    ? nil
                    : DisplayProfile(username: "connor", displayName: "Connor"),
                isMine: true,
                hasPrayed: false,
                link: nil
            )

            prayer.status = .answered
            prayer.answeredAt = Date()
            posts[prayerID] = prayer
            posts[created.id] = created
            seenKeys[idempotencyKey] = created.id

            // Both directions, exactly as the Worker resolves them.
            links[prayerID] = PostLink(
                id: created.id, type: .miracle, excerpt: created.body, createdAt: created.createdAt
            )
            links[created.id] = PostLink(
                id: prayerID, type: .prayer, excerpt: prayer.body, createdAt: prayer.createdAt
            )
            return .created(created)
        }

        switch outcome {
        case .created(let post): return post
        case .refused(let error): throw error
        }
    }
}

nonisolated extension Post {
    /// A post fixture for previews and tests.
    static func fixture(
        id: String = UUID().uuidString,
        type: PostType = .prayer,
        body: String = "Please pray for my marriage.",
        visibility: PostVisibility = .publicFeed,
        status: PostStatus = .active,
        prayerResponseCount: Int = 0,
        anonymous: Bool = false,
        isMine: Bool = true,
        hasPrayed: Bool = false,
        link: PostLink? = nil
    ) -> Post {
        Post(
            id: id,
            type: type,
            body: body,
            visibility: visibility,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_785_283_200),
            updatedAt: Date(timeIntervalSince1970: 1_785_283_200),
            answeredAt: status == .answered ? Date(timeIntervalSince1970: 1_785_369_600) : nil,
            version: 1,
            prayerResponseCount: prayerResponseCount,
            commentCount: 0,
            updateCount: 0,
            displayProfile: anonymous ? nil : DisplayProfile(username: "connor", displayName: "Connor"),
            isMine: isMine,
            hasPrayed: hasPrayed,
            link: link
        )
    }
}
#endif
