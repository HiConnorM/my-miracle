import Foundation
import Observation

/// Somebody's profile, and what they have chosen to share.
///
/// The timeline is filtered on display profile, not authorship, so a post published
/// anonymously never appears here — that is the whole point of publishing it that way
/// (rules 8 and 9).
@MainActor
@Observable
final class ProfileModel {
    private(set) var state: LoadState<ProfileDetail> = .idle
    private(set) var timeline: LoadState<[Post]> = .idle
    private(set) var error: AppError?
    private(set) var isUpdatingFollow = false
    /// Set once the viewer blocks this person, so the screen can close itself.
    private(set) var hasBlocked = false

    let username: String
    private var cursor: String?
    private let repository: any SocialRepository
    private let analytics: any AnalyticsClient

    init(username: String, repository: any SocialRepository, analytics: any AnalyticsClient) {
        self.username = username
        self.repository = repository
        self.analytics = analytics
    }

    var profile: ProfileDetail? { state.value }

    func load() async {
        state = .loading
        do {
            state = .loaded(try await repository.profile(username: username))
            await loadTimeline()
        } catch {
            state = .failed(error)
        }
    }

    private func loadTimeline() async {
        timeline = .loading
        do {
            let page = try await repository.timeline(username: username, cursor: nil)
            cursor = page.nextCursor
            timeline = .resolved(page.items)
        } catch {
            timeline = .failed(error)
        }
    }

    func loadMore() async {
        guard let cursor, let existing = timeline.value else { return }
        do {
            let page = try await repository.timeline(username: username, cursor: cursor)
            self.cursor = page.nextCursor
            timeline = .resolved(existing + page.items)
        } catch {
            // Failing to extend a timeline is not worth destroying it.
        }
    }

    /// Optimistic: following should feel instant, and a failure puts it back.
    func toggleFollow() async {
        guard var profile = state.value, !isUpdatingFollow else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }
        error = nil

        let wasFollowing = profile.isFollowing
        let restore = profile
        profile.isFollowing.toggle()
        state = .loaded(profile)

        do {
            if wasFollowing {
                try await repository.unfollow(username: username)
            } else {
                try await repository.follow(username: username)
            }
            // Following changes what is visible, so the timeline is re-read.
            await loadTimeline()
        } catch {
            state = .loaded(restore)
            self.error = error
        }
    }

    /// Blocks this person.
    ///
    /// A block outranks any follow in either direction, and the server tears both edges
    /// down. From here the person simply becomes invisible, so the screen closes.
    func block() async {
        do {
            try await repository.block(username: username)
            analytics.track(.userBlocked)
            hasBlocked = true
        } catch {
            self.error = error
        }
    }

    func report(category: ReportCategory) async -> Bool {
        do {
            try await repository.report(
                subjectType: "profile",
                subjectID: username,
                category: category,
                details: nil
            )
            analytics.track(.reportSubmitted)
            return true
        } catch {
            self.error = error
            return false
        }
    }

    func dismissError() { error = nil }
}
