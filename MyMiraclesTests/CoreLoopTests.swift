import Foundation
import Testing
@testable import MyMiracles

@Suite("Post draft")
nonisolated struct PostDraftTests {
    /// Anonymity is meaningless without an audience, and the server rejects the pair — so
    /// the draft clears it rather than sending something that will be refused.
    @Test("Clears anonymity when a post becomes private")
    func privateClearsAnonymity() {
        let draft = PostDraft(type: .prayer, body: "x", visibility: .privateOnly, anonymous: true)
        #expect(draft.normalized.anonymous == false)
    }

    @Test("Keeps anonymity where there is an audience", arguments: [PostVisibility.followers, .publicFeed])
    func sharedKeepsAnonymity(visibility: PostVisibility) {
        let draft = PostDraft(type: .prayer, body: "x", visibility: visibility, anonymous: true)
        #expect(draft.normalized.anonymous)
    }

    @Test("Trims surrounding whitespace")
    func trims() {
        let draft = PostDraft(body: "  Please pray.  \n")
        #expect(draft.normalized.body == "Please pray.")
    }

    @Test("Will not send an empty or whitespace-only body", arguments: ["", "   ", "\n\n"])
    func rejectsEmpty(body: String) {
        #expect(!PostDraft(body: body).isSendable)
    }

    @Test("Will not send past the server's limit")
    func rejectsTooLong() {
        #expect(!PostDraft(body: String(repeating: "a", count: 5001)).isSendable)
        #expect(PostDraft(body: String(repeating: "a", count: 5000)).isSendable)
    }

    /// The journal starts private (docs/product-spec.md). Sharing is always a deliberate act.
    @Test("Defaults to private")
    func defaultsToPrivate() {
        #expect(PostDraft().visibility == .privateOnly)
    }
}

@Suite("Post")
nonisolated struct PostTests {
    @Test("Only an open prayer of your own can be answered")
    func answerability() {
        #expect(Post.fixture(type: .prayer, status: .active, isMine: true).canBeAnswered)
        #expect(!Post.fixture(type: .prayer, status: .answered, isMine: true).canBeAnswered)
        #expect(!Post.fixture(type: .prayer, status: .active, isMine: false).canBeAnswered)
        #expect(!Post.fixture(type: .miracle, status: .active, isMine: true).canBeAnswered)
    }

    @Test("A private post accepts no prayer")
    func privateAcceptsNoPrayer() {
        #expect(!Post.fixture(visibility: .privateOnly).acceptsPrayer)
        #expect(Post.fixture(visibility: .publicFeed).acceptsPrayer)
    }

    /// A missing display profile is exactly what anonymity is. There is no author field to
    /// consult, by design (rules 8 and 9).
    @Test("Anonymity is the absence of a display profile")
    func anonymity() {
        #expect(Post.fixture(anonymous: true).isAnonymous)
        #expect(!Post.fixture(anonymous: false).isAnonymous)
    }

    @Test("Decodes the Worker's payload, and carries no author field")
    func decoding() throws {
        let json = """
        {
          "id": "post-1",
          "type": "prayer",
          "body": "Please pray for my marriage.",
          "visibility": "public",
          "status": "answered",
          "createdAt": 1785283200000,
          "updatedAt": 1785283200000,
          "answeredAt": 1785369600000,
          "version": 2,
          "prayerResponseCount": 3,
          "commentCount": 1,
          "updateCount": 2,
          "displayProfile": null,
          "isMine": true,
          "hasPrayed": false,
          "link": {
            "id": "post-2",
            "type": "miracle",
            "excerpt": "I got the call.",
            "createdAt": 1785369600000
          }
        }
        """
        let post = try APICoding.decoder.decode(Post.self, from: Data(json.utf8))

        #expect(post.status == .answered)
        #expect(post.isAnsweredPrayer)
        #expect(post.isAnonymous)
        #expect(post.link?.id == "post-2")
        #expect(post.createdAt == Date(timeIntervalSince1970: 1_785_283_200))

        // The shape itself has no author. Nothing to leak.
        let mirrored = Mirror(reflecting: post).children.compactMap(\.label)
        for forbidden in ["ownerId", "authorId", "accountId"] {
            #expect(!mirrored.contains(forbidden))
        }
    }
}

