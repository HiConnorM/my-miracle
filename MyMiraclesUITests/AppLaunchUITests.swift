import XCTest

/// Launch and onboarding smoke tests.
///
/// These run without a Worker reachable, which is deliberate: with no session to restore
/// and no network, the app must land on onboarding rather than hanging on a spinner or
/// showing an error. That is the first-launch experience for anyone on a bad connection.
///
/// `nonisolated` because `XCTestCase`'s initializers and `setUp()` are nonisolated, which
/// clashes with the project's MainActor-by-default isolation. Individual tests opt back in
/// with `@MainActor`.
nonisolated final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesIntoOnboarding() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Remember the moments you never want to forget."]
                .waitForExistence(timeout: 15),
            "The app did not reach onboarding. A configuration failure shows the diagnostic screen instead."
        )
        XCTAssertTrue(
            app.staticTexts["Record miracles, carry prayers, and look back on the good."].exists
        )
    }

    /// The three onboarding steps, in order, ending at Sign in with Apple.
    @MainActor
    func testOnboardingReachesSignIn() {
        let app = XCUIApplication()
        app.launch()

        let firstScreen = app.staticTexts["Remember the moments you never want to forget."]
        XCTAssertTrue(firstScreen.waitForExistence(timeout: 15))

        capture(app, named: "01-welcome")

        app.buttons["Continue"].tap()
        XCTAssertTrue(
            app.staticTexts["What would you like to do?"].waitForExistence(timeout: 5),
            "The intent picker did not appear"
        )
        capture(app, named: "02-intent")

        // Selecting an intent is optional — someone can move on without choosing.
        app.buttons["Ask for prayer"].tap()
        capture(app, named: "03-intent-selected")
        app.buttons["Continue"].tap()

        XCTAssertTrue(
            app.staticTexts["Your journal starts private."].waitForExistence(timeout: 5),
            "The privacy promise did not appear"
        )
        XCTAssertTrue(
            app.staticTexts["You choose what — if anything — to share."].exists
        )
        capture(app, named: "04-privacy-and-signin")
    }

    /// Attaches a screenshot to the result bundle. Kept `.keepAlways` so the flow can be
    /// reviewed after a green run, not only after a failure.
    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Onboarding must not ask for anything before someone has seen any value. A permission
    /// prompt here would be a regression against docs/product-spec.md.
    @MainActor
    func testOnboardingRequestsNoSystemPermissions() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Remember the moments you never want to forget."]
                .waitForExistence(timeout: 15)
        )

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(
            springboard.alerts.count, 0,
            "Onboarding asked for a system permission before showing any value"
        )
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
