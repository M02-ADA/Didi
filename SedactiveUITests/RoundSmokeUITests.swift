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
        app.launchArguments = ["--synthetic-gameplay-preview"]
        app.launch()
        LaserHeistJourney.enterRound(app, timeout: timeout)
        let end = app.buttons["endRound"]
        let retry = app.buttons["retryRound"]
        let health = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Team health")).firstMatch

        for round in 1...1 {
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
        let camera = app.buttons["startMission"]   // Sketch Home: camera setup follows the two Set Up steps
        XCTAssertTrue(replay.waitForExistence(timeout: timeout))
        XCTAssertTrue(camera.exists && camera.isEnabled)
        XCTAssertFalse(app.buttons["endRound"].exists)
        replay.tap()
        XCTAssertTrue(app.buttons["endRound"].waitForExistence(timeout: timeout))
        let fullRoundProgress = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Vaults opened 0 of 5")).firstMatch
        XCTAssertTrue(fullRoundProgress.waitForExistence(timeout: timeout), "Replay must use the full five-vault plan")
        let back = app.buttons["leaveReplay"]
        XCTAssertTrue(back.waitForExistence(timeout: timeout))
        back.tap()
        XCTAssertTrue(replay.waitForExistence(timeout: timeout))
        XCTAssertTrue(camera.isEnabled)
        XCTAssertFalse(app.buttons["endRound"].exists)
    }

    func testSimulatorCameraUnavailableCanRetryAndReturnToSelection() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launch()
        let camera = app.buttons["startMission"]
        XCTAssertTrue(camera.waitForExistence(timeout: timeout))
        LaserHeistJourney.startCameraSetup(app, timeout: timeout)
        // Real Simulator permission UI, if this app has not requested camera access before.
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            if permission.buttons["Allow"].exists { permission.buttons["Allow"].tap() }
            else if permission.buttons["OK"].exists { permission.buttons["OK"].tap() }
        }
        let error = app.staticTexts["liveSetupError"]
        XCTAssertTrue(error.waitForExistence(timeout: timeout), "Simulator must show the unavailable-camera path")
        let retry = app.buttons["retryLiveSetup"]
        XCTAssertTrue(retry.exists && retry.isEnabled)
        retry.tap()
        XCTAssertTrue(error.waitForExistence(timeout: timeout))
        app.buttons["leaveLiveSetup"].tap()
        XCTAssertTrue(camera.waitForExistence(timeout: timeout))
        XCTAssertTrue(camera.isEnabled, "A stopped source must allow a new explicit setup")
        #else
        throw XCTSkip("This checks the Simulator's unavailable-camera path, not physical tracking")
        #endif
    }
}

/// Reaching the round and camera setup from the Sketch Home.
enum LaserHeistJourney {
    /// Opens the replay demo from Home, or finds it already open (`-replay`).
    static func enterRound(_ app: XCUIApplication, timeout: TimeInterval) {
        let replay = app.buttons["chooseReplay"]
        let end = app.buttons["endRound"]
        let either = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in replay.exists || end.exists }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [either], timeout: timeout), .completed, "the app opened on neither Home nor a round")
        if replay.exists { replay.tap() }
    }

    /// Home › START MISSION › both "Put your iPad on the Floor" steps › camera setup.
    static func startCameraSetup(_ app: XCUIApplication, timeout: TimeInterval) {
        app.buttons["startMission"].tap()
        let next = app.buttons["setupNext"]
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Set Up step 1 did not show")
        next.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Set Up step 2 did not show")
        next.tap()
    }
}
