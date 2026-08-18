import Foundation

/// The complete set of analytics events My Miracles is allowed to emit.
///
/// This is a closed enum with enum-typed associated values and no free-form `String`
/// payload anywhere. Adding `prayer.body` to an event is not a code-review catch — it
/// does not compile. That is the point: rule 7, and the promise that we do not monetize
/// the substance of a person's prayers.
///
/// See the allowlist in `docs/architecture.md`.
nonisolated enum AnalyticsEvent: Sendable, Equatable {
    case onboardingCompleted
    case prayerCreated(visibility: Visibility, anonymous: Bool)
    case miracleCreated(visibility: Visibility)
    case gratitudeCreated(visibility: Visibility)
    case prayerResponseCreated
    case prayerUpdatePosted
    case prayerMarkedAnswered(daysOpen: DaysOpenBucket)
    case journalOpened
    case memoryResurfaced
    case notificationOpened(type: NotificationKind)
    case notificationPreferenceChanged(category: NotificationKind, enabled: Bool)
    case reportSubmitted
    case userBlocked
    case subscriptionStarted(tier: SubscriptionTier)
    case accountDeletionRequested

    /// Visibility of the affected content. Never the content itself.
    nonisolated enum Visibility: String, Sendable, CaseIterable {
        case privateOnly = "private"
        case followers
        case publicFeed = "public"
    }

    /// How long a prayer stayed open, bucketed. A precise duration combined with a
    /// timestamp would re-identify a specific prayer.
    nonisolated enum DaysOpenBucket: String, Sendable, CaseIterable {
        case sameDay = "0"
        case upToWeek = "1_7"
        case upToMonth = "8_30"
        case upToQuarter = "31_90"
        case beyondQuarter = "91_plus"

        init(days: Int) {
            self = switch days {
            case ..<1: .sameDay
            case 1...7: .upToWeek
            case 8...30: .upToMonth
            case 31...90: .upToQuarter
            default: .beyondQuarter
            }
        }
    }

    nonisolated enum NotificationKind: String, Sendable, CaseIterable {
        case prayed
        case comment
        case answered
        case memory
        case prayerWindow = "prayer_window"
    }

    nonisolated enum SubscriptionTier: String, Sendable, CaseIterable {
        case plus
        case patron
    }

    var name: String {
        switch self {
        case .onboardingCompleted: "onboarding_completed"
        case .prayerCreated: "prayer_created"
        case .miracleCreated: "miracle_created"
        case .gratitudeCreated: "gratitude_created"
        case .prayerResponseCreated: "prayer_response_created"
        case .prayerUpdatePosted: "prayer_update_posted"
        case .prayerMarkedAnswered: "prayer_marked_answered"
        case .journalOpened: "journal_opened"
        case .memoryResurfaced: "memory_resurfaced"
        case .notificationOpened: "notification_opened"
        case .notificationPreferenceChanged: "notification_preference_changed"
        case .reportSubmitted: "report_submitted"
        case .userBlocked: "user_blocked"
        case .subscriptionStarted: "subscription_started"
        case .accountDeletionRequested: "account_deletion_requested"
        }
    }

    /// Every parameter value originates in an enum or a `Bool`. There is no path from
    /// user-authored text to this dictionary.
    var parameters: [String: String] {
        switch self {
        case .onboardingCompleted,
             .prayerResponseCreated,
             .prayerUpdatePosted,
             .journalOpened,
             .memoryResurfaced,
             .reportSubmitted,
             .userBlocked,
             .accountDeletionRequested:
            [:]
        case .prayerCreated(let visibility, let anonymous):
            ["visibility": visibility.rawValue, "anonymous": String(anonymous)]
        case .miracleCreated(let visibility), .gratitudeCreated(let visibility):
            ["visibility": visibility.rawValue]
        case .prayerMarkedAnswered(let bucket):
            ["days_open_bucket": bucket.rawValue]
        case .notificationOpened(let type):
            ["type": type.rawValue]
        case .notificationPreferenceChanged(let category, let enabled):
            ["category": category.rawValue, "enabled": String(enabled)]
        case .subscriptionStarted(let tier):
            ["tier": tier.rawValue]
        }
    }
}
