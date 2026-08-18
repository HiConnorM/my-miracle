import Foundation
import Observation

/// What the journal is filtered to.
nonisolated enum JournalFilter: String, CaseIterable, Sendable, Identifiable {
    case all
    case miracles
    case prayers
    case gratitude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Everything"
        case .miracles: "Miracles"
        case .prayers: "Prayers"
        case .gratitude: "Gratitude"
        }
    }

    var symbol: String {
        switch self {
        case .all: MiracleIcon.journal
        case .miracles: MiracleIcon.miracle
        case .prayers: MiracleIcon.prayer
        case .gratitude: MiracleIcon.gratitude
        }
    }

    /// The server's `type` parameter, or `nil` for everything.
    var postType: PostType? {
        switch self {
        case .all: nil
        case .miracles: .miracle
        case .prayers: .prayer
        case .gratitude: .gratitude
        }
    }
}

/// A month's worth of entries, inside a year.
nonisolated struct JournalMonth: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let entries: [Post]
}

nonisolated struct JournalYear: Identifiable, Sendable, Equatable {
    let id: Int
    var year: Int { id }
    let months: [JournalMonth]

    var entryCount: Int { months.reduce(0) { $0 + $1.entries.count } }
}

nonisolated struct JournalSummary: Codable, Sendable, Equatable {
    struct Year: Codable, Sendable, Equatable, Identifiable {
        let year: Int
        let total: Int
        var byType: [String: Int] = [:]
        var id: Int { year }
    }

    var years: [Year] = []
    var total: Int = 0
}

nonisolated protocol JournalRepository: Sendable {
    func journal(
        filter: JournalFilter,
        search: String?,
        year: Int?,
        cursor: String?
    ) async throws(AppError) -> PostPage
    func summary() async throws(AppError) -> JournalSummary
}

nonisolated struct HTTPJournalRepository: JournalRepository {
    private let client: any APIClient

    init(client: any APIClient) {
        self.client = client
    }

    func journal(
        filter: JournalFilter,
        search: String?,
        year: Int?,
        cursor: String?
    ) async throws(AppError) -> PostPage {
        var query: [URLQueryItem] = []
        if let type = filter.postType { query.append(.init(name: "type", value: type.rawValue)) }
        if let search, !search.isEmpty { query.append(.init(name: "q", value: search)) }
        if let year { query.append(.init(name: "year", value: String(year))) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }

        return try await client.send(APIRequest<PostPage>.get("/v1/me/journal", query: query))
    }

    func summary() async throws(AppError) -> JournalSummary {
        try await client.send(APIRequest<JournalSummary>.get("/v1/me/journal/summary"))
    }
}

/// The journal: everything you have ever written, grouped the way a life actually reads.
///
/// This is the part of the product people stay for. It holds private entries and posts
/// published anonymously, because they are yours either way, and it can be searched and
/// exported — someone should stay because their history is here, not because leaving is
/// hard.
@MainActor
@Observable
final class JournalModel {
    private(set) var state: LoadState<[JournalYear]> = .idle
    private(set) var summary = JournalSummary()
    private(set) var isLoadingMore = false
    private(set) var error: AppError?

    var filter: JournalFilter = .all
    var searchText = ""
    var selectedYear: Int?

    private var entries: [Post] = []
    private var cursor: String?
    private var reloadToken = UUID()

    private let repository: any JournalRepository
    private let analytics: any AnalyticsClient

    init(repository: any JournalRepository, analytics: any AnalyticsClient) {
        self.repository = repository
        self.analytics = analytics
    }

    var isFiltered: Bool {
        filter != .all || selectedYear != nil || !trimmedSearch.isEmpty
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() async {
        state = .loading
        await fetch(replacing: true)
        summary = (try? await repository.summary()) ?? summary
        analytics.track(.journalOpened)
    }

    /// Re-runs the query after a filter, year or search change.
    ///
    /// Each run takes a token; a slower earlier request cannot overwrite a newer one, which
    /// is what stops results flickering back to a previous search while someone types.
    func applyQuery() async {
        state = .loading
        await fetch(replacing: true)
    }

    func refresh() async {
        await fetch(replacing: true, quietly: true)
        summary = (try? await repository.summary()) ?? summary
    }

    func loadMore() async {
        guard cursor != nil, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(replacing: false, quietly: true)
    }

    func clearFilters() async {
        filter = .all
        selectedYear = nil
        searchText = ""
        await applyQuery()
    }

    private func fetch(replacing: Bool, quietly: Bool = false) async {
        let token = replacing ? UUID() : reloadToken
        if replacing { reloadToken = token }

        do {
            let page = try await repository.journal(
                filter: filter,
                search: trimmedSearch.isEmpty ? nil : trimmedSearch,
                year: selectedYear,
                cursor: replacing ? nil : cursor
            )

            // A stale response from a previous query must not replace a newer one.
            guard token == reloadToken else { return }

            entries = replacing ? page.items : entries + page.items
            cursor = page.nextCursor
            state = entries.isEmpty ? .empty : .loaded(Self.group(entries))
            error = nil
        } catch {
            if quietly || state.value != nil {
                self.error = error
            } else {
                state = .failed(error)
            }
        }
    }

    func upsert(_ post: Post) {
        if let index = entries.firstIndex(where: { $0.id == post.id }) {
            entries[index] = post
        } else {
            entries.insert(post, at: 0)
        }
        state = entries.isEmpty ? .empty : .loaded(Self.group(entries))
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        state = entries.isEmpty ? .empty : .loaded(Self.group(entries))
    }

    func dismissError() { error = nil }

    /// Groups a flat, newest-first list into years and months.
    ///
    /// The list arrives ordered, so this preserves order rather than re-sorting — a
    /// re-sort would quietly disagree with the server's keyset pagination and make entries
    /// jump as pages arrive.
    nonisolated static func group(
        _ posts: [Post],
        calendar: Calendar = .current
    ) -> [JournalYear] {
        var years: [(year: Int, months: [(key: Int, title: String, entries: [Post])])] = []

        for post in posts {
            let components = calendar.dateComponents([.year, .month], from: post.createdAt)
            guard let year = components.year, let month = components.month else { continue }

            if years.last?.year != year {
                years.append((year: year, months: []))
            }
            if years[years.count - 1].months.last?.key != month {
                years[years.count - 1].months.append(
                    (key: month, title: monthName(month, calendar: calendar), entries: [])
                )
            }
            let lastMonth = years[years.count - 1].months.count - 1
            years[years.count - 1].months[lastMonth].entries.append(post)
        }

        return years.map { year in
            JournalYear(
                id: year.year,
                months: year.months.map {
                    JournalMonth(id: "\(year.year)-\($0.key)", title: $0.title, entries: $0.entries)
                }
            )
        }
    }

    private nonisolated static func monthName(_ month: Int, calendar: Calendar) -> String {
        let symbols = calendar.monthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : "\(month)"
    }
}
