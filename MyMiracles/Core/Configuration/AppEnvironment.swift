import Foundation

/// Which backend this build talks to.
///
/// Each case maps to a *separate* Supabase project (see `docs/architecture.md`). A build
/// never crosses environments at runtime — the value is fixed at compile time by
/// `Config/<Configuration>.xcconfig`.
nonisolated enum AppEnvironment: String, Sendable, CaseIterable {
    case development
    case staging
    case production

    var isProduction: Bool { self == .production }

    /// Verbose diagnostics, developer menus and console analytics are acceptable outside
    /// production only.
    var allowsVerboseDiagnostics: Bool { self != .production }

    var displayName: String {
        switch self {
        case .development: "Development"
        case .staging: "Staging"
        case .production: "Production"
        }
    }
}
