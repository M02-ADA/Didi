import XCTest

/// The LaserHeist journey through real taps (Sketch "Hi-Fi Revisi 6 NOV"):
/// Home, the two Set Up steps and calibration with Back at each, a round,
/// Results, and Back to Home. Waits on UI state only, never a fixed delay.
final class LaserHeistJourneyUITests: XCTestCase {
    /// An upper bound for a slow Simulator, not an expected duration.
    private let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testHomeSetUpCalibrationRoundResultsAndBackToHome() {
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["startMission"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "the app did not open on Home")
        let next = app.buttons["setupNext"]
        let back = app.buttons["navigationBack"]
        let skip = app.buttons["debugSkipCalibration"]
        let setUpTitle = app.staticTexts["Put your iPad on the Floor"]

        // Home › Set Up and back.
        start.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "START MISSION did not open Set Up")
        XCTAssertTrue(setUpTitle.exists)
        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back on Set Up step 1 did not return Home")

        // Through both Set Up steps to calibration, then one step back and forward again.
        start.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout))
        next.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout))
        next.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: timeout), "Set Up did not lead to calibration")
        XCTAssertFalse(next.exists, "calibration has no Next: it moves on only when calibrated")
        back.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Back on calibration did not return to Set Up")
        next.tap()
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))

        // Round › Results › Back to Home.
        skip.tap()
        let end = app.buttons["endRound"]
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "calibration did not start a round")
        end.tap()
        let home = app.buttons["backToHome"]
        XCTAssertTrue(home.waitForExistence(timeout: timeout), "Results offered no Back to Home")
        XCTAssertTrue(app.buttons["retryRound"].exists, "Results offered no Play Again")
        home.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back to Home did not return Home")
        XCTAssertFalse(end.exists, "the round is still running behind Home")
    }

    /// A completed replay round celebrates, then shows the score; Play Again
    /// starts a new round with no celebration left over.
    func testACompletedRoundCelebratesThenShowsTheScore() {
        let app = XCUIApplication()
        app.launch()
        LaserHeistJourney.enterRound(app, timeout: timeout)
        let celebration = app.descendants(matching: .any)["resultsCelebration"]
        // The replay round runs to its end by itself (about 40 s of game time).
        XCTAssertTrue(celebration.waitForExistence(timeout: 120), "a completed round showed no celebration")
        let retry = app.buttons["retryRound"]
        XCTAssertTrue(retry.waitForExistence(timeout: timeout), "the celebration did not lead to the score")
        XCTAssertFalse(celebration.exists)
        retry.tap()
        XCTAssertTrue(app.buttons["endRound"].waitForExistence(timeout: timeout), "Play Again did not start a round")
        XCTAssertFalse(celebration.exists, "the celebration outlived its round")
    }
}
