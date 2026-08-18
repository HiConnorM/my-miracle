import XCTest

/// Phase 0 smoke test: the app launches and renders its shell.
///
/// Phase 3 replaces this with onboarding and authentication flows; Phase 4 adds the
/// prayer → answered → miracle journey.
/// `nonisolated` because `XCTestCase`'s initializers and `setUp()` are nonisolated, which
/// clashes with the project's MainActor-by-default isolation. Individual tests opt back in
/// with `@MainActor` where they drive the UI.
nonisolated final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsShell() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["My Miracles"].waitForExistence(timeout: 10),
            "The app shell did not appear. A configuration failure shows the diagnostic screen instead."
        )
        XCTAssertTrue(app.staticTexts["Remember the good. Carry each other."].exists)
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
