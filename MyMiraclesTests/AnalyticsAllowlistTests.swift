import Foundation
import Testing
@testable import MyMiracles

/// Rule 7 and the promise that we never monetize the substance of a person's prayers.
///
/// The strongest guarantee here is structural: ``AnalyticsEvent`` is a closed enum whose
/// associated values are enums and booleans, so there is no expression that attaches a
/// prayer body to an event. These tests defend the remaining surface — that the emitted
/// names and parameter values stay inside the documented allowlist.
@Suite("Analytics allowlist")
nonisolated struct AnalyticsAllowlistTests {
    static let allEvents: [AnalyticsEvent] = [
        .onboardingCompleted,
        .prayerCreated(visibility: .privateOnly, anonymous: true),
        .prayerCreated(visibility: .publicFeed, anonymous: false),
        .miracleCreated(visibility: .followers),
        .gratitudeCreated(visibility: .privateOnly),
        .prayerResponseCreated,
        .prayerUpdatePosted,
        .prayerMarkedAnswered(daysOpen: .upToMonth),
        .journalOpened,
        .memoryResurfaced,
        .notificationOpened(type: .answered),
        .notificationPreferenceChanged(category: .prayed, enabled: false),
        .reportSubmitted,
        .userBlocked,
        .subscriptionStarted(tier: .plus),
        .accountDeletionRequested,
    ]

    /// Exactly the allowlist in `docs/architecture.md`. Adding an event is a deliberate
    /// act that updates this set.
    static let allowedNames: Set<String> = [
        "onboarding_completed",
        "prayer_created",
        "miracle_created",
        "gratitude_created",
        "prayer_response_created",
        "prayer_update_posted",
        "prayer_marked_answered",
        "journal_opened",
        "memory_resurfaced",
        "notification_opened",
        "notification_preference_changed",
        "report_submitted",
        "user_blocked",
        "subscription_started",
        "account_deletion_requested",
    ]

    static let allowedParameterKeys: Set<String> = [
        "visibility", "anonymous", "days_open_bucket", "type", "category", "enabled", "tier",
    ]

    @Test("Every event name is on the allowlist", arguments: allEvents)
    func namesAreAllowlisted(event: AnalyticsEvent) {
        #expect(Self.allowedNames.contains(event.name))
    }

    @Test("Every parameter key is on the allowlist", arguments: allEvents)
    func parameterKeysAreAllowlisted(event: AnalyticsEvent) {
        for key in event.parameters.keys {
            #expect(Self.allowedParameterKeys.contains(key), "unexpected parameter key \(key)")
        }
    }

    /// Parameter values must be short enum tokens. A body, a name, or an email would blow
    /// past this and would not match the token shape.
    @Test("Every parameter value is a short enum token", arguments: allEvents)
    func parameterValuesAreTokens(event: AnalyticsEvent) {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        for (key, value) in event.parameters {
            #expect(value.count <= 24, "\(key) value is too long to be an enum token")
            #expect(
                value.unicodeScalars.allSatisfy(permitted.contains),
                "\(key)=\(value) is not a lowercase enum token"
            )
        }
    }

    @Test("Event names are unique per case")
    func namesAreDistinctPerCase() {
        #expect(Set(Self.allEvents.map(\.name)).count == Self.allowedNames.count)
    }

    @Test(
        "Days-open bucketing is inclusive at each boundary",
        arguments: [
            (0, AnalyticsEvent.DaysOpenBucket.sameDay),
            (1, .upToWeek), (7, .upToWeek),
            (8, .upToMonth), (30, .upToMonth),
            (31, .upToQuarter), (90, .upToQuarter),
            (91, .beyondQuarter), (4_000, .beyondQuarter),
        ]
    )
    func bucketBoundaries(days: Int, expected: AnalyticsEvent.DaysOpenBucket) {
        #expect(AnalyticsEvent.DaysOpenBucket(days: days) == expected)
    }

    @Test("The no-op client is inert")
    func noopClientEmitsNothing() {
        let client = NoopAnalyticsClient()
        for event in Self.allEvents { client.track(event) }
    }
}
