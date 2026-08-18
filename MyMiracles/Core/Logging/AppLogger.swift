import Foundation
import OSLog

/// Structured application logging with redaction enforced by the type system.
///
/// The message is a `StaticString`, so user-authored content — a prayer body, a journal
/// entry, a comment — **cannot** be interpolated into a log line. Attaching context is
/// done through ``LogMetadataValue``, whose cases are limited to values that are safe to
/// persist. Rule 7 stops being a convention and becomes a compile error.
nonisolated protocol AppLogger: Sendable {
    func write(
        _ level: LogLevel,
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue],
        file: StaticString,
        line: UInt
    )
}

nonisolated extension AppLogger {
    func debug(
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        write(.debug, message, category: category, metadata: metadata, file: file, line: line)
    }

    func info(
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        write(.info, message, category: category, metadata: metadata, file: file, line: line)
    }

    func warning(
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        write(.warning, message, category: category, metadata: metadata, file: file, line: line)
    }

    func error(
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        write(.error, message, category: category, metadata: metadata, file: file, line: line)
    }

    func fault(
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        write(.fault, message, category: category, metadata: metadata, file: file, line: line)
    }
}

nonisolated enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error, fault

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }
}

/// One subsystem category per `Core/` concern, so Console filtering matches the
/// architecture.
nonisolated enum LogCategory: String, Sendable, CaseIterable {
    case app
    case analytics
    case authentication
    case configuration
    case database
    case moderation
    case network
    case notifications
    case persistence
    case security
    case subscription
}

/// Values that may accompany a log line.
///
/// There is deliberately no `case string(String)`. Free-form text is exactly how a
/// prayer body ends up in a diagnostic archive. Use ``symbol(_:)`` for compile-time
/// labels, ``id(_:)`` for record identifiers, and ``redacted`` to record that a value
/// existed without recording the value.
nonisolated enum LogMetadataValue: Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// A compile-time constant label, such as an enum case name.
    case symbol(StaticString)
    /// A record identifier. Truncated in production so archives cannot be used to
    /// reconstruct a user's activity.
    case id(UUID)
    /// Marks the presence of a sensitive value without disclosing it.
    case redacted
    /// An allowlisted analytics event. ``AnalyticsEventSummary`` can only be built from
    /// an ``AnalyticsEvent``, so this case cannot smuggle in user-authored text.
    case analytics(AnalyticsEventSummary)

    func rendered(truncatingIdentifiers: Bool) -> String {
        switch self {
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        case .symbol(let value): value.description
        case .id(let value):
            truncatingIdentifiers ? String(value.uuidString.prefix(8)) + "…" : value.uuidString
        case .redacted: "<redacted>"
        case .analytics(let summary): summary.rendered
        }
    }
}

/// Written by hand because `StaticString` is not `Equatable`, so the conformance cannot be
/// synthesized. Comparison is on the rendered form, which is what tests assert against.
nonisolated extension LogMetadataValue: Equatable {
    static func == (lhs: LogMetadataValue, rhs: LogMetadataValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let left), .int(let right)): left == right
        case (.double(let left), .double(let right)): left == right
        case (.bool(let left), .bool(let right)): left == right
        case (.symbol(let left), .symbol(let right)): left.description == right.description
        case (.id(let left), .id(let right)): left == right
        case (.redacted, .redacted): true
        case (.analytics(let left), .analytics(let right)): left == right
        default: false
        }
    }
}

// MARK: - OSLog

/// Default logger. Writes to the unified logging system under
/// `com.mymiracles.MyMiracles`.
nonisolated struct OSLogAppLogger: AppLogger {
    private let subsystem: String
    private let minimumLevel: LogLevel
    private let truncatesIdentifiers: Bool

    init(environment: AppEnvironment, subsystem: String = "com.mymiracles.MyMiracles") {
        self.subsystem = subsystem
        self.minimumLevel = environment.allowsVerboseDiagnostics ? .debug : .info
        self.truncatesIdentifiers = environment.isProduction
    }

    func write(
        _ level: LogLevel,
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue],
        file: StaticString,
        line: UInt
    ) {
        guard level >= minimumLevel else { return }

        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        let rendered = LogLineFormatter.render(
            level: level,
            message: message,
            metadata: metadata,
            file: file,
            line: line,
            truncatingIdentifiers: truncatesIdentifiers
        )
        logger.log(level: level.osLogType, "\(rendered, privacy: .public)")
    }
}

nonisolated enum LogLineFormatter {
    static func render(
        level: LogLevel,
        message: StaticString,
        metadata: [String: LogMetadataValue],
        file: StaticString,
        line: UInt,
        truncatingIdentifiers: Bool
    ) -> String {
        var rendered = "[\(level.label)] \(message.description)"
        if !metadata.isEmpty {
            // Sorted so output is deterministic and testable.
            let pairs = metadata.keys.sorted().map { key in
                "\(key)=\(metadata[key]!.rendered(truncatingIdentifiers: truncatingIdentifiers))"
            }
            rendered += " {" + pairs.joined(separator: " ") + "}"
        }
        rendered += " (\(file.description):\(line))"
        return rendered
    }
}

/// Discards everything. For SwiftUI previews and tests that do not assert on logging.
nonisolated struct NoopAppLogger: AppLogger {
    init() {}

    func write(
        _ level: LogLevel,
        _ message: StaticString,
        category: LogCategory,
        metadata: [String: LogMetadataValue],
        file: StaticString,
        line: UInt
    ) {}
}