@MainActor
@Suite("The core loop")
struct CoreLoopTests {
    private func makeModels() -> (FakePostRepository, ComposerModel) {
        let repository = FakePostRepository()
        return (
            repository,
            ComposerModel(repository: repository, analytics: NoopAnalyticsClient(), type: .prayer)
        )
    }

    /**
     The whole journey, from the client's side: ask, be prayed for, update, answer,
     remember. If this passes, the loop works.
     */
    @Test("Carries a prayer from asking to remembering")
    func wholeJourney() async throws {
        let repository = FakePostRepository()
        let analytics = NoopAnalyticsClient()

        // Ask.
        let composer = ComposerModel(repository: repository, analytics: analytics, type: .prayer)
        composer.draft.body = "I have an interview on Thursday."
        composer.setVisibility(.publicFeed)
        await composer.save()

        let prayer = try #require(composer.saved)
        #expect(prayer.type == .prayer)
        #expect(prayer.status == .active)

        // Be prayed for.
        let detail = PostDetailModel(postID: prayer.id, repository: repository, analytics: analytics)
        await detail.load()
        await detail.togglePrayer()
        #expect(detail.post?.prayerResponseCount == 1)
        #expect(detail.post?.hasPrayed == true)

        // Update while it is still open.
        await detail.addUpdate("It went well. They said they would call.")
        #expect(detail.updates.count == 1)
        #expect(detail.post?.updateCount == 1)

        // Answer.
        var miracle = PostDraft(type: .miracle, visibility: .publicFeed)
        miracle.body = "I got the call. I start on the first."
        await detail.markAnswered(with: miracle, idempotencyKey: "key-1")

        let created = try #require(detail.justAnswered)
        #expect(created.type == .miracle)

        // The prayer is answered and points at the miracle.
        #expect(detail.post?.status == .answered)
        #expect(detail.post?.link?.id == created.id)

        // The miracle points back.
        let miracleDetail = PostDetailModel(
            postID: created.id, repository: repository, analytics: analytics
        )
        await miracleDetail.load()
        #expect(miracleDetail.post?.link?.id == prayer.id)

        // Both are in the journal.
        let journal = JournalModel(repository: repository, analytics: analytics)
        await journal.load()
        let ids = Set((journal.state.value ?? []).map(\.id))
        #expect(ids == [prayer.id, created.id])
    }

    @Test("Answering is refused for anything that is not an open prayer")
    func answeringGuards() async throws {
        let repository = FakePostRepository(seed: [
            Post.fixture(id: "miracle-1", type: .miracle),
            Post.fixture(id: "answered-1", type: .prayer, status: .answered),
        ])
        let analytics = NoopAnalyticsClient()

        for id in ["miracle-1", "answered-1"] {
            let model = PostDetailModel(postID: id, repository: repository, analytics: analytics)
            await model.load()
            await model.markAnswered(with: PostDraft(type: .miracle, body: "x"), idempotencyKey: "k")
            #expect(model.justAnswered == nil, "\(id) should not be answerable")
        }
        #expect(repository.answerCallCount == 0)
    }

    /// A retry after a dropped connection must replay, not create a second miracle.
    @Test("Answering twice with the same key produces one miracle")
    func answeringIsIdempotent() async throws {
        let repository = FakePostRepository(seed: [Post.fixture(id: "prayer-1", type: .prayer)])
        let model = PostDetailModel(
            postID: "prayer-1", repository: repository, analytics: NoopAnalyticsClient()
        )
        await model.load()

        var draft = PostDraft(type: .miracle, visibility: .publicFeed)
        draft.body = "It happened."
        await model.markAnswered(with: draft, idempotencyKey: "same-key")
        let first = model.justAnswered
        model.clearJustAnswered()

        await model.markAnswered(with: draft, idempotencyKey: "same-key")

        // The second attempt is refused because the prayer is no longer open — which is the
        // correct outcome, and leaves exactly one miracle behind.
        let journal = try await repository.journal(after: nil)
        #expect(journal.items.filter { $0.type == .miracle }.count == 1)
        #expect(first != nil)
    }

