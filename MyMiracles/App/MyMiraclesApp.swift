import SwiftUI

@main
struct MyMiraclesApp: App {
    /// Configuration is resolved once, synchronously, before any UI appears. A build with
    /// missing or invalid credentials shows a diagnostic screen rather than crashing or —
    /// worse — silently pointing at the wrong environment.
    private let bootstrap: Result<AppDependencies, AppConfiguration.LoadError>

    init() {
        // `load()` uses typed throws, so the catch binds a `LoadError` directly — no cast
        // and no unreachable fallback case.
        do {
            bootstrap = .success(AppDependencies.live(configuration: try AppConfiguration.load()))
        } catch {
            bootstrap = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .success(let dependencies):
                RootView()
                    .environment(\.dependencies, dependencies)
            case .failure(let error):
                ConfigurationErrorView(error: error)
            }
        }
    }
}
