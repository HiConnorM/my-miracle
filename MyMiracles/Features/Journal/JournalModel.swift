import Foundation
import Observation

/// The journal: everything you have ever recorded, newest first.
///
/// This is the durable value of the product — the part that still matters if the social
/// side goes quiet. It includes private entries and posts published anonymously, because
/// they are yours either way.
@MainActor
@Observable
final class JournalModel {
    private(set) var state: LoadState<[Post]> = .idle
    private(set) var isLoadingMore = false

    private var cursor: String?
    private let repository: any PostRepository
    private let analytics: any AnalyticsClient

    init(repository: any PostRepository, analytics: any AnalyticsClient) {
        self.repository = repository
        self.analytics = analytics
    }

    func load() async {
        guard !state.isLoading else { return }
        state = .loading
        cursor = nil

        do {
            let page = try await repository.journal(after: nil)
            cursor = page.nextCursor
            state = .resolved(page.items)
            analytics.track(.journalOpened)
        } catch {
            state = .failed(error)
        }
    }

    /// Pull-to-refresh. Keeps whatever is on screen if the refresh fails, so a flaky
    /// connection never empties someone's journal in front of them.
    func refresh() async {
        do {
            let page = try await repository.journal(after: nil)
            cursor = page.nextCursor
            state = .resolved(page.items)
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }

    func loadMore() async {
        guard let cursor, !isLoadingMore, let existing = state.value else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await repository.journal(after: cursor)
            self.cursor = page.nextCursor
            state = .resolved(existing + page.items)
        } catch {
            // Failing to extend the list is not worth destroying it. The person keeps what
            // they were reading and can try again by scrolling.
        }
    }

    /// Folds a post created or changed elsewhere into the list without a round trip.
    func upsert(_ post: Post) {
        var items = state.value ?? []
        if let index = items.firstIndex(where: { $0.id == post.id }) {
            items[index] = post
        } else {
            items.insert(post, at: 0)
        }
        state = .resolved(items)
    }

    func remove(id: String) {
        state = .resolved((state.value ?? []).filter { $0.id != id })
    }
}
