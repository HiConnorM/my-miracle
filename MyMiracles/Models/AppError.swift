import Foundation

/// The single error type features present to people.
///
/// Underlying failures are mapped here at the repository boundary. The original
/// description is kept ``Redacted`` because server and decoding errors routinely echo
/// request payloads — which in this app means prayer and journal text (rule 7).
nonisolated struct AppError: Error, Identifiable, Equatable, Sendable {
    nonisolated enum Kind: String, Sendable, CaseIterable {
        /// No usable connection. The work is queued, not lost.
        case offline
        case timedOut
        case notFound
        /// The server refused. In this app that usually means an RLS policy said no,
        /// which is a correct outcome, not a bug to work around (rule 6).
        case permissionDenied
        case notAuthenticated
        case conflict
        case rateLimited
        case server
        case configuration
        case unexpected
    }

    let id: UUID
    let kind: Kind
    /// Diagnostic detail for logs and bug reports only. Never rendered in the UI.
    let diagnostic: Redacted<String>?

    init(kind: Kind, diagnostic: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.diagnostic = diagnostic.map(Redacted.init)
    }

    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.kind == rhs.kind
    }
}

nonisolated extension AppError {
    /// Short, human, non-technical. No error codes, no stack traces, no blame.
    var title: String {
        switch kind {
        case .offline: "You're offline"
        case .timedOut: "That took too long"
        case .notFound: "Not found"
        case .permissionDenied: "Not available"
        case .notAuthenticated: "Please sign in again"
        case .conflict: "Something changed"
        case .rateLimited: "Slow down a moment"
        case .server, .unexpected: "Something went wrong"
        case .configuration: "This build isn't configured"
        }
    }

    var message: String {
        switch kind {
        case .offline: "We'll finish this as soon as you're back online. Nothing is lost."
        case .timedOut: "The connection is slow right now. Try again in a moment."
        case .notFound: "This may have been removed by the person who shared it."
        case .permissionDenied: "You don't have access to this."
        case .notAuthenticated: "Your session expired. Signing in again will restore everything."
        case .conflict: "This was updated somewhere else. Refresh to see the latest."
        case .rateLimited: "You've done that a lot in a short time. Try again shortly."
        case .server: "This is on our side, not yours. Please try again."
        case .configuration: "Supabase credentials are missing or invalid for this build."
        case .unexpected: "Please try again."
        }
    }

    var isRetryable: Bool {
        switch kind {
        case .offline, .timedOut, .rateLimited, .server, .unexpected, .conflict: true
        case .notFound, .permissionDenied, .notAuthenticated, .configuration: false
        }
    }

    /// True when the user's work is safely queued and will be sent later, so the UI can
    /// say "waiting to sync" instead of showing a failure.
    var isPending: Bool { kind == .offline }
}

nonisolated extension AppError {
    init(configurationError: AppConfiguration.LoadError) {
        self.init(kind: .configuration, diagnostic: configurationError.localizedDescription)
    }

    /// Last-resort mapping for an unrecognised error.
    static func unexpected(_ error: some Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return AppError(kind: .timedOut) }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed:
                return AppError(kind: .offline, diagnostic: nsError.debugDescription)
            case NSURLErrorTimedOut:
                return AppError(kind: .timedOut, diagnostic: nsError.debugDescription)
            default:
                break
            }
        }
        return AppError(kind: .unexpected, diagnostic: nsError.debugDescription)
    }
}
