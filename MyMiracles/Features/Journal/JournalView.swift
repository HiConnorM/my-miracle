import SwiftUI

/// The Journal.
///
/// Years, then months, then entries — the way a life actually reads back. Filters and
/// search sit above it, and an answered prayer carries the miracle it became right there in
/// the timeline, so a story is legible without opening it.
struct JournalView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var model: JournalModel?
    @State private var composing: PostType?
    @State private var selected: String?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            ZStack {
                MiracleColor.canvas.ignoresSafeArea()
                content
            }
            .navigationTitle("My Miracles")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(item: $selected) { id in
                PostDetailView(postID: id) { updated in
                    model?.upsert(updated)
                } onDelete: { deleted in
                    model?.remove(id: deleted)
                }
            }
            .sheet(item: $composing) { type in
                ComposerView(type: type) { created in
                    model?.upsert(created)
                    composing = nil
                    selected = created.id
                }
            }
            .sheet(isPresented: $isExporting) {
                if let dependencies {
                    ExportView(baseURL: dependencies.configuration.apiBaseURL)
                }
            }
        }
        .task {
            guard model == nil, let dependencies else { return }
            let created = JournalModel(
                repository: HTTPJournalRepository(client: dependencies.api),
                analytics: dependencies.analytics
            )
            model = created
            await created.load()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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

        ToolbarItem(placement: .topBarLeading) {
            Button("Export", systemImage: "square.and.arrow.up") { isExporting = true }
                .labelStyle(.iconOnly)
                .foregroundStyle(MiracleColor.inkSecondary)
                .accessibilityLabel("Export your journal")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            @Bindable var model = model

            VStack(spacing: 0) {
                filters(model)

                switch model.state {
                case .idle, .loading:
                    LoadingState(label: "Loading your journal")
                case .empty:
                    emptyState(model)
                case .failed(let error):
                    ErrorState(error: error) { Task { await model.load() } }
                case .loaded(let years):
                    timeline(years, model: model)
                }
            }
            .searchable(
                text: $model.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search your journal"
            )
            .onSubmit(of: .search) { Task { await model.applyQuery() } }
            .onChange(of: model.searchText) { _, new in
                // Clearing the box restores the timeline without needing a submit.
                if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await model.applyQuery() }
                }
            }
        } else {
            LoadingState()
        }
    }

    private func filters(_ model: JournalModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: MiracleSpacing.small) {
                ForEach(JournalFilter.allCases) { option in
                    FilterChip(
                        title: option.title,
                        symbol: option.symbol,
                        isSelected: model.filter == option
                    ) {
                        model.filter = option
                        Task { await model.applyQuery() }
                    }
                }

                ForEach(model.summary.years) { year in
                    FilterChip(
                        title: String(year.year),
                        symbol: "calendar",
                        isSelected: model.selectedYear == year.year
                    ) {
                        model.selectedYear = model.selectedYear == year.year ? nil : year.year
                        Task { await model.applyQuery() }
                    }
                }
            }
            .padding(.horizontal, MiracleSpacing.regular)
            .padding(.vertical, MiracleSpacing.small)
        }
        .scrollIndicators(.hidden)
    }

    private func timeline(_ years: [JournalYear], model: JournalModel) -> some View {
        let lastEntryID = years.last?.months.last?.entries.last?.id

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: MiracleSpacing.comfortable) {
                ForEach(years) { year in
                    VStack(alignment: .leading, spacing: MiracleSpacing.regular) {
                        yearHeader(year)

                        ForEach(year.months) { month in
                            VStack(alignment: .leading, spacing: MiracleSpacing.medium) {
                                Text(month.title)
                                    .font(MiracleFont.interface(.subheadline, weight: .medium))
                                    .foregroundStyle(MiracleColor.inkSecondary)
                                    .accessibilityAddTraits(.isHeader)

                                ForEach(month.entries) { entry in
                                    entryRow(
                                        entry,
                                        model: model,
                                        isLast: entry.id == lastEntryID
                                    )
                                }
                            }
                        }
                    }
                }

                if model.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(MiracleSpacing.regular)
                }

                if let error = model.error {
                    ErrorNotice(error: error) { model.dismissError() }
                }
            }
            .padding(MiracleSpacing.regular)
        }
        .refreshable { await model.refresh() }
    }

    private func yearHeader(_ year: JournalYear) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MiracleSpacing.medium) {
            Text(String(year.year))
                .font(MiracleFont.reflective(.title))
                .foregroundStyle(MiracleColor.ink)

            Rectangle()
                .fill(MiracleColor.separator)
                .frame(height: 1)

            Text("\(year.entryCount)")
                .font(MiracleFont.interface(.caption))
                .foregroundStyle(MiracleColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(year.year), \(year.entryCount) entries")
        .accessibilityAddTraits(.isHeader)
    }

    private func entryRow(_ entry: Post, model: JournalModel, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selected = entry.id } label: { JournalEntryCard(post: entry) }
                .buttonStyle(.plain)

            // A prayer's answer, shown in the timeline where it happened — the story is
            // legible without opening anything.
            if entry.isAnsweredPrayer, let answeredAt = entry.answeredAt {
                HStack(spacing: MiracleSpacing.small) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(MiracleColor.separator)
                    Image(systemName: MiracleIcon.miracle)
                        .font(.caption)
                        .foregroundStyle(MiracleColor.haloGold)
                    Text("Answered")
                        .font(MiracleFont.interface(.caption, weight: .medium))
                        .foregroundStyle(MiracleColor.ink)
                    Text(answeredAt, format: .dateTime.month(.abbreviated).day())
                        .font(MiracleFont.interface(.caption))
                        .foregroundStyle(MiracleColor.inkSecondary)
                    Spacer()
                }
                .padding(.leading, MiracleSpacing.regular)
                .padding(.top, MiracleSpacing.small)
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear {
            if isLast { Task { await model.loadMore() } }
        }
    }

    private func emptyState(_ model: JournalModel) -> some View {
        Group {
            if model.isFiltered {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: "Nothing here",
                    message: "No entries match what you're looking for.",
                    action: (title: "Clear filters", perform: { Task { await model.clearFilters() } })
                )
            } else {
                EmptyState(
                    symbol: MiracleIcon.journal,
                    title: "Your journal is empty",
                    message: "Record something you want to remember, or ask for prayer about something happening now.",
                    action: (title: "Record a miracle", perform: { composing = .miracle })
                )
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// A filter or year chip.
struct FilterChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MiracleSpacing.tight) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(MiracleFont.interface(.footnote, weight: .medium))
            }
            .padding(.horizontal, MiracleSpacing.medium)
            .padding(.vertical, MiracleSpacing.small)
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? MiracleColor.ink : MiracleColor.canvasElevated,
            in: .rect(cornerRadius: MiracleRadius.pill)
        )
        .foregroundStyle(isSelected ? MiracleColor.canvas : MiracleColor.ink)
        .overlay(
            RoundedRectangle(cornerRadius: MiracleRadius.pill)
                .stroke(isSelected ? .clear : MiracleColor.separator, lineWidth: 1)
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension PostType: Identifiable {
    public var id: String { rawValue }
}
