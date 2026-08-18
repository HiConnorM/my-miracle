import Foundation
import Testing
@testable import MyMiracles

@Suite("App configuration")
nonisolated struct AppConfigurationTests {
    static func values(
        environment: String? = "development",
        url: String? = "http://127.0.0.1:8787"
    ) -> (AppConfiguration.InfoKey) -> String? {
        { key in
            switch key {
            case .environment: environment
            case .apiBaseURL: url
            }
        }
    }

    @Test("Loads a complete, valid configuration")
    func loadsValidConfiguration() throws {
        let configuration = try AppConfiguration.load(values: Self.values())

        #expect(configuration.environment == .development)
        #expect(configuration.apiBaseURL.host() == "127.0.0.1")
        #expect(configuration.apiBaseURL.port == 8787)
    }

    @Test("Every Info.plist key is required", arguments: AppConfiguration.InfoKey.allCases)
    func missingValueFails(missing: AppConfiguration.InfoKey) {
        let source = Self.values()
        #expect(throws: AppConfiguration.LoadError.missingValue(missing)) {
            try AppConfiguration.load(values: { $0 == missing ? nil : source($0) })
        }
    }

    @Test("Whitespace-only values count as missing")
    func blankValueFails() {
        #expect(throws: AppConfiguration.LoadError.missingValue(.apiBaseURL)) {
            try AppConfiguration.load(values: Self.values(url: "   "))
        }
    }

    @Test("An unrecognised environment name is rejected")
    func unknownEnvironmentFails() {
        #expect(throws: AppConfiguration.LoadError.unknownEnvironment("prod")) {
            try AppConfiguration.load(values: Self.values(environment: "prod"))
        }
    }

    /// Guards the xcconfig `//` comment trap: a truncated URL must fail loudly at launch
    /// rather than sending traffic somewhere unexpected.
    @Test("A malformed or truncated URL is rejected", arguments: ["https:", "not a url", "https://"])
    func malformedURLFails(raw: String) {
        #expect(throws: AppConfiguration.LoadError.malformedURL(raw)) {
            try AppConfiguration.load(values: Self.values(url: raw))
        }
    }

    // MARK: - Transport

    @Test("Plaintext HTTP is refused outside development", arguments: ["staging", "production"])
    func plaintextRefusedOutsideDevelopment(environment: String) {
        #expect(throws: AppConfiguration.LoadError.insecureTransport("http://api.example.com")) {
            try AppConfiguration.load(
                values: Self.values(environment: environment, url: "http://api.example.com")
            )
        }
    }

    @Test("HTTPS is accepted everywhere", arguments: ["development", "staging", "production"])
    func httpsAccepted(environment: String) throws {
        let configuration = try AppConfiguration.load(
            values: Self.values(environment: environment, url: "https://api.mymiracles.app")
        )
        #expect(configuration.apiBaseURL.scheme == "https")
    }

    @Test("A local Worker over plaintext is fine in development")
    func plaintextAllowedLocally() throws {
        let configuration = try AppConfiguration.load(values: Self.values())
        #expect(configuration.apiBaseURL.scheme == "http")
    }

    // MARK: - Rule 4: nothing credential-shaped ships in the bundle

    @Test("A credential in the bundle stops the app from launching")
    func embeddedCredentialFails() {
        #expect(throws: AppConfiguration.LoadError.embeddedCredential("MMSessionSecret")) {
            try AppConfiguration.load(
                values: Self.values(),
                info: ["MMSessionSecret": "anything-at-all"]
            )
        }
    }

    @Test(
        "Known private-credential shapes are caught",
        arguments: [
            "sb_secret_abcdefghijklmnop",
            "sk_live_51H8xYzAbCdEf",
            "sk-proj-abcdefghijklmnop",
            "rk_live_abcdefghij",
            "AKIAIOSFODNN7EXAMPLE",
            "-----BEGIN PRIVATE KEY-----",
            "ghp_abcdefghijklmnopqrstuvwxyz",
        ]
    )
    func credentialShapesCaught(value: String) {
        #expect(EmbeddedCredentialInspector.firstSuspiciousKey(in: ["SomeKey": value]) == "SomeKey")
    }

    @Test("A privileged JWT is caught wherever it is hiding")
    func privilegedJWTCaught() {
        let serviceRole = Self.jwt(role: "service_role")
        #expect(EmbeddedCredentialInspector.firstSuspiciousKey(in: ["MMToken": serviceRole]) == "MMToken")
        #expect(EmbeddedCredentialInspector.jwtRole(in: serviceRole) == "service_role")
    }

    /// The inspector must not cry wolf, or it will be disabled the first time it blocks a
    /// legitimate build.
    @Test("Ordinary Info.plist contents are not flagged")
    func noFalsePositives() {
        let info: [String: Any] = [
            "CFBundleName": "MyMiracles",
            "CFBundleIdentifier": "com.mymiracles.MyMiracles",
            "CFBundleShortVersionString": "0.1.0",
            "MMEnvironment": "production",
            "MMAPIBaseURL": "https://api.mymiracles.app",
            // A *public* SDK key is legitimately shipped in a binary.
            "MMRevenueCatPublicKey": "appl_ABCDEFGHIJKLMNOP",
            "MMAnonToken": Self.jwt(role: "anon"),
            "UILaunchScreen": ["UIColorName": "LaunchBackground"],
            "ITSAppUsesNonExemptEncryption": false,
        ]
        #expect(EmbeddedCredentialInspector.firstSuspiciousKey(in: info) == nil)
    }

    @Test("A clean bundle loads normally")
    func cleanBundleLoads() throws {
        let configuration = try AppConfiguration.load(
            values: Self.values(),
            info: ["CFBundleName": "MyMiracles", "MMAPIBaseURL": "http://127.0.0.1:8787"]
        )
        #expect(configuration.environment == .development)
    }

    @Test("Only production suppresses verbose diagnostics")
    func diagnosticPolicy() {
        #expect(AppEnvironment.development.allowsVerboseDiagnostics)
        #expect(AppEnvironment.staging.allowsVerboseDiagnostics)
        #expect(!AppEnvironment.production.allowsVerboseDiagnostics)
        #expect(AppEnvironment.production.isProduction)
    }

    static func jwt(role: String) -> String {
        func segment(_ object: [String: String]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [segment(["alg": "HS256"]), segment(["role": role]), "signature"]
            .joined(separator: ".")
    }
}
