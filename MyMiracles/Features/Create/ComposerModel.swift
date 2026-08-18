import Foundation
import Observation

/// Writing something down.
///
/// The draft defaults to **private** (docs/product-spec.md — the journal starts private,
/// and sharing is always an explicit act). Visibility is chosen before posting, never
/// after.
@MainActor
@Observable
final class ComposerModel {
    var draft: PostDraft
    private(set) var isSaving = false
    private(set) var error: AppError?
    private(set) var saved: Post?

    /// Generated once per composer, not per attempt. A retry after a dropped connection
    /// reuses it, so the server replays the original result instead of writing a second
    /// copy of something someone only meant to say once.
    private let idempotencyKey = UUID().uuidString

    private let repository: any PostRepository
    private let analytics: any AnalyticsClient

    init(
        repository: any PostRepository,
        analytics: any AnalyticsClient,
        type: PostType = .prayer
    ) {
        self.repository = repository
        self.analytics = analytics
        self.draft = PostDraft(type: type)
    }

    var canSave: Bool { draft.isSendable && !isSaving }

    var remainingCharacters: Int {
        5000 - draft.body.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    func setVisibility(_ visibility: PostVisibility) {
        draft.visibility = visibility
        // Anonymity has no meaning without an audience, and the server rejects the pair.
        if !visibility.allowsAnonymity { draft.anonymous = false }
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            let post = try await repository.create(draft, idempotencyKey: idempotencyKey)
            saved = post
            track(post)
        } catch {
            self.error = error
        }
    }

    func dismissError() { error = nil }

    /// Records the shape of what happened — type, visibility, anonymity — and never a word
    /// of what was written (rule 7).
    private func track(_ post: Post) {
        let visibility: AnalyticsEvent.Visibility = switch post.visibility {
        case .privateOnly: .privateOnly
        case .followers: .followers
        case .publicFeed: .publicFeed
        }

        switch post.type {
        case .prayer:
            analytics.track(.prayerCreated(visibility: visibility, anonymous: post.isAnonymous))
        case .miracle, .testimony:
            analytics.track(.miracleCreated(visibility: visibility))
        case .gratitude:
            analytics.track(.gratitudeCreated(visibility: visibility))
        }
    }
}
