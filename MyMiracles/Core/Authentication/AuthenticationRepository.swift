import Foundation

nonisolated protocol AuthenticationRepository: Sendable {
    func signInWithApple(identityToken: String, nonce: String) async throws(AppError) -> SessionResponse
    func signOut(refreshToken: String) async throws(AppError)
    func me() async throws(AppError) -> MeResponse
    func claimProfile(
        username: String,
        displayName: String,
        bio: String?
    ) async throws(AppError) -> ProfileResponse
    func requestAccountDeletion() async throws(AppError) -> AccountDeletionResponse
}

nonisolated struct AccountDeletionResponse: Decodable, Sendable {
    let scheduledFor: Date
    let alreadyRequested: Bool
}

/// Exchanges a refresh token for a new session.
///
/// Split out from ``AuthenticationRepository`` on purpose. ``SessionManager`` needs to
/// refresh, and the authenticated ``APIClient`` needs the session manager for its bearer
/// token — wiring the full repository into the manager would be a cycle. Refresh is the one
/// call that must work *without* a bearer token, so it only ever needs the unauthenticated
/// client and the cycle disappears.
nonisolated struct HTTPSessionRefresher: SessionRefreshing {
    private let client: any APIClient

    /// - Parameter client: an **unauthenticated** client. Passing an authenticated one
    ///   would deadlock: refreshing would wait on a token that is being refreshed.
    init(unauthenticatedClient client: any APIClient) {
        self.client = client
    }

    func refresh(refreshToken: String) async throws(AppError) -> SessionResponse {
        struct Body: Encodable, Sendable { let refreshToken: String }
        return try await client.send(
            APIRequest<SessionResponse>(
                method: .post,
                path: "/v1/auth/refresh",
                body: try APICoding.encode(Body(refreshToken: refreshToken)),
                requiresAuthentication: false
            )
        )
    }
}

/// Talks to the Worker's `/v1/auth` and `/v1/me` routes.
///
/// Takes two clients on purpose. Sign-in and sign-out carry no bearer token — and must
/// not, since sign-in is what produces one. Everything else goes through the authenticated
/// client.
nonisolated struct HTTPAuthenticationRepository: AuthenticationRepository {
    private let unauthenticated: any APIClient
    private let authenticated: any APIClient

    init(unauthenticated: any APIClient, authenticated: any APIClient) {
        self.unauthenticated = unauthenticated
        self.authenticated = authenticated
    }

    func signInWithApple(
        identityToken: String,
        nonce: String
    ) async throws(AppError) -> SessionResponse {
        struct Body: Encodable, Sendable {
            let identityToken: String
            let nonce: String
        }
        return try await unauthenticated.send(
            APIRequest<SessionResponse>(
                method: .post,
                path: "/v1/auth/apple",
                body: try APICoding.encode(Body(identityToken: identityToken, nonce: nonce)),
                requiresAuthentication: false
            )
        )
    }

    func signOut(refreshToken: String) async throws(AppError) {
        struct Body: Encodable, Sendable { let refreshToken: String }
        _ = try await unauthenticated.send(
            APIRequest<EmptyResponse>(
                method: .post,
                path: "/v1/auth/signout",
                body: try APICoding.encode(Body(refreshToken: refreshToken)),
                requiresAuthentication: false
            )
        )
    }

    func me() async throws(AppError) -> MeResponse {
        try await authenticated.send(APIRequest<MeResponse>.get("/v1/me"))
    }

    func claimProfile(
        username: String,
        displayName: String,
        bio: String?
    ) async throws(AppError) -> ProfileResponse {
        struct Body: Encodable, Sendable {
            let username: String
            let displayName: String
            let bio: String?
        }
        return try await authenticated.send(
            APIRequest<ProfileResponse>(
                method: .put,
                path: "/v1/me/profile",
                body: try APICoding.encode(
                    Body(username: username, displayName: displayName, bio: bio)
                )
            )
        )
    }

    func requestAccountDeletion() async throws(AppError) -> AccountDeletionResponse {
        try await authenticated.send(
            APIRequest<AccountDeletionResponse>(method: .delete, path: "/v1/me")
        )
    }
}
