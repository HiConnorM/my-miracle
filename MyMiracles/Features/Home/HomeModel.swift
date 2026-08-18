import Foundation
import Observation

/// What Home shows, in one request.
nonisolated struct HomeFeed: Codable, Sendable, Equatable {
    var prayerRequests: [Post]
    /// How many more people are waiting beyond this batch. Drives an explicit "see more",
    /// never an automatic load.
    var remainingPrayerRequests: Int
    var recentMiracles: [Post]
    /// Something the viewer wrote on this date in an earlier year.
    var memory: Post?

    var isEmpty: Bool {
        prayerRequests.isEmpty && recentMiracles.isEmpty && memory == nil
    }

    /// True when there was something to do and it is done — the difference between a quiet
    /// morning and a finished one.
    var isCaughtUp: Bool {
        prayerRequests.isEmpty && remainingPrayerRequests == 0
    }
}

nonisolated protocol HomeRepository: Sendable {
    func home() async throws(AppError) -> HomeFeed
}

nonisolated struct HTTPHomeRepository: HomeRepository {
    private let client: any APIClient

    init(client: any APIClient) {
        self.client = client
    }

    func home() async throws(AppError) -> HomeFeed {
        try await client.send(APIRequest<HomeFeed>.get("/v1/home"))
    }
}

/// Home: a finite session with an ending.
///
/// The single most important behaviour here is that the prayer set **runs out**. Someone
/// prays for the people in front of them, the list empties, and the screen says so. There
/// is no automatic next page — "see more" is a deliberate choice, taken by someone who
/// wants to keep going (docs/product-spec.md).
@MainActor
@Observable
final class HomeModel {
    private(set) var state: LoadState<HomeFeed> = .idle
    private(set) var error: AppError?
    private(set) var prayingFor: Set<String> = []
    /// Set once the day's batch is finished, so the view can acknowledge it rather than
    /// silently showing nothing.
    private(set) var hasJustFinished = false

    private let repository: any HomeRepository
    private let posts: any PostRepository
    private let analytics: any AnalyticsClient

    init(
        repository: any HomeRepository,
        posts: any PostRepository,
        analytics: any AnalyticsClient
    ) {
        self.repository = repository
        self.posts = posts
        self.analytics = analytics
    }

    var feed: HomeFeed? { state.value }

    func load() async {
        guard !state.isLoading else { return }
        state = .loading
        await fetch(resettingFinishedFlag: true)
    }

    func refresh() async {
        await fetch(resettingFinishedFlag: true)
    }

    /// Loads the next batch, only when someone asks for it.
    func seeMore() async {
        await fetch(resettingFinishedFlag: false)
    }

    private func fetch(resettingFinishedFlag: Bool) async {
        do {
            let feed = try await repository.home()
            state = .loaded(feed)
            if resettingFinishedFlag { hasJustFinished = false }
        } catch {
            // A failed refresh keeps whatever is on screen. Emptying someone's morning
            // because the network blinked would be worse than showing stale content.
            if state.value == nil { state = .failed(error) } else { self.error = error }
        }
    }

    /// Prays for someone from Home.
    ///
    /// Optimistic, and the person leaves the list once carried — that is what makes the set
    /// finishable. When the last one goes, `hasJustFinished` turns on so the view can say
    /// so instead of just going blank.
    func pray(for post: Post) async {
        guard var feed = state.value, !prayingFor.contains(post.id) else { return }
        prayingFor.insert(post.id)
        defer { prayingFor.remove(post.id) }
        error = nil

        let restore = feed
        feed.prayerRequests.removeAll { $0.id == post.id }
        state = .loaded(feed)

        do {
            _ = try await posts.pray(for: post.id)
            analytics.track(.prayerResponseCreated)

            if feed.prayerRequests.isEmpty && feed.remainingPrayerRequests == 0 {
                hasJustFinished = true
            }
        } catch {
            state = .loaded(restore)
            self.error = error
        }
    }

    func dismissError() { error = nil }

    /// Folds in a post created elsewhere, so Home reflects it without a round trip.
    func upsertMiracle(_ post: Post) {
        guard var feed = state.value, post.type == .miracle, !post.isMine else { return }
        feed.recentMiracles.insert(post, at: 0)
        state = .loaded(feed)
    }
}
