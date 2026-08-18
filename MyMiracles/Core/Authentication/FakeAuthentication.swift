#if DEBUG
import Foundation

/// Scripted stand-ins for previews and tests.
///
/// Compiled only in DEBUG so none of this reaches a shipped binary. Behaviour is
/// configurable per call so a test can drive the whole sign-in journey — including its
/// failures — without a network, a simulator, or a real Apple ID.
nonisolated final class FakeAuthenticationRepository: AuthenticationRepository,
    SessionRefreshing, @unchecked Sendable
{
    struct Script: Sendable {
        var signIn: Result<SessionResponse, AppError> = .success(.preview())
        var refresh: Result<SessionResponse, AppError> = .success(.preview())
        var me: Result<MeResponse, AppError> = .success(
            MeResponse(accountId: "account-1", profile: nil)
        )
        var claimProfile: Result<ProfileResponse, AppError> = .success(
            ProfileResponse(username: "connor", displayName: "Connor")
        )
        var deletion: Result<AccountDeletionResponse, AppError> = .success(
            AccountDeletionResponse(scheduledFor: .distantFuture, alreadyRequested: false)
        )
    }

    private let lock = NSLock()
    private var script: Script
    private(set) var refreshCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var lastNonce: String?

    init(script: Script = Script()) {
        self.script = script
    }

    func update(_ transform: (inout Script) -> Void) {
        lock.withLock { transform(&script) }
    }

    private func current() -> Script {
        lock.withLock { script }
    }

    func signInWithApple(
        identityToken: String,
        nonce: String
    ) async throws(AppError) -> SessionResponse {
        lock.withLock { lastNonce = nonce }
        return try current().signIn.get()
    }

    func refresh(refreshToken: String) async throws(AppError) -> SessionResponse {
        lock.withLock { refreshCallCount += 1 }
        return try current().refresh.get()
    }

    func signOut(refreshToken: String) async throws(AppError) {
        lock.withLock { signOutCallCount += 1 }
    }

    func me() async throws(AppError) -> MeResponse {
        try current().me.get()
    }

    func claimProfile(
        username: String,
        displayName: String,
        bio: String?
    ) async throws(AppError) -> ProfileResponse {
        try current().claimProfile.get()
    }

    func requestAccountDeletion() async throws(AppError) -> AccountDeletionResponse {
        try current().deletion.get()
    }
}

/// `Result.get()` is untyped-throwing, so this narrows it back to `AppError` for the typed
/// signatures above.
nonisolated private extension Result where Failure == AppError {
    func get() throws(AppError) -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

nonisolated extension SessionResponse {
    static func preview(
        accessToken: String = "preview-access-token",
        refreshToken: String = "preview-refresh-token",
        expiresIn: Int = 900,
        isNewAccount: Bool = false,
        profile: ProfileResponse? = nil
    ) -> SessionResponse {
        let json = """
        {
          "accessToken": "\(accessToken)",
          "refreshToken": "\(refreshToken)",
          "expiresIn": \(expiresIn),
          "isNewAccount": \(isNewAccount)
          \(profile.map { ", \"profile\": { \"username\": \"\($0.username)\", \"displayName\": \"\($0.displayName)\" }" } ?? "")
        }
        """
        return try! JSONDecoder().decode(SessionResponse.self, from: Data(json.utf8))
    }
}

@MainActor
extension AuthenticationModel {
    /// A model wired to fakes, for SwiftUI previews.
    static func preview(
        state: AuthenticationState = .signedOut,
        repository: FakeAuthenticationRepository = FakeAuthenticationRepository()
    ) -> AuthenticationModel {
        let logger = NoopAppLogger()
        return AuthenticationModel(
            repository: repository,
            sessions: SessionManager(
                store: InMemorySecureStore(),
                refresher: repository,
                logger: logger
            ),
            analytics: NoopAnalyticsClient(),
            logger: logger,
            initialState: state
        )
    }
}
#endif
