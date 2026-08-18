import SwiftUI

/// Finding people.
///
/// A search box and nothing else. There is no ranked list of accounts to follow, nothing
/// trending, and no "people you may know" — the screen is empty until someone asks it a
/// question, which is the difference between a directory and a growth mechanic.
struct DiscoverView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var model: DiscoverModel?
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()
                content
            }
            .navigationTitle("Find people")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $selected) { username in
                ProfileView(username: username)
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            model = DiscoverModel(
                repository: HTTPSocialRepository(client: dependencies.api)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            @Bindable var model = model

            Group {
                switch model.state {
                case .idle:
                    resting
                case .loading:
                    LoadingState(label: "Searching")
                case .empty:
                    EmptyState(
                        symbol: "person.slash",
                        title: "Nobody by that name",
                        message: "Try a different name, or check the spelling."
                    )
                case .failed(let error):
                    ErrorState(error: error) { Task { await model.search() } }
                case .loaded(let people):
                    results(people, model: model)
                }
            }
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by name"
            )
            .onSubmit(of: .search) { Task { await model.search() } }
            .onChange(of: model.query) { _, new in
                if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.clear()
                }
            }
        } else {
            LoadingState()
        }
    }

    /// The default state. Deliberately not a feed of suggestions.
    private var resting: some View {
        EmptyState(
            symbol: "magnifyingglass",
            title: "Find someone",
            message: "Search for a person by their name or username. We don't suggest people to follow — you decide who you carry."
        )
        .frame(maxHeight: .infinity)
    }

    private func results(_ people: [PersonSummary], model: DiscoverModel) -> some View {
        ScrollView {
            LazyVStack(spacing: MiracleSpacing.medium) {
                ForEach(people) { person in
                    PersonRow(person: person) {
                        selected = person.username
                    } onToggleFollow: {
                        Task { await model.toggleFollow(person) }
                    }
                }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }
            }
            .padding(MiracleSpacing.regular)
        }
    }
}

/// One person in a list. Carries no follower count, because there is none to carry.
struct PersonRow: View {
    let person: PersonSummary
    let onOpen: () -> Void
    let onToggleFollow: () -> Void

    var body: some View {
        MiracleCard {
            HStack(spacing: MiracleSpacing.regular) {
                Button(action: onOpen) {
                    HStack(spacing: MiracleSpacing.regular) {
                        ProfileAvatar(profile: person.displayProfile)

                        VStack(alignment: .leading, spacing: MiracleSpacing.hair) {
                            Text(person.displayName)
                                .font(MiracleFont.interface(.body, weight: .medium))
                                .foregroundStyle(MiracleColor.ink)
                            Text("@\(person.username)")
                                .font(MiracleFont.interface(.caption))
                                .foregroundStyle(MiracleColor.inkSecondary)
                            if let bio = person.bio, !bio.isEmpty {
                                Text(bio)
                                    .font(MiracleFont.interface(.caption))
                                    .foregroundStyle(MiracleColor.inkSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .multilineTextAlignment(.leading)

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                FollowButton(isFollowing: person.isFollowing, action: onToggleFollow)
            }
        }
    }
}

struct FollowButton: View {
    let isFollowing: Bool
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isFollowing ? "Following" : "Follow")
                .font(MiracleFont.interface(.footnote, weight: .medium))
                .padding(.horizontal, MiracleSpacing.regular)
                .padding(.vertical, MiracleSpacing.small)
        }
        .buttonStyle(.plain)
        .background(
            isFollowing ? MiracleColor.canvasElevated : MiracleColor.ink,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(isFollowing ? MiracleColor.ink : MiracleColor.canvas)
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.pill)
                .stroke(isFollowing ? MiracleColor.separator : .clear, lineWidth: 1)
        )
        .disabled(isWorking)
        .accessibilityLabel(isFollowing ? "Following" : "Follow")
        .accessibilityHint(isFollowing ? "Double tap to stop following" : "Double tap to follow")
    }
}

#if DEBUG
#Preview("Discover") {
    DiscoverView().environment(\.dependencies, .preview())
}
#endif
