import Foundation
import Testing
import UIKit
@testable import MyMiracles

nonisolated final class FakeJournalRepository: JournalRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Post]
    var nextFailure: AppError?
    private(set) var lastFilter: JournalFilter?
    private(set) var lastSearch: String?
    private(set) var lastYear: Int?
    private(set) var callCount = 0
    /// Delays the response, so a slow earlier query can be raced against a newer one.
    var delay: Duration = .zero

    init(entries: [Post] = []) {
        self.entries = entries
    }

    func journal(
        filter: JournalFilter,
        search: String?,
        year: Int?,
        cursor: String?
    ) async throws(AppError) -> PostPage {
        let delay = lock.withLock { self.delay }
        if delay > .zero { try? await Task.sleep(for: delay) }

        if let failure = lock.withLock({ let f = nextFailure; nextFailure = nil; return f }) {
            throw failure
        }

        return lock.withLock {
            callCount += 1
            lastFilter = filter
            lastSearch = search
            lastYear = year

            var matched = entries
            if let type = filter.postType { matched = matched.filter { $0.type == type } }
            if let search { matched = matched.filter { $0.body.localizedCaseInsensitiveContains(search) } }
            if let year {
                matched = matched.filter {
                    Calendar.current.component(.year, from: $0.createdAt) == year
                }
            }
            return PostPage(items: matched, nextCursor: nil)
        }
    }

    func summary() async throws(AppError) -> JournalSummary {
        lock.withLock {
            var byYear: [Int: Int] = [:]
            for entry in entries {
                let year = Calendar.current.component(.year, from: entry.createdAt)
                byYear[year, default: 0] += 1
            }
            return JournalSummary(
                years: byYear.keys.sorted(by: >).map { .init(year: $0, total: byYear[$0]!) },
                total: entries.count
            )
        }
    }
}

nonisolated extension Post {
    static func dated(
        _ iso: String,
        id: String = UUID().uuidString,
        type: PostType = .miracle,
        body: String = "An entry",
        status: PostStatus = .active
    ) -> Post {
        let date = ISO8601DateFormatter().date(from: iso)!
        return Post(
            id: id, type: type, body: body, visibility: .privateOnly, status: status,
            createdAt: date, updatedAt: date,
            answeredAt: status == .answered ? date.addingTimeInterval(86_400 * 11) : nil,
            version: 1, prayerResponseCount: 0, commentCount: 0, updateCount: 0,
            displayProfile: DisplayProfile(username: "connor", displayName: "Connor"),
            isMine: true, hasPrayed: false, link: nil
        )
    }
}

@Suite("Journal grouping")
nonisolated struct JournalGroupingTests {
    /// Years, then months, then entries — the way a life reads back.
    @Test("Groups a flat list into years and months")
    func groups() {
        let years = JournalModel.group([
            .dated("2027-12-18T12:00:00Z", body: "Finally moved"),
            .dated("2027-11-03T12:00:00Z", body: "Interview prayer"),
            .dated("2027-09-04T12:00:00Z", body: "Gabi got the job"),
            .dated("2026-05-02T12:00:00Z", body: "Older"),
        ])

        #expect(years.map(\.year) == [2027, 2026])
        #expect(years[0].months.map(\.title) == ["December", "November", "September"])
        #expect(years[0].entryCount == 3)
        #expect(years[1].entryCount == 1)
    }

    /// The list arrives ordered from the server. Re-sorting would disagree with keyset
    /// pagination and make entries jump as pages arrive.
    @Test("Preserves the order it was given")
    func preservesOrder() {
        let years = JournalModel.group([
            .dated("2027-03-01T12:00:00Z", body: "First"),
            .dated("2027-03-05T12:00:00Z", body: "Second"),
        ])
        #expect(years[0].months[0].entries.map(\.body) == ["First", "Second"])
    }

    @Test("Keeps entries from the same month together")
    func sameMonth() {
        let years = JournalModel.group([
            .dated("2027-03-20T12:00:00Z"),
            .dated("2027-03-02T12:00:00Z"),
        ])
        #expect(years[0].months.count == 1)
        #expect(years[0].months[0].entries.count == 2)
    }

    @Test("Handles an empty journal")
    func empty() {
        #expect(JournalModel.group([]).isEmpty)
    }

    /// The same month in different years is two sections, not one.
    @Test("Does not merge the same month across years")
    func sameMonthDifferentYears() {
        let years = JournalModel.group([
            .dated("2027-03-01T12:00:00Z"),
            .dated("2026-03-01T12:00:00Z"),
        ])
        #expect(years.count == 2)
        #expect(years.allSatisfy { $0.months.count == 1 })
    }
}

@MainActor
@Suite("Journal")
struct JournalModelTests {
    private func makeModel(
        entries: [Post] = []
    ) -> (JournalModel, FakeJournalRepository) {
        let repository = FakeJournalRepository(entries: entries)
        return (
            JournalModel(repository: repository, analytics: NoopAnalyticsClient()),
            repository
        )
    }

    @Test("Loads and groups the timeline")
    func loads() async {
        let (model, _) = makeModel(entries: [
            .dated("2027-12-18T12:00:00Z"),
            .dated("2026-05-02T12:00:00Z"),
        ])
        await model.load()

        #expect(model.state.value?.map(\.year) == [2027, 2026])
        #expect(model.summary.total == 2)
    }

    @Test("Shows a designed empty state for a new journal")
    func emptyJournal() async {
        let (model, _) = makeModel()
        await model.load()

        #expect(model.state == .empty)
        #expect(!model.isFiltered)
    }

