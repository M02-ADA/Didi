import XCTest

/// Smoke test of the real tap path, which unit tests can't reach: launch,
/// End round, Results, Retry. It waits on UI state only, never a fixed delay.
///
/// `endRound` appears only after a new scene has been built and its session
/// started, and it is gone while Results shows. Its return after Retry
/// therefore means Retry built a new round. What each round contains is
/// covered by `RoundLifecycleTests`.
///
/// PENDING Jevon: when the session offers pause, `endRound` moves into the
/// HUD's pause menu, and this test must follow it.
final class RoundSmokeUITests: XCTestCase {
    /// An upper bound for a slow Simulator, not an expected duration.
    private let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testLaunchEndRoundAndRetryBuildANewRound() {
        let app = XCUIApplication()
        app.launchArguments = ["-replay"]
        app.launch()
        let end = app.buttons["endRound"]
        let retry = app.buttons["retryRound"]
        let health = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Team health")).firstMatch

        for round in 1...3 {
            XCTAssertTrue(end.waitForExistence(timeout: timeout), "round \(round) did not start")
            XCTAssertTrue(health.waitForExistence(timeout: timeout), "round \(round) has no HUD")
            end.tap()
            XCTAssertTrue(retry.waitForExistence(timeout: timeout), "round \(round) showed no results")
            XCTAssertFalse(end.exists, "round \(round) is still running behind its results")
            retry.tap()
        }
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "the round after the last Retry did not start")
    }

    func testInputSelectionCanOpenReplayAndReturnWithoutStartingCamera() {
        let app = XCUIApplication()
        app.launch()
        let replay = app.buttons["chooseReplay"]
        let camera = app.buttons["chooseLive"]
        XCTAssertTrue(replay.waitForExistence(timeout: timeout))
        XCTAssertTrue(camera.exists && camera.isEnabled)
        XCTAssertFalse(app.buttons["endRound"].exists)
        replay.tap()
        XCTAssertTrue(app.buttons["endRound"].waitForExistence(timeout: timeout))
        let back = app.buttons["leaveReplay"]
        XCTAssertTrue(back.waitForExistence(timeout: timeout))
        back.tap()
        XCTAssertTrue(replay.waitForExistence(timeout: timeout))
        XCTAssertTrue(camera.isEnabled)
        XCTAssertFalse(app.buttons["endRound"].exists)
    }
}
