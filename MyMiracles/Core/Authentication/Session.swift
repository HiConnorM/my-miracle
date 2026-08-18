import Foundation

/// A signed-in session.
///
/// The access token is short-lived and sent with every request. The refresh token is
/// single-use: the Worker rotates it on each exchange and revokes the whole chain if one is
/// ever presented twice, so the client must always persist the newest one it received.
nonisolated struct Session: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(response: SessionResponse, now: Date = Date()) {
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        self.expiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
    }

    /// Treated as expired slightly early, so a request is never sent with a token that
    /// dies in flight.
    static let refreshMargin: TimeInterval = 60

    func isExpired(at moment: Date = Date()) -> Bool {
        moment.addingTimeInterval(Self.refreshMargin) >= expiresAt
    }
}

nonisolated struct SessionResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    var isNewAccount: Bool = false
    var profile: ProfileResponse?

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresIn, isNewAccount, profile
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        isNewAccount = try container.decodeIfPresent(Bool.self, forKey: .isNewAccount) ?? false
        profile = try container.decodeIfPresent(ProfileResponse.self, forKey: .profile)
    }
}

nonisolated struct ProfileResponse: Codable, Sendable, Equatable {
    let username: String
    let displayName: String
    var avatarKey: String?
    var bio: String?
}

nonisolated struct MeResponse: Decodable, Sendable {
    let accountId: String
    let profile: ProfileResponse?
}

/// Where the person is in the sign-in journey.
///
/// `signedInWithoutProfile` is a real state, not an edge case: an account exists from the
/// moment Apple verifies, but a username is chosen during onboarding. Someone can abandon
/// onboarding and come back, and the app has to know to ask again.
nonisolated enum AuthenticationState: Sendable, Equatable {
    case restoring
    case signedOut
    case signedInWithoutProfile
    case signedIn(ProfileResponse)

    var isSignedIn: Bool {
        switch self {
        case .signedInWithoutProfile, .signedIn: true
        case .restoring, .signedOut: false
        }
    }
}