    @Test("Narrows by type", arguments: [
        (JournalFilter.miracles, PostType.miracle),
        (.prayers, .prayer),
        (.gratitude, .gratitude),
    ])
    func filtersByType(filter: JournalFilter, type: PostType) async {
        let (model, repository) = makeModel(entries: [
            .dated("2027-01-01T12:00:00Z", type: .miracle),
            .dated("2027-01-02T12:00:00Z", type: .prayer),
            .dated("2027-01-03T12:00:00Z", type: .gratitude),
        ])
        await model.load()

        model.filter = filter
        await model.applyQuery()

        #expect(repository.lastFilter == filter)
        #expect(model.state.value?.first?.months.first?.entries.allSatisfy { $0.type == type } == true)
    }

    @Test("Narrows by year")
    func filtersByYear() async {
        let (model, repository) = makeModel(entries: [
            .dated("2027-01-01T12:00:00Z"),
            .dated("2026-01-01T12:00:00Z"),
        ])
        await model.load()

        model.selectedYear = 2026
        await model.applyQuery()

        #expect(repository.lastYear == 2026)
        #expect(model.state.value?.map(\.year) == [2026])
    }

    @Test("Searches its own entries")
    func searches() async {
        let (model, repository) = makeModel(entries: [
            .dated("2027-01-01T12:00:00Z", body: "We finally got the house."),
            .dated("2027-01-02T12:00:00Z", body: "Dad called."),
        ])
        await model.load()

        model.searchText = "house"
        await model.applyQuery()

        #expect(repository.lastSearch == "house")
        #expect(model.state.value?.first?.months.first?.entries.count == 1)
    }

    @Test("Trims whitespace, and treats a blank search as no search")
    func trimsSearch() async {
        let (model, repository) = makeModel(entries: [.dated("2027-01-01T12:00:00Z")])
        await model.load()

        model.searchText = "   "
        await model.applyQuery()
        #expect(repository.lastSearch == nil)

        model.searchText = "  house  "
        await model.applyQuery()
        #expect(repository.lastSearch == "house")
    }

    /// A filtered empty result is a different message from an empty journal — one offers a
    /// way back, the other offers a way to start.
    @Test("Distinguishes an empty journal from an empty result")
    func emptyStates() async {
        let (model, _) = makeModel(entries: [.dated("2027-01-01T12:00:00Z", body: "Something")])
        await model.load()
        #expect(!model.isFiltered)

        model.searchText = "zebra"
        await model.applyQuery()

        #expect(model.state == .empty)
        #expect(model.isFiltered)
    }

    @Test("Clearing filters restores everything")
    func clearFilters() async {
        let (model, _) = makeModel(entries: [.dated("2027-01-01T12:00:00Z")])
        await model.load()

        model.filter = .prayers
        model.searchText = "zebra"
        model.selectedYear = 1999
        await model.applyQuery()
        #expect(model.state == .empty)

        await model.clearFilters()
        #expect(!model.isFiltered)
        #expect(model.state.value?.count == 1)
    }

    /**
     A slow earlier query must not overwrite a newer one. Without this, typing "ho" then
     "house" can leave the screen showing results for "ho" — and in a journal, showing
     entries someone did not ask for is worse than showing none.
     */
    @Test("A stale response never replaces a newer one")
    func staleResponseIgnored() async {
        let (model, repository) = makeModel(entries: [
            .dated("2027-01-01T12:00:00Z", body: "We finally got the house."),
            .dated("2027-01-02T12:00:00Z", body: "Dad called."),
        ])
        await model.load()

        repository.delay = .milliseconds(120)
        model.searchText = "house"
        async let slow: Void = model.applyQuery()

        try? await Task.sleep(for: .milliseconds(20))
        repository.delay = .zero
        model.searchText = "Dad"
        await model.applyQuery()

        await slow

        let bodies = model.state.value?.flatMap { $0.months.flatMap(\.entries) }.map(\.body)
        #expect(bodies == ["Dad called."])
    }

    /// A flaky network must not empty someone's journal in front of them.
    @Test("Keeps what is on screen when a refresh fails")
    func refreshFailureKeepsContent() async {
        let (model, repository) = makeModel(entries: [.dated("2027-01-01T12:00:00Z")])
        await model.load()

        repository.nextFailure = AppError(kind: .offline)
        await model.refresh()

        #expect(model.state.value?.count == 1)
        #expect(model.error?.kind == .offline)
    }

    @Test("Surfaces a first-load failure with a retry")
    func firstLoadFailure() async {
        let (model, repository) = makeModel()
        repository.nextFailure = AppError(kind: .server)
        await model.load()

        #expect(model.state.error?.kind == .server)
        #expect(model.state.error?.isRetryable == true)
    }

    @Test("Folds in a new entry, and drops a deleted one")
    func upsertAndRemove() async {
        let (model, _) = makeModel(entries: [.dated("2027-01-01T12:00:00Z", id: "existing")])
        await model.load()

        model.upsert(.dated("2027-06-01T12:00:00Z", id: "new"))
        #expect(model.state.value?.first?.entryCount == 2)

        model.remove(id: "new")
        #expect(model.state.value?.first?.entryCount == 1)

        model.remove(id: "existing")
        #expect(model.state == .empty)
    }
}

@Suite("Journal filters")
nonisolated struct JournalFilterTests {
    @Test("Everything means no type filter")
    func allHasNoType() {
        #expect(JournalFilter.all.postType == nil)
    }

    @Test("Each filter maps to its post type", arguments: [
        (JournalFilter.miracles, PostType.miracle),
        (.prayers, .prayer),
        (.gratitude, .gratitude),
    ])
    func mapping(filter: JournalFilter, type: PostType) {
        #expect(filter.postType == type)
    }

    @Test("Every filter has a real symbol", arguments: JournalFilter.allCases)
    func symbols(filter: JournalFilter) {
        #expect(UIImage(systemName: filter.symbol) != nil)
    }
}
