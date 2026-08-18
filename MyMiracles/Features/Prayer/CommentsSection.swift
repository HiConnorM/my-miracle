import Foundation
import Observation
import SwiftUI

/// Encouragement on a post.
///
/// The vocabulary is deliberately small — this is somewhere to say "I'm thinking of you",
/// not a comment thread to win. There are no reactions, no replies to replies, and no
/// upvotes (docs/product-spec.md).
@MainActor
@Observable
final class CommentsModel {
    private(set) var state: LoadState<[Encouragement]> = .idle
    private(set) var isSending = false
    private(set) var error: AppError?

    let postID: String
    private let repository: any SocialRepository

    init(postID: String, repository: any SocialRepository) {
        self.postID = postID
        self.repository = repository
    }

    func load() async {
        state = .loading
        do {
            state = .resolved(try await repository.comments(for: postID))
        } catch {
            state = .failed(error)
        }
    }

    func add(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        error = nil

        do {
            let comment = try await repository.addComment(to: postID, body: trimmed)
            state = .resolved((state.value ?? []) + [comment])
        } catch {
            self.error = error
        }
    }

    func delete(_ comment: Encouragement) async {
        guard let existing = state.value else { return }
        let restore = existing
        state = .resolved(existing.filter { $0.id != comment.id })

        do {
            try await repository.deleteComment(id: comment.id)
        } catch {
            state = .resolved(restore)
            self.error = error
        }
    }

    func dismissError() { error = nil }
}

struct CommentsSection: View {
    @Environment(\.dependencies) private var dependencies

    let postID: String
    /// Whether the post accepts new encouragement. A private or removed post does not.
    let canComment: Bool
    var onOpenProfile: (String) -> Void = { _ in }

    @State private var model: CommentsModel?
    @State private var draft = ""
    @FocusState private var isWriting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            if let model {
                switch model.state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .empty:
                    if canComment {
                        Text("Be the first to say something kind.")
                            .font(MiracleFont.interface(.footnote))
                            .foregroundStyle(MiracleColor.inkSecondary)
                    }
                case .failed(let error):
                    ErrorNotice(error: error)
                case .loaded(let comments):
                    SectionHeader(title: "Encouragement")
                    ForEach(comments) { comment in
                        row(comment, model: model)
                    }
                }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }

                if canComment {
                    composer(model)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = CommentsModel(
                postID: postID,
                repository: HTTPSocialRepository(client: dependencies.api)
            )
            model = created
            await created.load()
        }
    }

    private func row(_ comment: Encouragement, model: CommentsModel) -> some View {
        MiracleCard {
            VStack(alignment: .leading, spacing: MiracleSpacing.small) {
                HStack(spacing: MiracleSpacing.small) {
                    if let author = comment.author {
                        Button { onOpenProfile(author.username) } label: {
                            HStack(spacing: MiracleSpacing.small) {
                                ProfileAvatar(profile: author, size: 24)
                                Text(author.displayName)
                                    .font(MiracleFont.interface(.caption, weight: .medium))
                                    .foregroundStyle(MiracleColor.ink)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Text(comment.createdAt, format: .dateTime.month(.abbreviated).day())
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(MiracleColor.inkSecondary)

                    if comment.isMine {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.delete(comment) }
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(MiracleColor.inkSecondary)
                        .accessibilityLabel("Delete your comment")
                    }
                }

                Text(comment.body)
                    .font(MiracleFont.interface(.callout))
                    .foregroundStyle(MiracleColor.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func composer(_ model: CommentsModel) -> some View {
        HStack(spacing: MiracleSpacing.small) {
            TextField("Say something kind…", text: $draft, axis: .vertical)
                .font(MiracleFont.interface(.callout))
                .padding(MiracleSpacing.medium)
                .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
                .focused($isWriting)
                .accessibilityLabel("Write encouragement")

            Button {
                let body = draft
                draft = ""
                isWriting = false
                Task { await model.add(body) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(MiracleColor.prayerBlue)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            .accessibilityLabel("Send encouragement")
        }
    }
}
