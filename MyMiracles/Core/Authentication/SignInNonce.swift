import CryptoKit
import Foundation

/// A single-use nonce for Sign in with Apple.
///
/// The flow is a three-way handshake. The app generates a random value, hands Apple its
/// SHA-256, and sends the original to the Worker; Apple echoes the hash back inside the
/// signed identity token, and the Worker checks that hashing what it received reproduces
/// what Apple signed.
///
/// The point is replay protection: a token captured from one sign-in cannot be presented
/// again, because the Worker will be expecting a different nonce.
///
/// Both sides hash to **lowercase hex**. Apple echoes the string verbatim, so a mismatch in
/// encoding would break every sign-in — see `workers/src/auth/apple.ts`.
nonisolated struct SignInNonce: Sendable, Equatable {
    /// Sent to the Worker.
    let raw: String
    /// Sent to Apple as `ASAuthorizationAppleIDRequest.nonce`.
    let hashed: String

    init() {
        let raw = Self.randomString()
        self.raw = raw
        self.hashed = Self.sha256Hex(raw)
    }

    /// Deterministic initializer for tests.
    init(raw: String) {
        self.raw = raw
        self.hashed = Self.sha256Hex(raw)
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 32 bytes from the system CSPRNG, hex-encoded.
    private static func randomString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes failing means the platform CSPRNG is unavailable. There is
            // no safe weaker fallback for a value whose whole job is unpredictability.
            preconditionFailure("the system random number generator is unavailable")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
