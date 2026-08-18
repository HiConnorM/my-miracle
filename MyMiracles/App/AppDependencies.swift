import Foundation
import SwiftUI

/// The composition root.
///
/// Everything a feature needs is resolved here once, at launch, and handed down the
/// SwiftUI environment. Dependencies are declared as protocol existentials so a feature
/// model can be tested against a fake without touching the network (rule 17, rule 18 — no
/// global singletons, no Redux-style store).
@MainActor
final class AppDependencies {
    let configuration: AppConfiguration
    let logger: any AppLogger
    let analytics: any AnalyticsClient
    /// The authenticated path to the backend. There is no client-side database and no
    /// platform credential — see `docs/architecture.md`.
    let api: any APIClient
    let sessions: SessionManager
    let authentication: any AuthenticationRepository

    init(
        configuration: AppConfiguration,
        logger: any AppLogger,
        analytics: any AnalyticsClient,
        api: any APIClient,
        sessions: SessionManager,
        authentication: any AuthenticationRepository
    ) {
        self.configuration = configuration
        self.logger = logger
        self.analytics = analytics
        self.api = api
        self.sessions = sessions
        self.authentication = authentication
    }

    /// Wiring for a real build.
    ///
    /// The order matters and is not arbitrary. The unauthenticated client depends on
    /// nothing; the refresher needs only that; the session manager needs the refresher; the
    /// authenticated client needs the session manager for its bearer token. Building them
    /// in that order is what keeps the graph acyclic — see ``HTTPSessionRefresher``.
    static func live(configuration: AppConfiguration) -> AppDependencies {
        let logger = OSLogAppLogger(environment: configuration.environment)

        // No vendor analytics is wired up yet, and the default outside development stays
        // "emit nothing" — a safe default for a product built on private prayer content.
        let analytics: any AnalyticsClient = configuration.environment == .development
            ? LoggingAnalyticsClient(logger: logger)
            : NoopAnalyticsClient()

        let unauthenticated = HTTPAPIClient(
            baseURL: configuration.apiBaseURL,
            tokens: AnonymousSessionTokenProvider(),
            logger: logger
        )

        let sessions = SessionManager(
            store: KeychainStore(),
            refresher: HTTPSessionRefresher(unauthenticatedClient: unauthenticated),
            logger: logger
        )

        let api = HTTPAPIClient(
            baseURL: configuration.apiBaseURL,
            tokens: sessions,
            logger: logger
        )

        return AppDependencies(
            configuration: configuration,
            logger: logger,
            analytics: analytics,
            api: api,
            sessions: sessions,
            authentication: HTTPAuthenticationRepository(
                unauthenticated: unauthenticated,
                authenticated: api
            )
        )
    }

    func makeAuthenticationModel() -> AuthenticationModel {
        AuthenticationModel(
            repository: authentication,
            sessions: sessions,
            analytics: analytics,
            logger: logger
        )
    }
}

#if DEBUG
extension AppDependencies {
    /// For SwiftUI previews and tests. Points at an unreachable host and an in-memory
    /// keychain, so a preview can never write to a real environment or touch a real session.
    static func preview() -> AppDependencies {
        let configuration = AppConfiguration(
            environment: .development,
            apiBaseURL: URL(string: "http://127.0.0.1:8787")!
        )
        let logger = NoopAppLogger()
        let repository = FakeAuthenticationRepository()

        let api = HTTPAPIClient(
            baseURL: configuration.apiBaseURL,
            tokens: AnonymousSessionTokenProvider(),
            logger: logger
        )

        return AppDependencies(
            configuration: configuration,
            logger: logger,
            analytics: NoopAnalyticsClient(),
            api: api,
            sessions: SessionManager(
                store: InMemorySecureStore(),
                refresher: repository,
                logger: logger
            ),
            authentication: repository
        )
    }
}
#endif

extension EnvironmentValues {
    /// `nil` until the composition root injects the container, so a view that reaches for
    /// dependencies outside the app hierarchy fails loudly in development instead of
    /// silently constructing a second one.
    @Entry var dependencies: AppDependencies?
}
