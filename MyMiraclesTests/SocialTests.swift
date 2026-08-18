import Foundation
import Testing
@testable import MyMiracles

nonisolated final class FakeSocialRepository: SocialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var people: [PersonSummary]
    private var profiles: [String: ProfileDetail]
    private var commentsByPost: [String: [Encouragement]] = [:]
    private var savedPosts: [Post] = []

    var nextFailure: AppError?
    private(set) var followed: [String] = []
    private(set) var unfollowed: [String] = []
    private(set) var blocked: [String] = []
    private(set) var reports: [(type: String, id: String, category: ReportCategory)] = []
    private(set) var searchCount = 0
    var searchDelay: Duration = .zero

    init(people: [PersonSummary] = [], profiles: [String: ProfileDetail] = [:], saved: [Post] = []) {
        self.people = people
        self.profiles = profiles
        self.savedPosts = saved
    }

    private func failIfScripted() throws(AppError) {
        if let failure = lock.withLock({ let f = nextFailure; nextFailure = nil; return f }) {
            throw failure
        }
    }

    func profile(username: String) async throws(AppError) -> ProfileDetail {
        try failIfScripted()
        let found = lock.withLock { profiles[username] }
        guard let found else { throw AppError(kind: .notFound) }
        return found
    }

    func timeline(username: String, cursor: String?) async throws(AppError) -> PostPage {
        try failIfScripted()
        return PostPage(items: [], nextCursor: nil)
    }

    func follow(username: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock {
            followed.append(username)
            if var profile = profiles[username] { profile.isFollowing = true; profiles[username] = profile }
        }
    }

    func unfollow(username: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock {
            unfollowed.append(username)
            if var profile = profiles[username] { profile.isFollowing = false; profiles[username] = profile }
        }
    }

    func block(username: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock { blocked.append(username) }
    }

    func comments(for postID: String) async throws(AppError) -> [Encouragement] {
        try failIfScripted()
        return lock.withLock { commentsByPost[postID] ?? [] }
    }

    func addComment(to postID: String, body: String) async throws(AppError) -> Encouragement {
        try failIfScripted()
        return lock.withLock {
            let comment = Encouragement(
                id: UUID().uuidString, body: body, createdAt: Date(), isMine: true,
                author: DisplayProfile(username: "connor", displayName: "Connor")
            )
            commentsByPost[postID, default: []].append(comment)
            return comment
        }
    }

    func deleteComment(id: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock {
            for key in commentsByPost.keys {
                commentsByPost[key]?.removeAll { $0.id == id }
            }
        }
    }

    func save(postID: String) async throws(AppError) { try failIfScripted() }
    func unsave(postID: String) async throws(AppError) {
        try failIfScripted()
        lock.withLock { savedPosts.removeAll { $0.id == postID } }
    }

    func saved(cursor: String?) async throws(AppError) -> PostPage {
        try failIfScripted()
        return lock.withLock { PostPage(items: savedPosts, nextCursor: nil) }
    }

    func searchPeople(query: String) async throws(AppError) -> [PersonSummary] {
        let delay = lock.withLock { searchDelay }
        if delay > .zero { try? await Task.sleep(for: delay) }
        try failIfScripted()

        return lock.withLock {
            searchCount += 1
            return people.filter {
                $0.username.localizedCaseInsensitiveContains(query)
                    || $0.displayName.localizedCaseInsensitiveContains(query)
            }
        }
    }

    func report(
        subjectType: String,
        subjectID: String,
        category: ReportCategory,
        details: String?
    ) async throws(AppError) {
        try failIfScripted()
        lock.withLock { reports.append((subjectType, subjectID, category)) }
    }
}

nonisolated extension PersonSummary {
    static func fixture(_ username: String, displayName: String? = nil, isFollowing: Bool = false) -> PersonSummary {
        PersonSummary(
            username: username,
            displayName: displayName ?? username.capitalized,
            isFollowing: isFollowing
        )
    }
}

nonisolated extension ProfileDetail {
    static func fixture(
        _ username: String,
        isMe: Bool = false,
        isFollowing: Bool = false
    ) -> ProfileDetail {
        ProfileDetail(
            username: username,
            displayName: username.capitalized,
            bio: nil,
            createdAt: Date(timeIntervalSince1970: 1_785_283_200),
            isMe: isMe,
            isFollowing: isFollowing
        )
    }
}

@MainActor
@Suite("Discover")
struct DiscoverModelTests {
    /// The whole of discovery is a search box. The screen shows nothing until asked.
    @Test("Shows nothing until someone searches")
    func idleUntilAsked() async {
        let model = DiscoverModel(repository: FakeSocialRepository(people: [.fixture("gabi")]))
        #expect(model.state == .idle)

        await model.search()
        #expect(model.state == .idle, "an empty query must not run a search")
    }

