import SwiftUI
import Observation

/// Things you saved.
///
/// A private list, and only that. The author is never told, there is no count, and saving
/// does not influence what surfaces on Home — it is a bookmark so someone can keep a prayer
/// in mind, not a way for a post to accumulate a score (rule 13).
///
/// The list is re-checked against visibility on every load, so a post that becomes private,
/// is deleted, or belongs to someone now blocked simply drops out. A bookmark is a pointer,
/// not a copy.
@MainActor
@Observable
final class SavedModel {
    private(set) var state: LoadState<[Post]> = .idle
    private var cursor: String?
    private let repository: any SocialRepository

    init(repository: any SocialRepository) {
        self.repository = repository
    }

    func load() async {
        state = .loading
        do {
            let page = try await repository.saved(cursor: nil)
            cursor = page.nextCursor
            state = .resolved(page.items)
        } catch {
            state = .failed(error)
        }
    }

    func loadMore() async {
        guard let cursor, let existing = state.value else { return }
        do {
            let page = try await repository.saved(cursor: cursor)
            self.cursor = page.nextCursor
            state = .resolved(existing + page.items)
        } catch {
            // Failing to extend the list is not worth destroying it.
        }
    }

    func unsave(_ post: Post) async {
        guard let existing = state.value else { return }
        let restore = existing
        state = .resolved(existing.filter { $0.id != post.id })

        do {
            try await repository.unsave(postID: post.id)
        } catch {
            state = .resolved(restore)
        }
    }
}

struct SavedView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var model: SavedModel?
    @State private var selected: String?

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()
            content
        }
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { id in
            PostDetailView(postID: id)
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = SavedModel(repository: HTTPSocialRepository(client: dependencies.api))
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
            case .empty:
                EmptyState(
                    symbol: "bookmark",
                    title: "Nothing saved",
                    message: "Save a prayer to keep it in mind. Nobody is told, and nothing is counted."
                )
            case .failed(let error):
                ErrorState(error: error) { Task { await model.load() } }
            case .loaded(let posts):
                ScrollView {
                    LazyVStack(spacing: MiracleSpacing.medium) {
                        ForEach(posts) { post in
                            Button { selected = post.id } label: { JournalEntryCard(post: post) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Remove", role: .destructive) {
                                        Task { await model.unsave(post) }
                                    }
                                }
                                .onAppear {
                                    if post.id == posts.last?.id {
                                        Task { await model.loadMore() }
                                    }
                                }
                        }
                    }
                    .padding(MiracleSpacing.regular)
                }
                .refreshable { await model.load() }
            }
        } else {
            LoadingState()
        }
    }
}

#if DEBUG
#Preview("Saved") {
    NavigationStack {
        SavedView().environment(\.dependencies, .preview())
    }
}
#endif
