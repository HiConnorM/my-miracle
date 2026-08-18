import SwiftUI

/// Home.
///
/// Sections in a fixed order: a greeting, the two things you might want to write, a small
/// set of people who could use prayer, a few miracles from around you, and — if there is
/// one — something you wrote on this day in an earlier year.
///
/// **There is no infinite scroll.** The prayer set is bounded and runs out, and the screen
/// says so when it does. "See more" exists, but someone has to ask for it.
struct HomeView: View {
    @Environment(\.dependencies) private var dependencies

    let profile: ProfileResponse
    var onCompose: (PostType) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    @State private var model: HomeModel?

    var body: some View {
        ZStack {
            MiracleColor.canvas.ignoresSafeArea()
            content
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = HomeModel(
                repository: HTTPHomeRepository(client: dependencies.api),
                posts: HTTPPostRepository(client: dependencies.api),
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
                LoadingState(label: "Loading your morning")
            case .failed(let error):
                ErrorState(error: error) { Task { await model.load() } }
            case .empty, .loaded:
                sections(model)
            }
        } else {
            LoadingState()
        }
    }

    private func sections(_ model: HomeModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MiracleSpacing.generous) {
                greeting

                compose

                if let feed = model.feed {
                    prayerSection(feed, model: model)

                    if !feed.recentMiracles.isEmpty {
                        miracleSection(feed)
                    }

                    if let memory = feed.memory {
                        memorySection(memory)
                    }
                }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }
            }
            .padding(MiracleSpacing.regular)
            .padding(.bottom, MiracleSpacing.sanctuary)
        }
        .refreshable { await model.refresh() }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.tight) {
            Text(Self.salutation(for: Date()))
                .font(MiracleFont.interface(.subheadline))
                .foregroundStyle(MiracleColor.inkSecondary)
            Text(profile.displayName)
                .font(MiracleFont.reflective(.largeTitle))
                .foregroundStyle(MiracleColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The two things someone might have come to do. Both are one tap from the top.
    private var compose: some View {
        VStack(spacing: MiracleSpacing.medium) {
            composeRow(
                symbol: MiracleIcon.miracle,
                tint: MiracleColor.haloGold,
                title: "Remember something good",
                subtitle: "Record a miracle"
            ) { onCompose(.miracle) }

            composeRow(
                symbol: MiracleIcon.prayer,
                tint: MiracleColor.prayerBlue,
                title: "Carrying something heavy?",
                subtitle: "Ask for prayer"
            ) { onCompose(.prayer) }
        }
    }

    private func composeRow(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.regular) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: MiracleSpacing.hair) {
                    Text(title)
                        .font(MiracleFont.interface(.subheadline))
                        .foregroundStyle(MiracleColor.inkSecondary)
                    Text(subtitle)
                        .font(MiracleFont.interface(.headline))
                        .foregroundStyle(MiracleColor.ink)
                }
                .multilineTextAlignment(.leading)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(MiracleColor.inkSecondary)
            }
        }
        .buttonStyle(.plain)
        .padding(MiracleSpacing.regular)
        .background(MiracleColor.canvasElevated, in: .rect(cornerRadius: MiracleRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.card)
                .stroke(MiracleColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subtitle). \(title)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func prayerSection(_ feed: HomeFeed, model: HomeModel) -> some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            SectionHeader(
                title: "People who could use prayer",
                subtitle: feed.prayerRequests.isEmpty
                    ? nil
                    : "\(feed.prayerRequests.count) waiting"
            )

            if feed.prayerRequests.isEmpty {
                caughtUp(feed, model: model)
            } else {
                ForEach(feed.prayerRequests) { post in
                    Button { onOpen(post.id) } label: {
                        PrayerCard(post: post) {
                            Task { await model.pray(for: post) }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if feed.remainingPrayerRequests > 0 {
                    // Deliberately a choice, not an automatic page load.
                    SecondaryButton(
                        title: "See \(feed.remainingPrayerRequests) more",
                        systemImage: "arrow.down"
                    ) {
                        Task { await model.seeMore() }
                    }
                }
            }
        }
    }

    /// The end of the session. The point of Home is that it has one.
    private func caughtUp(_ feed: HomeFeed, model: HomeModel) -> some View {
        MiracleCard(isHighlighted: model.hasJustFinished) {
            VStack(spacing: MiracleSpacing.small) {
                Image(systemName: model.hasJustFinished ? "checkmark.circle.fill" : "sun.horizon")
                    .font(.title2)
                    .foregroundStyle(MiracleColor.sage)
                    .accessibilityHidden(true)

                Text(model.hasJustFinished ? "You're caught up." : "Nothing waiting right now.")
                    .font(MiracleFont.reflective(.title3))
                    .foregroundStyle(MiracleColor.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.hasJustFinished
                     ? "Thank you for showing up for someone today."
                     : "When someone asks for prayer, they'll appear here.")
                    .font(MiracleFont.interface(.callout))
                    .foregroundStyle(MiracleColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MiracleSpacing.small)
        }
        .accessibilityElement(children: .combine)
    }

    private func miracleSection(_ feed: HomeFeed) -> some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            SectionHeader(title: "Miracles around you")

            ForEach(feed.recentMiracles) { post in
                Button { onOpen(post.id) } label: { JournalEntryCard(post: post) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func memorySection(_ memory: Post) -> some View {
        VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
            SectionHeader(title: "On this day", subtitle: Self.yearsAgo(memory.createdAt))

            Button { onOpen(memory.id) } label: {
                MiracleCard(isHighlighted: true) {
                    VStack(alignment: .leading, spacing: MiracleSpacing.small) {
                        Text(memory.body)
                            .font(MiracleFont.reflective(.body))
                            .foregroundStyle(MiracleColor.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(memory.createdAt, format: .dateTime.month(.wide).day().year())
                            .font(MiracleFont.interface(.caption))
                            .foregroundStyle(MiracleColor.inkSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Copy

    /// Time-of-day greeting. Warm, and never presumes to know how someone's day is going.
    nonisolated static func salutation(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<5: "Still awake"
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }

    nonisolated static func yearsAgo(_ date: Date, from now: Date = Date(), calendar: Calendar = .current) -> String {
        let years = calendar.dateComponents([.year], from: date, to: now).year ?? 0
        return switch years {
        case ..<1: "Earlier this year"
        case 1: "One year ago"
        default: "\(years) years ago"
        }
    }
}

#if DEBUG
#Preview("Home") {
    HomeView(profile: ProfileResponse(username: "connor", displayName: "Connor"))
        .environment(\.dependencies, .preview())
}
#endif
