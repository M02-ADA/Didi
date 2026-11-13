import XCTest

/// The LaserHeist journey through real taps (Sketch "Hi-Fi Revisi 6 NOV" over
/// `LaserInputFlow`): Home, the two Set Up steps with Back, camera setup on the
/// "stand here" stage and leaving it, then the replay demo, Results and Back to
/// Home. Waits on UI state only, never a fixed delay.
final class LaserHeistJourneyUITests: XCTestCase {
    /// An upper bound for a slow Simulator, not an expected duration.
    private let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testHomeSetUpCameraSetupReplayResultsAndBackToHome() {
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["startMission"]
        let next = app.buttons["setupNext"]
        let back = app.buttons["navigationBack"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "the app did not open on Home")

        // Home › Set Up and back, one step at a time.
        start.tap()
        let skipVideo = app.buttons["skipIntroVideo"]
        XCTAssertTrue(skipVideo.waitForExistence(timeout: timeout), "START MISSION did not open the intro video")
        skipVideo.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Skipping the intro video did not open Set Up")
        XCTAssertTrue(app.staticTexts["Put your iPad on the Floor"].exists)
        next.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout))
        back.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Back on step 2 did not return to step 1")
        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back on step 1 did not return Home")

        // Camera setup opens on the stage with the session's own controls; leaving returns Home.
        LaserHeistJourney.startCameraSetup(app, timeout: timeout)
        let leave = app.buttons["leaveLiveSetup"]
        XCTAssertTrue(leave.waitForExistence(timeout: timeout), "camera setup did not open")
        // A first camera request shows the system permission alert over the app;
        // answer it as a player would, then leave at once, startup finished or not.
        // (Leaving mid-startup waits for the old startup to end: LaserInputFlow.)
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            // `firstMatch`: some iOS versions label more than one control "Allow".
            let allow = permission.buttons.matching(identifier: "Allow").firstMatch
            if allow.exists { allow.tap() } else { permission.buttons.matching(identifier: "OK").firstMatch.tap() }
        }
        XCTAssertTrue(leave.waitForExistence(timeout: timeout) && leave.isHittable)
        leave.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "leaving camera setup did not return Home")

        // Replay demo › Results › Back to Home.
        app.buttons["chooseReplay"].tap()
        let end = app.buttons["endRound"]
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "the replay demo did not start")
        end.tap()
        let home = app.buttons["backToHome"]
        XCTAssertTrue(home.waitForExistence(timeout: timeout), "Results offered no Back to Home")
        XCTAssertTrue(app.buttons["retryRound"].exists, "Results offered no Play Again")
        home.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back to Home did not return Home")
        XCTAssertFalse(end.exists, "the round is still running behind Home")
    }

    /// DEBUG: from calibration, skip the camera into the seeded five-vault
    /// replay (no calibration is forged), then Results, Play Again and Home.
    func testDebugSkipFromCalibrationPlaysTheFullReplay() {
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["startMission"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        LaserHeistJourney.startCameraSetup(app, timeout: timeout)
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let allow = permission.buttons.matching(identifier: "Allow").firstMatch
            if allow.exists { allow.tap() } else { permission.buttons.matching(identifier: "OK").firstMatch.tap() }
        }
        let skip = app.buttons["debugSkipToReplay"]
        XCTAssertTrue(skip.waitForExistence(timeout: timeout) && skip.isHittable, "calibration offers no DEBUG skip")
        skip.tap()
        let end = app.buttons["endRound"]
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "the skip did not start the replay")
        let fullRound = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Vaults opened 0 of 5")).firstMatch
        XCTAssertTrue(fullRound.waitForExistence(timeout: timeout), "the skip must play the complete five-vault replay")
        XCTAssertFalse(app.buttons["leaveLiveSetup"].exists, "no live setup is left behind")
        end.tap()
        let retry = app.buttons["retryRound"]
        XCTAssertTrue(retry.waitForExistence(timeout: timeout))
        retry.tap()
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "Play Again did not start a fresh round")
        end.tap()
        let home = app.buttons["backToHome"]
        XCTAssertTrue(home.waitForExistence(timeout: timeout))
        home.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back to Home did not return Home")
    }
}
