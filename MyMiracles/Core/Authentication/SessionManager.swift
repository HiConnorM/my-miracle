import Foundation

/// Refreshes an expired session. Implemented by `AuthenticationRepository`.
///
/// A separate protocol so ``SessionManager`` does not depend on the authenticated
/// ``APIClient`` — which would be circular, since that client needs the manager to supply
/// its bearer token. The refresh endpoint takes the refresh token in the body and needs no
/// bearer token of its own, so it goes through an unauthenticated client.
nonisolated protocol SessionRefreshing: Sendable {
    func refresh(refreshToken: String) async throws(AppError) -> SessionResponse
}

/// Owns the session and hands out access tokens.
///
/// An `actor` because two screens can hit an expired token at the same moment. Without
/// serialization both would refresh, and the second exchange would present a refresh token
/// the first had already rotated — which the Worker correctly reads as theft and responds
/// to by revoking every session. Concurrent refreshes would sign the person out of their
/// own account.
actor SessionManager: SessionTokenProvider {
    private let store: any SecureStore
    private let refresher: any SessionRefreshing
    private let logger: any AppLogger
    private let storageKey = "session"

    private var session: Session?
    private var inFlightRefresh: Task<Session, any Error>?

    init(store: any SecureStore, refresher: any SessionRefreshing, logger: any AppLogger) {
        self.store = store
        self.refresher = refresher
        self.logger = logger
    }

    /// Reads any persisted session from the Keychain. Called once at launch.
    func restore() -> Session? {
        guard let data = store.read(storageKey) else { return nil }
        guard let restored = try? JSONDecoder().decode(Session.self, from: data) else {
            // Unreadable means a format change or corruption. Drop it rather than leaving
            // the app wedged with something it cannot use.
            logger.warning("stored session could not be decoded", category: .authentication)
            try? store.delete(storageKey)
            return nil
        }
        session = restored
        return restored
    }

    func adopt(_ newSession: Session) {
        session = newSession
        persist(newSession)
    }

    func clear() {
        session = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        try? store.delete(storageKey)
    }

    var currentSession: Session? { session }

    func accessToken() async throws(AppError) -> String? {
        guard let current = session else { return nil }
        guard current.isExpired() else { return current.accessToken }

        do {
            return try await refreshed().accessToken
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.unexpected(error)
        }
    }

    /// Coalesces concurrent refreshes onto one exchange.
    private func refreshed() async throws -> Session {
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        let task = Task<Session, any Error> { [refresher, store, storageKey] in
            guard let current = session else { throw AppError(kind: .notAuthenticated) }

            let response = try await refresher.refresh(refreshToken: current.refreshToken)
            let renewed = Session(response: response)

            // The Worker rotates the refresh token on every exchange, so the new one must
            // be persisted before anything else can use it.
            if let data = try? JSONEncoder().encode(renewed) {
                try? store.save(data, for: storageKey)
            }
            return renewed
        }

        inFlightRefresh = task
        defer { inFlightRefresh = nil }

        do {
            let renewed = try await task.value
            session = renewed
            return renewed
        } catch {
            // A refused refresh means the session is gone for good — expired, signed out
            // elsewhere, or revoked because the token was replayed. Clearing it sends the
            // person to sign-in instead of retrying against a dead session forever.
            if (error as? AppError)?.kind == .notAuthenticated {
                logger.info("session was refused; signing out", category: .authentication)
                clear()
            }
            throw error
        }
    }

    private func persist(_ value: Session) {
        guard let data = try? JSONEncoder().encode(value) else {
            logger.error("session could not be encoded for storage", category: .authentication)
            return
        }
        do {
            try store.save(data, for: storageKey)
        } catch {
            logger.error("session could not be saved to the keychain", category: .authentication)
        }
    }
}