    /// The count should move the instant it is tapped — this is a small kindness, and it
    /// should feel immediate.
    @Test("Praying is optimistic, and rolls back on failure")
    func optimisticPrayer() async throws {
        let repository = FakePostRepository(seed: [
            Post.fixture(id: "p1", isMine: false, hasPrayed: false),
        ])
        let model = PostDetailModel(
            postID: "p1", repository: repository, analytics: NoopAnalyticsClient()
        )
        await model.load()

        repository.nextFailure = AppError(kind: .offline)
        await model.togglePrayer()

        #expect(model.post?.hasPrayed == false)
        #expect(model.post?.prayerResponseCount == 0)
        #expect(model.error?.kind == .offline)
    }

    @Test("Praying can be withdrawn")
    func withdrawPrayer() async throws {
        let repository = FakePostRepository(seed: [Post.fixture(id: "p1", isMine: false)])
        let model = PostDetailModel(
            postID: "p1", repository: repository, analytics: NoopAnalyticsClient()
        )
        await model.load()

        await model.togglePrayer()
        #expect(model.post?.hasPrayed == true)

        await model.togglePrayer()
        #expect(model.post?.hasPrayed == false)
        #expect(model.post?.prayerResponseCount == 0)
    }

    @Test("A composer failure keeps the draft so nothing written is lost")
    func composerKeepsDraftOnFailure() async throws {
        let (repository, composer) = makeModels()
        composer.draft.body = "Something I spent ten minutes writing."
        repository.nextFailure = AppError(kind: .offline)

        await composer.save()

        #expect(composer.saved == nil)
        #expect(composer.error?.kind == .offline)
        #expect(composer.draft.body == "Something I spent ten minutes writing.")
    }

    @Test("A composer retry reuses its key, so a duplicate is never created")
    func composerRetryIsIdempotent() async throws {
        let (repository, composer) = makeModels()
        composer.draft.body = "Please pray."

        repository.nextFailure = AppError(kind: .timedOut)
        await composer.save()
        #expect(composer.saved == nil)

        await composer.save()
        #expect(composer.saved != nil)

        let journal = try await repository.journal(after: nil)
        #expect(journal.items.count == 1)
    }

    @Test("Switching to private clears anonymity in the composer")
    func composerPrivacyInteraction() {
        let (_, composer) = makeModels()
        composer.setVisibility(.publicFeed)
        composer.draft.anonymous = true

        composer.setVisibility(.privateOnly)
        #expect(!composer.draft.anonymous)
    }
}

@MainActor
@Suite("Journal")
struct JournalModelTests {
    @Test("Shows a designed empty state, not a blank list")
    func emptyState() async {
        let model = JournalModel(repository: FakePostRepository(), analytics: NoopAnalyticsClient())
        await model.load()
        #expect(model.state == .empty)
    }

    @Test("Surfaces a failure with something to retry")
    func failureState() async {
        let repository = FakePostRepository()
        repository.nextFailure = AppError(kind: .offline)

        let model = JournalModel(repository: repository, analytics: NoopAnalyticsClient())
        await model.load()

        #expect(model.state.error?.kind == .offline)
        #expect(model.state.error?.isRetryable == true)
    }

    /// A flaky connection must never empty someone's journal in front of them.
    @Test("Keeps what is on screen when a refresh fails")
    func refreshFailureKeepsContent() async {
        let repository = FakePostRepository(seed: [Post.fixture(id: "p1")])
        let model = JournalModel(repository: repository, analytics: NoopAnalyticsClient())
        await model.load()
        #expect(model.state.value?.count == 1)

        repository.nextFailure = AppError(kind: .offline)
        await model.refresh()

        #expect(model.state.value?.count == 1)
    }

    @Test("Folds a newly created post in without a round trip")
    func upsert() async {
        let model = JournalModel(repository: FakePostRepository(), analytics: NoopAnalyticsClient())
        await model.load()

        model.upsert(Post.fixture(id: "new"))
        #expect(model.state.value?.map(\.id) == ["new"])

        // Upserting the same id replaces rather than duplicates.
        model.upsert(Post.fixture(id: "new", body: "edited"))
        #expect(model.state.value?.count == 1)
        #expect(model.state.value?.first?.body == "edited")
    }

    @Test("Removes a deleted post")
    func remove() async {
        let repository = FakePostRepository(seed: [Post.fixture(id: "p1"), Post.fixture(id: "p2")])
        let model = JournalModel(repository: repository, analytics: NoopAnalyticsClient())
        await model.load()

        model.remove(id: "p1")
        #expect(model.state.value?.map(\.id) == ["p2"])
    }
}
