import SwiftUI

/// The app once someone is signed in.
///
/// Three tabs and no more. Home is where a session starts and ends; the Journal is the
/// durable thing they came for; You holds the account, including deletion.
struct SignedInShell: View {
    let profile: ProfileResponse

    @State private var selection: TabSelection = .home
    @State private var composing: PostType?
    @State private var homePath: [String] = []
    /// Bumped after a post is created so Home refetches rather than showing stale content.
    @State private var homeReloadToken = UUID()

    /// Named to avoid colliding with SwiftUI's own `Tab`.
    enum TabSelection: Hashable { case home, discover, journal, you }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: TabSelection.home) {
                NavigationStack(path: $homePath) {
                    HomeView(
                        profile: profile,
                        onCompose: { composing = $0 },
                        onOpen: { homePath.append($0) }
                    )
                    .navigationDestination(for: String.self) { id in
                        PostDetailView(postID: id)
                    }
                }
                .id(homeReloadToken)
            }

            Tab("Find people", systemImage: "magnifyingglass", value: TabSelection.discover) {
                DiscoverView()
            }

            Tab("Journal", systemImage: MiracleIcon.journal, value: TabSelection.journal) {
                JournalView()
            }

            Tab("You", systemImage: "person", value: TabSelection.you) {
                SettingsView(profile: profile)
            }
        }
        .tint(MiracleColor.prayerBlue)
        .sheet(item: $composing) { type in
            ComposerView(type: type) { created in
                composing = nil
                // Land on the thing that was just written, wherever it belongs.
                if created.type == .miracle || created.type == .gratitude {
                    selection = .journal
                } else {
                    homeReloadToken = UUID()
                    homePath = [created.id]
                    selection = .home
                }
            }
        }
    }
}

#if DEBUG
#Preview("Shell") {
    SignedInShell(profile: ProfileResponse(username: "connor", displayName: "Connor"))
        .environment(\.dependencies, .preview())
        .environment(AuthenticationModel.preview())
}
#endif
