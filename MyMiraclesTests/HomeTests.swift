import Foundation
import Testing
@testable import MyMiracles

nonisolated final class FakeHomeRepository: HomeRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var feed: HomeFeed
    var nextFailure: AppError?
    private(set) var callCount = 0

    init(feed: HomeFeed) {
        self.feed = feed
    }

    func update(_ transform: (inout HomeFeed) -> Void) {
        lock.withLock { transform(&feed) }
    }

    func home() async throws(AppError) -> HomeFeed {
        if let failure = lock.withLock({ let f = nextFailure; nextFailure = nil; return f }) {
            throw failure
        }
        return lock.withLock {
            callCount += 1
            return feed
        }
    }
}

nonisolated extension HomeFeed {
    static func fixture(
        prayerRequests: [Post] = [],
        remaining: Int = 0,
        recentMiracles: [Post] = [],
        memory: Post? = nil
    ) -> HomeFeed {
        HomeFeed(
            prayerRequests: prayerRequests,
            remainingPrayerRequests: remaining,
            recentMiracles: recentMiracles,
            memory: memory
        )
    }
}

@MainActor
@Suite("Home")
struct HomeModelTests {
    private func makeModel(
        feed: HomeFeed,
        posts: FakePostRepository = FakePostRepository()
    ) -> (HomeModel, FakeHomeRepository, FakePostRepository) {
        let repository = FakeHomeRepository(feed: feed)
        return (
            HomeModel(repository: repository, posts: posts, analytics: NoopAnalyticsClient()),
            repository,
            posts
        )
    }

    @Test("Loads the day's set")
    func loads() async {
        let prayers = [Post.fixture(id: "p1", isMine: false), Post.fixture(id: "p2", isMine: false)]
        let (model, _, _) = makeModel(feed: .fixture(prayerRequests: prayers, remaining: 3))
        await model.load()

        #expect(model.feed?.prayerRequests.count == 2)
        #expect(model.feed?.remainingPrayerRequests == 3)
    }

    /**
     The behaviour Home exists for: the set is finishable, and finishing it is
     acknowledged. Praying removes someone from the list; when the last one goes and
     nothing remains, the screen has something to say rather than going blank.
     */
    @Test("Empties as you pray, and says so when it's done")
    func runsOutAndSaysSo() async {
        let prayers = [Post.fixture(id: "p1", isMine: false), Post.fixture(id: "p2", isMine: false)]
        let posts = FakePostRepository(seed: prayers)
        let (model, _, _) = makeModel(feed: .fixture(prayerRequests: prayers), posts: posts)
        await model.load()

        await model.pray(for: prayers[0])
        #expect(model.feed?.prayerRequests.map(\.id) == ["p2"])
        #expect(!model.hasJustFinished)

        await model.pray(for: prayers[1])
        #expect(model.feed?.prayerRequests.isEmpty == true)
        #expect(model.hasJustFinished)
        #expect(model.feed?.isCaughtUp == true)
    }

    /// A quiet morning is not the same as a finished one, and the copy differs.
    @Test("An empty set is not the same as a completed one")
    func quietIsNotFinished() async {
        let (model, _, _) = makeModel(feed: .fixture())
        await model.load()

        #expect(model.feed?.isCaughtUp == true)
        #expect(!model.hasJustFinished)
    }

    /// More waiting means more to do — the session is not over.
    @Test("Is not caught up while more remain")
    func notCaughtUpWithMoreWaiting() async {
        let (model, _, _) = makeModel(feed: .fixture(remaining: 7))
        await model.load()
        #expect(model.feed?.isCaughtUp == false)
    }

    @Test("Praying rolls back if it fails, and the person stays on the list")
    func prayerRollsBack() async {
        let prayer = Post.fixture(id: "p1", isMine: false)
        let posts = FakePostRepository(seed: [prayer])
        let (model, _, _) = makeModel(feed: .fixture(prayerRequests: [prayer]), posts: posts)
        await model.load()

        posts.nextFailure = AppError(kind: .offline)
        await model.pray(for: prayer)

        #expect(model.feed?.prayerRequests.map(\.id) == ["p1"])
        #expect(model.error?.kind == .offline)
        #expect(!model.hasJustFinished)
    }

    /// "See more" is a choice someone makes, never an automatic page load.
    @Test("Loads more only when asked")
    func seeMoreIsExplicit() async {
        let (model, repository, _) = makeModel(feed: .fixture(remaining: 4))
        await model.load()
        #expect(repository.callCount == 1)

        await model.seeMore()
        #expect(repository.callCount == 2)
    }

    /// A flaky network must not empty someone's morning in front of them.
    @Test("Keeps what is on screen when a refresh fails")
    func refreshFailureKeepsContent() async {
        let prayers = [Post.fixture(id: "p1", isMine: false)]
        let (model, repository, _) = makeModel(feed: .fixture(prayerRequests: prayers))
        await model.load()

        repository.nextFailure = AppError(kind: .offline)
        await model.refresh()

        #expect(model.feed?.prayerRequests.count == 1)
        #expect(model.error?.kind == .offline)
    }

    @Test("Surfaces a first-load failure with a retry")
    func firstLoadFailure() async {
        let (model, repository, _) = makeModel(feed: .fixture())
        repository.nextFailure = AppError(kind: .server)
        await model.load()

        #expect(model.state.error?.kind == .server)
        #expect(model.state.error?.isRetryable == true)
    }

    @Test("Decodes the Worker's shape")
    func decoding() throws {
        let json = """
        {
          "prayerRequests": [],
          "remainingPrayerRequests": 4,
          "recentMiracles": [],
          "memory": null
        }
        """
        let feed = try APICoding.decoder.decode(HomeFeed.self, from: Data(json.utf8))

        #expect(feed.remainingPrayerRequests == 4)
        #expect(feed.memory == nil)
        #expect(feed.isEmpty)
        #expect(!feed.isCaughtUp)
    }
}

@Suite("Home copy")
nonisolated struct HomeCopyTests {
    private func date(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    /// Warm, and never presuming to know how someone's day is going.
    @Test(
        "Greets by time of day",
        arguments: [(2, "Still awake"), (8, "Good morning"), (14, "Good afternoon"), (19, "Good evening"), (23, "Good night")]
    )
    func salutation(hour: Int, expected: String) {
        #expect(HomeView.salutation(for: date(hour: hour)) == expected)
    }

    @Test("Describes how long ago a memory was")
    func yearsAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current

        let oneYear = calendar.date(byAdding: .year, value: -1, to: now)!
        let threeYears = calendar.date(byAdding: .year, value: -3, to: now)!
        let months = calendar.date(byAdding: .month, value: -3, to: now)!

        #expect(HomeView.yearsAgo(oneYear, from: now) == "One year ago")
        #expect(HomeView.yearsAgo(threeYears, from: now) == "3 years ago")
        #expect(HomeView.yearsAgo(months, from: now) == "Earlier this year")
    }
}