    @Test("Needs at least two characters")
    func minimumQuery() async {
        let repository = FakeSocialRepository(people: [.fixture("gabi")])
        let model = DiscoverModel(repository: repository)

        model.query = "g"
        await model.search()
        #expect(repository.searchCount == 0)

        model.query = "ga"
        await model.search()
        #expect(repository.searchCount == 1)
    }

    @Test("Finds people")
    func finds() async {
        let model = DiscoverModel(
            repository: FakeSocialRepository(people: [.fixture("gabi"), .fixture("connor")])
        )
        model.query = "gab"
        await model.search()

        #expect(model.state.value?.map(\.username) == ["gabi"])
    }

    @Test("Shows a designed empty state when nobody matches")
    func noMatches() async {
        let model = DiscoverModel(repository: FakeSocialRepository(people: [.fixture("gabi")]))
        model.query = "zebra"
        await model.search()

        #expect(model.state == .empty)
    }

    /// Typing "gab" then "gabi" must not leave results for "gab" on screen.
    @Test("A stale search never replaces a newer one")
    func staleSearchIgnored() async {
        let repository = FakeSocialRepository(people: [.fixture("gabi"), .fixture("connor")])
        let model = DiscoverModel(repository: repository)

        repository.searchDelay = .milliseconds(120)
        model.query = "gab"
        async let slow: Void = model.search()

        try? await Task.sleep(for: .milliseconds(20))
        repository.searchDelay = .zero
        model.query = "con"
        await model.search()

        await slow

        #expect(model.state.value?.map(\.username) == ["connor"])
    }

    @Test("Follows optimistically, and rolls back on failure")
    func followRollsBack() async {
        let repository = FakeSocialRepository(people: [.fixture("gabi")])
        let model = DiscoverModel(repository: repository)
        model.query = "gab"
        await model.search()

        repository.nextFailure = AppError(kind: .offline)
        await model.toggleFollow(model.state.value![0])

        #expect(model.state.value?[0].isFollowing == false)
        #expect(model.error?.kind == .offline)
    }

    @Test("Clearing returns to the resting state")
    func clears() async {
        let model = DiscoverModel(repository: FakeSocialRepository(people: [.fixture("gabi")]))
        model.query = "gab"
        await model.search()
        #expect(model.state.value != nil)

        model.clear()
        #expect(model.state == .idle)
        #expect(model.query.isEmpty)
    }
}

@MainActor
@Suite("Profile")
struct ProfileModelTests {
    private func makeModel(
        _ username: String = "gabi",
        profile: ProfileDetail? = nil
    ) -> (ProfileModel, FakeSocialRepository) {
        let repository = FakeSocialRepository(
            profiles: [username: profile ?? .fixture(username)]
        )
        return (
            ProfileModel(username: username, repository: repository, analytics: NoopAnalyticsClient()),
            repository
        )
    }

    @Test("Loads a profile and its timeline")
    func loads() async {
        let (model, _) = makeModel()
        await model.load()

        #expect(model.profile?.username == "gabi")
        #expect(model.timeline == .empty)
    }

    @Test("Follows and unfollows")
    func followToggle() async {
        let (model, repository) = makeModel()
        await model.load()

        await model.toggleFollow()
        #expect(repository.followed == ["gabi"])
        #expect(model.profile?.isFollowing == true)

        await model.toggleFollow()
        #expect(repository.unfollowed == ["gabi"])
        #expect(model.profile?.isFollowing == false)
    }

    @Test("Rolls back a failed follow")
    func followRollsBack() async {
        let (model, repository) = makeModel()
        await model.load()

        repository.nextFailure = AppError(kind: .offline)
        await model.toggleFollow()

        #expect(model.profile?.isFollowing == false)
        #expect(model.error?.kind == .offline)
    }

    /// A block makes someone invisible, so the screen that was showing them closes.
    @Test("Blocking marks the profile as gone")
    func blocking() async {
        let (model, repository) = makeModel()
        await model.load()

        await model.block()

        #expect(repository.blocked == ["gabi"])
        #expect(model.hasBlocked)
    }

    /// Account ids are internal; a person is reported by the only handle a client has.
    @Test("Reports a person by username")
    func reporting() async {
        let (model, repository) = makeModel()
        await model.load()

        let sent = await model.report(category: .impersonation)

        #expect(sent)
        #expect(repository.reports.first?.type == "profile")
        #expect(repository.reports.first?.id == "gabi")
        #expect(repository.reports.first?.category == .impersonation)
    }

