import SwiftUI

/// The journal — and, until Phase 6 builds Home, the app's main screen.
struct JournalView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var model: JournalModel?
    @State private var composing: PostType?
    @State private var selected: Post?

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()
                content
            }
            .navigationTitle("My Miracles")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Record a miracle", systemImage: MiracleIcon.miracle) { composing = .miracle }
                        Button("Ask for prayer", systemImage: MiracleIcon.prayer) { composing = .prayer }
                        Button("Note something you're grateful for", systemImage: MiracleIcon.gratitude) {
                            composing = .gratitude
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(MiracleColor.haloGold)
                    }
                    .accessibilityLabel("Add to your journal")
                }
            }
            .navigationDestination(item: $selected) { post in
                PostDetailView(postID: post.id) { updated in
                    model?.upsert(updated)
                } onDelete: { id in
                    model?.remove(id: id)
                }
            }
            .sheet(item: $composing) { type in
                ComposerView(type: type) { created in
                    model?.upsert(created)
                    composing = nil
                    selected = created
                }
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = JournalModel(
                repository: HTTPPostRepository(client: dependencies.api),
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
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Loading your journal")

            case .empty:
                EmptyState(
                    symbol: MiracleIcon.journal,
                    title: "Your journal is empty",
                    message: "Record something you want to remember, or ask for prayer about something happening now.",
                    action: (title: "Record a miracle", perform: { composing = .miracle })
                )

            case .failed(let error):
                ErrorState(error: error) {
                    Task { await model.load() }
                }

            case .loaded(let posts):
                list(posts, model: model)
            }
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private func list(_ posts: [Post], model: JournalModel) -> some View {
        ScrollView {
            LazyVStack(spacing: MiracleSpacing.medium) {
                ForEach(posts) { post in
                    Button { selected = post } label: { JournalEntryCard(post: post) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if post.id == posts.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                }

                if model.isLoadingMore {
                    ProgressView().padding(MiracleSpacing.regular)
                }
            }
            .padding(MiracleSpacing.regular)
        }
        .refreshable { await model.refresh() }
    }
}

extension PostType: Identifiable {
    public var id: String { rawValue }
}
