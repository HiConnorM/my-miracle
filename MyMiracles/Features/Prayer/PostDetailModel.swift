import Foundation
import Observation

/// One post, and everything that has happened to it.
///
/// Handles prayers and miracles alike — they are the same object with a different type, and
/// the whole point of the product is that one becomes the other.
@MainActor
@Observable
final class PostDetailModel {
    private(set) var state: LoadState<Post> = .idle
    private(set) var updates: [PostUpdate] = []
    private(set) var error: AppError?
    private(set) var isPraying = false
    private(set) var isAnswering = false

    /// Set when a prayer becomes a miracle, so the view can celebrate and navigate.
    private(set) var justAnswered: Post?

    let postID: String
    private let repository: any PostRepository
    private let analytics: any AnalyticsClient

    init(postID: String, repository: any PostRepository, analytics: any AnalyticsClient) {
        self.postID = postID
        self.repository = repository
        self.analytics = analytics
    }

    var post: Post? { state.value }

    func load() async {
        state = .loading
        do {
            let post = try await repository.post(id: postID)
            state = .loaded(post)
            if post.type == .prayer {
                updates = (try? await repository.updates(for: postID)) ?? []
            }
        } catch {
            state = .failed(error)
        }
    }

    /// "I prayed."
    ///
    /// Optimistic: the count moves the instant it is tapped, because this is a small act of
    /// kindness and it should feel immediate. A failure puts it back exactly as it was.
    func togglePrayer() async {
        guard var current = post, !isPraying else { return }
        isPraying = true
        error = nil
        defer { isPraying = false }

        let wasPrayed = current.hasPrayed
        let restore = current

        current.hasPrayed.toggle()
        current.prayerResponseCount += wasPrayed ? -1 : 1
        state = .loaded(current)

        do {
            let result = wasPrayed
                ? try await repository.withdrawPrayer(for: postID)
                : try await repository.pray(for: postID)

            var settled = current
            settled.hasPrayed = result.hasPrayed
            settled.prayerResponseCount = result.prayerResponseCount
            state = .loaded(settled)

            if !wasPrayed { analytics.track(.prayerResponseCreated) }
        } catch {
            state = .loaded(restore)
            self.error = error
        }
    }

    func addUpdate(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var current = post else { return }
        error = nil

        do {
            let update = try await repository.addUpdate(to: postID, body: trimmed)
            updates.append(update)
            current.updateCount += 1
            state = .loaded(current)
            analytics.track(.prayerUpdatePosted)
        } catch {
            self.error = error
        }
    }

    /// Turns this prayer into a miracle.
    ///
    /// One call. The server does it as a single transaction — creating the miracle, linking
    /// it, marking the prayer answered and notifying everyone who prayed either all happen
    /// or none of them do (rule 10). There is deliberately no version of this that writes
    /// the pieces separately from here.
    func markAnswered(with miracle: PostDraft, idempotencyKey: String) async {
        guard let current = post, current.canBeAnswered, !isAnswering else { return }
        isAnswering = true
        error = nil
        defer { isAnswering = false }

        do {
            let created = try await repository.markAnswered(
                prayerID: postID,
                miracle: miracle,
                idempotencyKey: idempotencyKey
            )
            justAnswered = created
            analytics.track(
                .prayerMarkedAnswered(daysOpen: .init(days: daysOpen(from: current.createdAt)))
            )
            // Re-read so the prayer shows as answered and carries its link to the miracle.
            await load()
        } catch {
            self.error = error
        }
    }

    func clearJustAnswered() { justAnswered = nil }
    func dismissError() { error = nil }

    private func daysOpen(from created: Date, now: Date = Date()) -> Int {
        max(Calendar.current.dateComponents([.day], from: created, to: now).day ?? 0, 0)
    }
}
