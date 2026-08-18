import AuthenticationServices
import Foundation
import Observation

/// Owns the sign-in journey and the app's authentication state.
///
/// The view renders `state` and sends intent; every decision lives here (rule 17). The
/// model never touches the network directly — it goes through ``AuthenticationRepository``,
/// so the whole journey is testable against a fake without a simulator or an Apple ID.
@MainActor
@Observable
final class AuthenticationModel {
    private(set) var state: AuthenticationState
    private(set) var isWorking = false
    private(set) var error: AppError?

    private let repository: any AuthenticationRepository
    private let sessions: SessionManager
    private let analytics: any AnalyticsClient
    private let logger: any AppLogger

    /// Held between building the Apple request and handling its result, so the raw value
    /// can be sent to the Worker while Apple only ever sees the hash.
    private var pendingNonce: SignInNonce?

    init(
        repository: any AuthenticationRepository,
        sessions: SessionManager,
        analytics: any AnalyticsClient,
        logger: any AppLogger,
        initialState: AuthenticationState = .restoring
    ) {
        self.repository = repository
        self.sessions = sessions
        self.analytics = analytics
        self.logger = logger
        self.state = initialState
    }

    /// Restores a stored session at launch and confirms it still works.
    func restore() async {
        guard await sessions.restore() != nil else {
            state = .signedOut
            return
        }

        do {
            let me = try await repository.me()
            state = me.profile.map(AuthenticationState.signedIn) ?? .signedInWithoutProfile
        } catch {
            // A refused session is not an error worth showing anyone — it just means
            // signing in again. Anything else leaves the stored session alone so a flaky
            // network does not sign someone out of their journal.
            if error.kind == .notAuthenticated {
                await sessions.clear()
                state = .signedOut
            } else {
                logger.warning("could not confirm session at launch", category: .authentication)
                state = .signedOut
            }
        }
    }

    // MARK: - Sign in with Apple

    /// Configures the request. Apple receives only the hashed nonce.
    func prepare(request: ASAuthorizationAppleIDRequest) {
        let nonce = SignInNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce.hashed
    }

    func handle(result: Result<ASAuthorization, any Error>) async {
        error = nil

        switch result {
        case .failure(let failure):
            // Tapping Cancel is not a failure and must not raise an alert.
            if (failure as? ASAuthorizationError)?.code == .canceled { return }
            logger.warning("Sign in with Apple failed", category: .authentication)
            error = AppError(kind: .unexpected, diagnostic: String(describing: failure))

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let nonce = pendingNonce
            else {
                error = AppError(kind: .unexpected, diagnostic: "missing Apple identity token")
                return
            }

            await signIn(identityToken: identityToken, nonce: nonce)
        }
    }

    /// The sign-in exchange itself, separated from unwrapping Apple's credential.
    ///
    /// Internal rather than private so tests can drive the real path without fabricating an
    /// `ASAuthorization` — this is the code that ships, not a test-only shortcut.
    func signIn(identityToken: String, nonce: SignInNonce) async {
        isWorking = true
        defer { isWorking = false; pendingNonce = nil }

        do {
            let response = try await repository.signInWithApple(
                identityToken: identityToken,
                nonce: nonce.raw
            )
            await sessions.adopt(Session(response: response))
            state = response.profile.map(AuthenticationState.signedIn) ?? .signedInWithoutProfile
        } catch {
            self.error = error
        }
    }

    // MARK: - Onboarding

    func claimProfile(username: String, displayName: String) async {
        isWorking = true
        defer { isWorking = false }
        error = nil

        do {
            let profile = try await repository.claimProfile(
                username: username,
                displayName: displayName,
                bio: nil
            )
            state = .signedIn(profile)
            analytics.track(.onboardingCompleted)
        } catch {
            self.error = error
        }
    }

    // MARK: - Leaving

    func signOut() async {
        if let session = await sessions.currentSession {
            // Best effort. If the network refuses, the local session still goes away —
            // "sign out" must never leave someone signed in.
            try? await repository.signOut(refreshToken: session.refreshToken)
        }
        await sessions.clear()
        state = .signedOut
    }

    func requestAccountDeletion() async -> Date? {
        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await repository.requestAccountDeletion()
            analytics.track(.accountDeletionRequested)
            await sessions.clear()
            state = .signedOut
            return response.scheduledFor
        } catch {
            self.error = error
            return nil
        }
    }

    func dismissError() {
        error = nil
    }
}