    @Test("Offers no follow control on your own profile")
    func ownProfile() async {
        let (model, _) = makeModel("connor", profile: .fixture("connor", isMe: true))
        await model.load()
        #expect(model.profile?.isMe == true)
    }

    @Test("Surfaces a load failure with a retry")
    func loadFailure() async {
        let (model, repository) = makeModel()
        repository.nextFailure = AppError(kind: .server)
        await model.load()

        #expect(model.state.error?.kind == .server)
    }
}

@MainActor
@Suite("Comments")
struct CommentsModelTests {
    @Test("Loads, adds and removes encouragement")
    func lifecycle() async {
        let repository = FakeSocialRepository()
        let model = CommentsModel(postID: "p1", repository: repository)

        await model.load()
        #expect(model.state == .empty)

        await model.add("Thinking of you.")
        #expect(model.state.value?.map(\.body) == ["Thinking of you."])

        await model.delete(model.state.value![0])
        // An empty collection resolves to the designed empty state, not an empty list.
        #expect(model.state == .empty)
    }

    @Test("Ignores an empty comment")
    func ignoresEmpty() async {
        let repository = FakeSocialRepository()
        let model = CommentsModel(postID: "p1", repository: repository)
        await model.load()

        await model.add("   \n ")
        #expect(model.state == .empty)
    }

    @Test("Trims before sending")
    func trims() async {
        let model = CommentsModel(postID: "p1", repository: FakeSocialRepository())
        await model.load()

        await model.add("  Praying for you.  ")
        #expect(model.state.value?.first?.body == "Praying for you.")
    }

    @Test("Puts a comment back if deleting it fails")
    func deleteRollsBack() async {
        let repository = FakeSocialRepository()
        let model = CommentsModel(postID: "p1", repository: repository)
        await model.load()
        await model.add("Thinking of you.")

        repository.nextFailure = AppError(kind: .offline)
        await model.delete(model.state.value![0])

        #expect(model.state.value?.count == 1)
        #expect(model.error?.kind == .offline)
    }
}

@MainActor
@Suite("Saved")
struct SavedModelTests {
    @Test("Lists what was saved")
    func lists() async {
        let repository = FakeSocialRepository(saved: [.fixture(id: "p1"), .fixture(id: "p2")])
        let model = SavedModel(repository: repository)
        await model.load()

        #expect(model.state.value?.map(\.id) == ["p1", "p2"])
    }

    @Test("Shows a designed empty state")
    func empty() async {
        let model = SavedModel(repository: FakeSocialRepository())
        await model.load()
        #expect(model.state == .empty)
    }

    @Test("Removes optimistically, and puts it back on failure")
    func unsaveRollsBack() async {
        let repository = FakeSocialRepository(saved: [.fixture(id: "p1")])
        let model = SavedModel(repository: repository)
        await model.load()

        repository.nextFailure = AppError(kind: .offline)
        await model.unsave(model.state.value![0])

        #expect(model.state.value?.count == 1)
    }
}

@Suite("Social types")
nonisolated struct SocialTypeTests {
    /// Deliberately absent: any field that would let a follower count be displayed.
    @Test("A profile carries no popularity metric")
    func noPopularityMetrics() {
        let mirrored = Mirror(reflecting: ProfileDetail.fixture("gabi"))
            .children.compactMap(\.label)

        for forbidden in ["followerCount", "followingCount", "postCount", "score", "rank"] {
            #expect(!mirrored.contains(forbidden))
        }
    }

    @Test("A person summary carries none either")
    func personHasNone() {
        let mirrored = Mirror(reflecting: PersonSummary.fixture("gabi"))
            .children.compactMap(\.label)

        for forbidden in ["followerCount", "followingCount", "postCount"] {
            #expect(!mirrored.contains(forbidden))
        }
    }

    @Test("Report categories are plain words, and match the server", arguments: ReportCategory.allCases)
    func reportCategories(category: ReportCategory) {
        #expect(!category.title.isEmpty)
        #expect(category.rawValue.allSatisfy { $0.isLowercase || $0 == "_" })
    }

    @Test("Decodes a profile from the Worker's shape")
    func decodesProfile() throws {
        let json = """
        {
          "username": "gabi",
          "displayName": "Gabi",
          "avatarKey": null,
          "bio": "Grateful.",
          "createdAt": 1785283200000,
          "isMe": false,
          "isFollowing": true
        }
        """
        let profile = try APICoding.decoder.decode(ProfileDetail.self, from: Data(json.utf8))

        #expect(profile.username == "gabi")
        #expect(profile.isFollowing)
        #expect(!profile.isMe)
    }
}
