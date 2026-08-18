import Foundation
import Testing
@testable import MyMiracles

@Suite("Redaction")
nonisolated struct RedactionTests {
    /// Rule 7. If this ever fails, prayer text can reach a log line or a crash report.
    @Test("A redacted value never renders its contents")
    func redactedNeverPrints() {
        let secret = Redacted("Please pray for my marriage.")

        #expect(secret.description == "<redacted>")
        #expect(secret.debugDescription == "<redacted>")
        #expect("\(secret)" == "<redacted>")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
    }

    @Test("Only an explicit reveal returns the value")
    func revealReturnsValue() {
        #expect(Redacted("token").reveal() == "token")
    }

    @Test("Mapping preserves redaction")
    func mapStaysRedacted() {
        let mapped = Redacted("token").map(\.count)
        #expect(mapped.description == "<redacted>")
        #expect(mapped.reveal() == 5)
    }

    @Test("An app error keeps its diagnostic redacted")
    func appErrorDiagnosticIsRedacted() {
        let error = AppError(kind: .server, diagnostic: "body=Please pray for my marriage.")

        #expect(error.diagnostic?.description == "<redacted>")
        #expect(!error.message.contains("marriage"))
        #expect(!error.title.contains("marriage"))
    }
}

@Suite("Log formatting")
nonisolated struct LogFormattingTests {
    @Test("Metadata renders in a deterministic order")
    func deterministicOrdering() {
        let line = LogLineFormatter.render(
            level: .info,
            message: "prayer created",
            metadata: ["zeta": .int(1), "alpha": .bool(true)],
            file: "Prayer.swift",
            line: 12,
            truncatingIdentifiers: false
        )
        #expect(line == "[INFO] prayer created {alpha=true zeta=1} (Prayer.swift:12)")
    }

    @Test("Identifiers are truncated in production")
    func identifiersTruncatedInProduction() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!

        let production = LogMetadataValue.id(id).rendered(truncatingIdentifiers: true)
        let development = LogMetadataValue.id(id).rendered(truncatingIdentifiers: false)

        #expect(production == "12345678…")
        #expect(development == id.uuidString)
    }

    @Test("A redacted marker discloses nothing")
    func redactedMarker() {
        #expect(LogMetadataValue.redacted.rendered(truncatingIdentifiers: false) == "<redacted>")
    }

    /// The analytics metadata case is the only route from a string into a log line, and it
    /// is reachable only through the allowlisted event enum.
    @Test("Analytics metadata carries the event summary and nothing else")
    func analyticsMetadata() {
        let summary = AnalyticsEventSummary(.prayerCreated(visibility: .privateOnly, anonymous: true))
        let rendered = LogMetadataValue.analytics(summary).rendered(truncatingIdentifiers: true)

        #expect(rendered == "prayer_created anonymous=true visibility=private")
    }

    @Test("The default logger discards without crashing")
    func noopLogger() {
        NoopAppLogger().error("boom", category: .app, metadata: ["count": .int(1)])
    }
}
