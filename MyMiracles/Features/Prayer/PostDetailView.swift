import SwiftUI

/// A prayer or a miracle, and the story attached to it.
struct PostDetailView: View {
    @Environment(\.dependencies) private var dependencies

    let postID: String
    var onChange: (Post) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }

    @State private var model: PostDetailModel?
    @State private var updateText = ""
    @State private var isAnswering = false
    @State private var celebrating: Post?
    @State private var isSaved = false
    @State private var isReporting = false
    @State private var openProfile: String?

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let post = model?.post {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(
                            isSaved ? "Remove from saved" : "Save",
                            systemImage: isSaved ? "bookmark.fill" : "bookmark"
                        ) {
                            Task { await toggleSave(post) }
                        }
                        if !post.isMine {
                            Button("Report", systemImage: MiracleIcon.report) { isReporting = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .navigationDestination(item: $openProfile) { username in
            ProfileView(username: username)
        }
        .sheet(isPresented: $isReporting) {
            if let dependencies, let post = model?.post {
                ReportSheet(subject: "this post") { category in
                    do {
                        try await HTTPSocialRepository(client: dependencies.api).report(
                            subjectType: "post",
                            subjectID: post.id,
                            category: category,
                            details: nil
                        )
                        dependencies.analytics.track(.reportSubmitted)
                        return true
                    } catch {
                        return false
                    }
                }
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = PostDetailModel(
                postID: postID,
                repository: HTTPPostRepository(client: dependencies.api),
                analytics: dependencies.analytics
            )
            model = created
            await created.load()
            if let post = created.post {
                isSaved = post.isSaved
                onChange(post)
            }
        }
        .sheet(isPresented: $isAnswering) {
            if let post = model?.post {
                AnswerComposerView(prayer: post) { draft, key in
                    await model?.markAnswered(with: draft, idempotencyKey: key)
                    isAnswering = false
                    if let created = model?.justAnswered {
                        celebrating = created
                        model?.clearJustAnswered()
                    }
                    if let updated = model?.post { onChange(updated) }
                }
            }
        }
        .sheet(item: $celebrating) { miracle in
            AnsweredCelebrationView(miracle: miracle)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.state {
            case .idle, .loading:
                ProgressView().controlSize(.large).accessibilityLabel("Loading")
            case .empty, .failed(_):
                ErrorState(error: model.state.error ?? AppError(kind: .notFound)) {
                    Task { await model.load() }
                }
            case .loaded(let post):
                detail(post, model: model)
            }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func detail(_ post: Post, model: PostDetailModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                header(post)

                Text(post.body)
                    .font(post.type == .miracle
                          ? MiracleFont.reflective(.title3)
                          : MiracleFont.interface(.body))
                    .foregroundStyle(MiracleColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let link = post.link {
                    linkCard(link, from: post)
                }

                if post.acceptsPrayer && !post.isMine {
                    PrayerButton(
                        hasPrayed: post.hasPrayed,
                        count: post.prayerResponseCount,
                        isWorking: model.isPraying
                    ) {
                        Task { await model.togglePrayer() }
                    }
                }

                if post.prayerResponseCount > 0 {
                    Text(post.prayerResponseCount == 1
                         ? "1 person has prayed for this."
                         : "\(post.prayerResponseCount) people have prayed for this.")
                        .font(MiracleFont.interface(.subheadline))
                        .foregroundStyle(MiracleColor.prayerBlue)
                }

                if post.type == .prayer {
                    updatesSection(post, model: model)
                }

                if post.canBeAnswered {
                    answerButton
                }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }

                if !post.isMine {
                    CommentsSection(
                        postID: post.id,
                        canComment: post.acceptsPrayer,
                        onOpenProfile: { openProfile = $0 }
                    )
                } else {
                    CommentsSection(postID: post.id, canComment: false) { openProfile = $0 }
                }

                if post.isMine {
                    deleteButton(post)
                }
            }
            .padding(MiracleSpacing.comfortable)
        }
    }

    private func header(_ post: Post) -> some View {
        HStack(spacing: MiracleSpacing.small) {
            Image(systemName: post.type.symbol)
                .foregroundStyle(post.type == .miracle ? MiracleColor.haloGold : MiracleColor.sage)

            Text(post.isAnsweredPrayer ? "Answered prayer" : post.type.title)
                .font(MiracleFont.interface(.subheadline, weight: .medium))
                .foregroundStyle(MiracleColor.inkSecondary)

            Spacer()

            Text(post.createdAt, format: .dateTime.month(.wide).day().year())
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The other end of the story. Tapping it moves between the prayer and what it became.
    private func linkCard(_ link: PostLink, from post: Post) -> some View {
        NavigationLink(value: link.id) {
            VStack(alignment: .leading, spacing: MiracleSpacing.small) {
                HStack(spacing: MiracleSpacing.small) {
                    Image(systemName: link.type == .miracle ? "sparkle" : "hands.and.sparkles")
                        .foregroundStyle(MiracleColor.haloGold)
                    Text(link.type == .miracle ? "This prayer was answered" : "This began as a prayer")
                        .font(MiracleFont.interface(.subheadline, weight: .medium))
                        .foregroundStyle(MiracleColor.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(MiracleColor.inkSecondary)
                }
                Text(link.excerpt)
                    .font(MiracleFont.reflective(.callout))
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(MiracleSpacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MiracleColor.dawnRose.opacity(0.25), in: .rect(cornerRadius: MiracleRadius.card))
        }
        .buttonStyle(.plain)
        .navigationDestination(for: String.self) { id in
            PostDetailView(postID: id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the linked \(link.type.title.lowercased())")
    }

    private func updatesSection(_ post: Post, model: PostDetailModel) -> some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            if !model.updates.isEmpty {
                Text("Updates")
                    .font(MiracleFont.interface(.subheadline, weight: .medium))
                    .foregroundStyle(MiracleColor.ink)

                ForEach(model.updates) { update in
                    VStack(alignment: .leading, spacing: MiracleSpacing.tight) {
                        Text(update.createdAt, format: .dateTime.month(.abbreviated).day())
                            .font(MiracleFont.interface(.caption))
                            .foregroundStyle(MiracleColor.inkSecondary)
                        Text(update.body)
                            .font(MiracleFont.interface(.callout))
                            .foregroundStyle(MiracleColor.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MiracleSpacing.regular)
                    .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
                    .accessibilityElement(children: .combine)
                }
            }

            if post.isMine && post.status == .active {
                HStack(spacing: MiracleSpacing.small) {
                    TextField("Add an update…", text: $updateText, axis: .vertical)
                        .font(MiracleFont.interface(.callout))
                        .padding(MiracleSpacing.medium)
                        .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
                        .accessibilityLabel("Add an update to this prayer")

                    Button {
                        let text = updateText
                        updateText = ""
                        Task { await model.addUpdate(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(MiracleColor.prayerBlue)
                    }
                    .disabled(updateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Post update")
                }
            }
        }
    }

    private var answerButton: some View {
        Button {
            isAnswering = true
        } label: {
            HStack(spacing: MiracleSpacing.small) {
                Image(systemName: "sparkle")
                Text("Mark as answered")
                    .font(MiracleFont.interface(.headline))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.regular)
        }
        .background(MiracleColor.haloGoldSurface, in: .rect(cornerRadius: MiracleRadius.pill))
        .foregroundStyle(MiracleColor.inkOnAccent)
        .accessibilityHint("Turns this prayer into a miracle in your journal")
    }

    /// Saving is private: nothing is sent to the author, and no count changes.
    private func toggleSave(_ post: Post) async {
        guard let dependencies else { return }
        let repository = HTTPSocialRepository(client: dependencies.api)
        let wasSaved = isSaved
        isSaved.toggle()

        do {
            if wasSaved {
                try await repository.unsave(postID: post.id)
            } else {
                try await repository.save(postID: post.id)
            }
        } catch {
            isSaved = wasSaved
        }
    }

    private func deleteButton(_ post: Post) -> some View {
        Button("Delete", role: .destructive) {
            Task {
                guard let dependencies else { return }
                try? await HTTPPostRepository(client: dependencies.api).delete(id: post.id)
                onDelete(post.id)
            }
        }
        .font(MiracleFont.interface(.footnote))
        .frame(maxWidth: .infinity)
        .padding(.top, MiracleSpacing.comfortable)
    }
}
