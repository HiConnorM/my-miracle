import Foundation

/// Immutable, validated configuration for one build.
///
/// Values originate in `Config/*.xcconfig`, land in `Config/Info.plist` at build time, and
/// are read once at launch. Nothing here is fetched at runtime and nothing is user-editable.
///
/// Note what is **absent**: there is no key, token or database credential. On Cloudflare
/// the app talks only to the Worker API, and an unauthenticated request gets nothing. The
/// strongest form of engineering rule 4 is that there is no secret in the bundle to leak.
nonisolated struct AppConfiguration: Sendable {
    let environment: AppEnvironment
    let apiBaseURL: URL
}

nonisolated extension AppConfiguration {
    enum InfoKey: String, CaseIterable {
        case environment = "MMEnvironment"
        case apiBaseURL = "MMAPIBaseURL"
    }

    enum LoadError: Error, Equatable, LocalizedError {
        case missingValue(InfoKey)
        case unknownEnvironment(String)
        case malformedURL(String)
        /// Plaintext HTTP outside development.
        case insecureTransport(String)
        /// Something credential-shaped is baked into the app bundle.
        case embeddedCredential(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let key):
                "\(key.rawValue) is missing. Copy Config/Secrets.example.xcconfig to Config/Secrets.Debug.xcconfig and fill it in."
            case .unknownEnvironment(let raw):
                "MMEnvironment is \"\(raw)\", which is not one of development, staging or production."
            case .malformedURL(let raw):
                "MMAPIBaseURL is not a valid URL: \"\(raw)\". Compose URLs with $(MM_SLASH) — a literal // starts a comment in xcconfig."
            case .insecureTransport(let raw):
                "MMAPIBaseURL is \"\(raw)\". Only development may use plaintext HTTP."
            case .embeddedCredential(let key):
                "\(key) looks like a credential embedded in the app bundle. This violates engineering rule 4 — server secrets belong in Worker secrets, never in the client."
            }
        }
    }

    /// Reads and validates configuration from a bundle's Info.plist.
    static func load(from bundle: Bundle = .main) throws(LoadError) -> AppConfiguration {
        try load(
            values: { bundle.object(forInfoDictionaryKey: $0.rawValue) as? String },
            info: bundle.infoDictionary ?? [:]
        )
    }

    /// Validation seam. Tests drive this directly instead of building a stub bundle.
    static func load(
        values: (InfoKey) -> String?,
        info: [String: Any] = [:]
    ) throws(LoadError) -> AppConfiguration {
        func string(_ key: InfoKey) throws(LoadError) -> String {
            let raw = values(key)?.trimmingCharacters(in: .whitespaces)
            guard let raw, !raw.isEmpty else {
                throw .missingValue(key)
            }
            return raw
        }

        let rawEnvironment = try string(.environment)
        guard let environment = AppEnvironment(rawValue: rawEnvironment) else {
            throw .unknownEnvironment(rawEnvironment)
        }

        let rawURL = try string(.apiBaseURL)
        guard let url = URL(string: rawURL), let scheme = url.scheme, url.host() != nil else {
            throw .malformedURL(rawURL)
        }
        // Staging and production carry real prayer content. Plaintext is only ever
        // acceptable against a Worker running on localhost.
        guard scheme == "https" || environment == .development else {
            throw .insecureTransport(rawURL)
        }

        if let leaked = EmbeddedCredentialInspector.firstSuspiciousKey(in: info) {
            throw .embeddedCredential(leaked)
        }

        return AppConfiguration(environment: environment, apiBaseURL: url)
    }
}

/// Runtime tripwire for engineering rule 4.
///
/// The Cloudflare architecture means the client should hold no backend secret at all, so
/// rather than validating one credential this looks for any credential appearing where
/// none belongs. It runs at launch because a secret in an app bundle is extractable by
/// anyone who downloads the app, and a code review will eventually miss one.
nonisolated enum EmbeddedCredentialInspector {
    /// Value prefixes that are unambiguously private credentials.
    static let credentialPrefixes = [
        "sb_secret_",     // Supabase secret key
        "sk_", "sk-",     // Stripe / OpenAI style secret keys
        "rk_",            // Stripe restricted key
        "AKIA",           // AWS access key id
        "-----BEGIN",     // PEM private key or certificate
        "ghp_", "gho_",   // GitHub tokens
    ]

    /// Substrings in an app-owned key name that imply the value is private. A *public*
    /// SDK key (RevenueCat's, for instance) is legitimately shipped in a binary and is
    /// named accordingly, so naming is a reliable signal here.
    static let privateNameFragments = ["secret", "password", "privatekey", "private_key"]

    static func firstSuspiciousKey(in info: [String: Any]) -> String? {
        for key in info.keys.sorted() {
            guard let value = info[key] as? String, !value.isEmpty else { continue }

            if key.hasPrefix("MM"), isPrivateName(key) {
                return key
            }
            if credentialPrefixes.contains(where: value.hasPrefix) {
                return key
            }
            if let role = jwtRole(in: value), role != "anon" {
                return key
            }
        }
        return nil
    }

    static func isPrivateName(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return privateNameFragments.contains { lowered.contains($0) }
    }

    /// Extracts the `role` claim from an unverified JWT payload. Signature verification is
    /// irrelevant — this only needs to spot an obviously wrong credential shape.
    static func jwtRole(in value: String) -> String? {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = base64URLDecode(String(segments[1])) else {
            return nil
        }
        let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return (claims?["role"] as? String)?.lowercased()
    }

    private static func base64URLDecode(_ input: String) -> Data? {
        var value = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 {
            value.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: value)
    }
}
