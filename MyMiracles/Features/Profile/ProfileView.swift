import SwiftUI

/// Somebody's profile.
///
/// Shows who they are and what they have chosen to share. It shows **no follower count and
/// no post count** — a prayer request is not more deserving because the person asking has
/// an audience (rule 13). Posts they published anonymously are not here, which is the whole
/// point of publishing them that way.
struct ProfileView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    let username: String

    @State private var model: ProfileModel?
    @State private var selected: String?
    @State private var isReporting = false
    @State private var isConfirmingBlock = false
    @State private var hasReported = false

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()
            content
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let model, model.profile?.isMe == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Report", systemImage: MiracleIcon.report) { isReporting = true }
                        Button("Block", systemImage: "hand.raised", role: .destructive) {
                            isConfirmingBlock = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .disabled(model.profile == nil)
                }
            }
        }
        .navigationDestination(item: $selected) { id in
            PostDetailView(postID: id)
        }
        .confirmationDialog("Block @\(username)?", isPresented: $isConfirmingBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task {
                    await model?.block()
                    if model?.hasBlocked == true { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and neither of you will appear in the other's searches. They aren't told.")
        }
        .sheet(isPresented: $isReporting) {
            if let model {
                ReportSheet(subject: "@\(username)") { category in
                    hasReported = await model.report(category: category)
                    return hasReported
                }
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = ProfileModel(
                username: username,
                repository: HTTPSocialRepository(client: dependencies.api),
                analytics: dependencies.analytics
            )
            model = created
            await created.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.state {
            case .idle, .loading:
                LoadingState()
            case .empty, .failed:
                ErrorState(error: model.state.error ?? AppError(kind: .notFound)) {
                    Task { await model.load() }
                }
            case .loaded(let profile):
                body(for: profile, model: model)
            }
        } else {
            LoadingState()
        }
    }

    private func body(for profile: ProfileDetail, model: ProfileModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                header(profile, model: model)

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }

                switch model.timeline {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(MiracleSpacing.comfortable)
                case .empty:
                    EmptyState(
                        symbol: MiracleIcon.journal,
                        title: profile.isMe ? "Nothing shared yet" : "Nothing shared with you",
                        message: profile.isMe
                            ? "Anything you share publicly will appear here."
                            : "When they share something, it will appear here."
                    )
                case .failed(let error):
                    ErrorState(error: error)
                case .loaded(let posts):
                    LazyVStack(spacing: MiracleSpacing.medium) {
                        ForEach(posts) { post in
                            Button { selected = post.id } label: { JournalEntryCard(post: post) }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if post.id == posts.last?.id {
                                        Task { await model.loadMore() }
                                    }
                                }
                        }
                    }
                }
            }
            .padding(MiracleSpacing.regular)
        }
    }

    private func header(_ profile: ProfileDetail, model: ProfileModel) -> some View {
        VStack(spacing: MiracleSpacing.medium) {
            ProfileAvatar(profile: profile.displayProfile, size: 72)

            Text(profile.displayName)
                .font(MiracleFont.reflective(.title2))
                .foregroundStyle(MiracleColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("@\(profile.username)")
                .font(MiracleFont.interface(.subheadline))
                .foregroundStyle(MiracleColor.inkSecondary)

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(MiracleFont.interface(.callout))
                    .foregroundStyle(MiracleColor.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Here since \(profile.createdAt, format: .dateTime.month(.wide).year())")
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)

            if !profile.isMe {
                FollowButton(
                    isFollowing: profile.isFollowing,
                    isWorking: model.isUpdatingFollow
                ) {
                    Task { await model.toggleFollow() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MiracleSpacing.regular)
    }
}

/// Reporting something.
///
/// Plain categories in plain words, and no promise about what happens next — a reporter
/// learning that their report was the tenth would be a way to probe moderation state
/// (docs/product-spec.md).
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let subject: String
    let onReport: (ReportCategory) async -> Bool

    @State private var isSending = false
    @State private var hasSent = false

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()

                if hasSent {
                    VStack(spacing: MiracleSpacing.regular) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(MiracleColor.sage)
                            .accessibilityHidden(true)
                        Text("Thank you")
                            .font(MiracleFont.reflective(.title3))
                            .foregroundStyle(MiracleColor.ink)
                        Text("Someone will look at this.")
                            .font(MiracleFont.interface(.callout))
                            .foregroundStyle(MiracleColor.inkSecondary)
                    }
                    .padding(MiracleSpacing.generous)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
                            Text("What's wrong with \(subject)?")
                                .font(MiracleFont.interface(.subheadline))
                                .foregroundStyle(MiracleColor.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(ReportCategory.allCases) { category in
                                Button {
                                    isSending = true
                                    Task {
                                        hasSent = await onReport(category)
                                        isSending = false
                                    }
                                } label: {
                                    HStack {
                                        Text(category.title)
                                            .font(MiracleFont.interface(.body))
                                            .foregroundStyle(MiracleColor.ink)
                                            .multilineTextAlignment(.leading)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(MiracleColor.inkSecondary)
                                    }
                                    .padding(MiracleSpacing.regular)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    MiracleColor.canvasElevated,
                                    in: .rect(cornerRadius: MiracleRadius.card)
                                )
                                .disabled(isSending)
                            }
                        }
                        .padding(MiracleSpacing.regular)
                    }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasSent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Profile") {
    NavigationStack {
        ProfileView(username: "gabi").environment(\.dependencies, .preview())
    }
}
#endif
