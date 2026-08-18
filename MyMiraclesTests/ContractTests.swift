import Foundation
import Testing
@testable import MyMiracles

/// Contract tests against responses captured from a **live Worker**.
///
/// This closes a real gap. The iOS tests run against `FakePostRepository` and the Worker
/// tests assert on raw JSON, so nothing else in the suite would notice if the two drifted
/// — a renamed field or a changed date format would compile, pass every test, and fail the
/// moment someone opened the app.
///
/// The fixtures in `Fixtures/` were produced by driving the real loop over HTTP against
/// `wrangler dev`. Regenerate them by re-running that flow; do not hand-edit them, or they
/// stop being evidence of anything.
@Suite("Worker contract")
nonisolated struct ContractTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    /// An answered prayer carrying its link to the miracle it became — the payload the core
    /// loop depends on.
    @Test("An answered prayer decodes from a real response")
    func answeredPrayerDecodes() throws {
        let post = try APICoding.decoder.decode(Post.self, from: try Self.fixture("answered-prayer"))

        #expect(post.type == .prayer)
        #expect(post.status == .answered)
        #expect(post.isAnsweredPrayer)
        #expect(post.answeredAt != nil)
        #expect(post.prayerResponseCount == 1)
        #expect(post.updateCount == 1)
        #expect(post.hasPrayed)
        #expect(post.displayProfile?.username == "connor")

        // The half of the story that makes this a product rather than a notes app.
        #expect(post.link?.type == .miracle)
        #expect(post.link?.excerpt == "I got the call. I start on the first.")
    }

    /// Epoch milliseconds, end to end: D1 stores an integer, the Worker passes it through,
    /// `Date` decodes the same number. A change of unit on either side silently shifts every
    /// timestamp by a factor of a thousand.
    @Test("Timestamps are epoch milliseconds on both sides")
    func timestampsAreMilliseconds() throws {
        let raw = try JSONSerialization.jsonObject(
            with: try Self.fixture("answered-prayer")
        ) as? [String: Any]
        let createdAtMilliseconds = try #require(raw?["createdAt"] as? Double)

        let post = try APICoding.decoder.decode(Post.self, from: try Self.fixture("answered-prayer"))

        #expect(post.createdAt.timeIntervalSince1970 == createdAtMilliseconds / 1000)
        // Sanity: a value this size can only be milliseconds. Seconds would land in 1970.
        #expect(createdAtMilliseconds > 1_000_000_000_000)
    }

    /// The response must carry no ownership field of any kind. For an anonymous post this
    /// is the whole promise (rules 8 and 9), and it is asserted on the wire format rather
    /// than on a Swift type that could not express it anyway.
    @Test("No response field identifies the author")
    func noOwnershipOnTheWire() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: try Self.fixture("answered-prayer"))
                as? [String: Any]
        )

        for forbidden in ["ownerId", "owner_id", "authorId", "author_id", "accountId", "account_id"] {
            #expect(raw[forbidden] == nil, "the Worker returned \(forbidden)")
        }
    }

    /// Home is one request that fills a whole screen, so a drift here breaks the first
    /// thing anyone sees.
    @Test("Home decodes from a real response")
    func homeDecodes() throws {
        let feed = try APICoding.decoder.decode(HomeFeed.self, from: try Self.fixture("home"))

        #expect(feed.prayerRequests.count == 2)
        #expect(feed.prayerRequests.allSatisfy { $0.type == .prayer })
        #expect(feed.prayerRequests.allSatisfy { !$0.isMine })
        #expect(feed.prayerRequests.allSatisfy { !$0.hasPrayed })
        // Nothing left beyond the batch, so this session has an end.
        #expect(feed.isCaughtUp == false)
        #expect(feed.remainingPrayerRequests == 0)
    }

    @Test("Home's payload has exactly the expected shape")
    func homeShape() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: try Self.fixture("home")) as? [String: Any]
        )
        #expect(Set(raw.keys) == ["prayerRequests", "remainingPrayerRequests", "recentMiracles", "memory"])
    }

    /// Every key the Worker sends is one the client understands. An unexpected key is not an
    /// error, but it usually means the two sides have drifted.
    @Test("The payload has exactly the expected shape")
    func payloadShape() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: try Self.fixture("answered-prayer"))
                as? [String: Any]
        )

        let expected: Set<String> = [
            "id", "type", "body", "visibility", "status", "createdAt", "updatedAt",
            "answeredAt", "version", "prayerResponseCount", "commentCount", "updateCount",
            "displayProfile", "isMine", "hasPrayed", "link",
        ]
        #expect(Set(raw.keys) == expected)
    }
}

/// Locates the test bundle for `Bundle(for:)`.
private final class BundleToken {}
