import Foundation

/// Emits allowlisted product analytics.
///
/// The protocol accepts ``AnalyticsEvent`` and nothing else — there is no
/// `track(_ name: String, properties: [String: Any])` escape hatch, and there must never
/// be one. Any vendor SDK added later is adapted behind this protocol so the allowlist
/// stays the only way in.
nonisolated protocol AnalyticsClient: Sendable {
    func track(_ event: AnalyticsEvent)
}

/// Default for production until a vendor is chosen. Emitting nothing is a safe default
/// for a product built on private prayer content.
nonisolated struct NoopAnalyticsClient: AnalyticsClient {
    init() {}
    func track(_ event: AnalyticsEvent) {}
}

/// Development aid: routes events to the unified log so the allowlist can be verified by
/// eye during a build. Never used in production.
nonisolated struct LoggingAnalyticsClient: AnalyticsClient {
    private let logger: any AppLogger

    init(logger: any AppLogger) {
        self.logger = logger
    }

    func track(_ event: AnalyticsEvent) {
        logger.info(
            "analytics event",
            category: .analytics,
            metadata: ["event": .analytics(AnalyticsEventSummary(event))]
        )
    }
}

/// A rendered analytics event that is safe to log.
///
/// The only initializer takes an ``AnalyticsEvent``, and that enum's parameters are all
/// enum raw values or booleans. So a summary cannot contain user-authored text — which
/// is what makes ``LogMetadataValue/analytics(_:)`` safe to expose.
nonisolated struct AnalyticsEventSummary: Sendable, Equatable {
    let rendered: String

    init(_ event: AnalyticsEvent) {
        let parameters = event.parameters
        let pairs = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }
        rendered = pairs.isEmpty ? event.name : ([event.name] + pairs).joined(separator: " ")
    }
}
