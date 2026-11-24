import XCTest

/// The LaserHeist journey through real taps (Sketch "Hi-Fi Revisi 6 NOV" over
/// `LaserInputFlow`): Home, the looping Set Up screen with Back, camera setup on the
/// "stand here" stage and leaving it, then the replay demo, Results and Back to
/// Home. Waits on UI state only, never a fixed delay.
final class LaserHeistJourneyUITests: XCTestCase {
    /// An upper bound for a slow Simulator, not an expected duration.
    private let timeout: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testLaunchWhileDeviceIsHeldInPortraitUsesLandscape() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        LaserHeistJourney.markTutorialCompleted(app)
        app.launch()

        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: timeout))
        for id in ["openSFXReplayLab", "chooseReplay", "resetLeanTutorial", "cameraDiagnostics", "chooseInGameCamera"] {
            XCTAssertFalse(app.buttons[id].exists)
        }
        XCTAssertFalse(app.segmentedControls["playerModeSelector"].exists)
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
    }

    func testHomeSetUpCameraSetupReplayResultsAndBackToHome() {
        let app = XCUIApplication()
        LaserHeistJourney.markTutorialCompleted(app)
        app.launchArguments.append("-showHomeDebugTools")
        app.launch()
        let start = app.buttons["startMission"]
        let next = app.buttons["setupNext"]
        let back = app.buttons["navigationBack"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "the app did not open on Home")

        // Both illustrations alternate automatically before returning Home with one Back tap.
        start.tap()
        let skipVideo = app.buttons["skipIntroVideo"]
        XCTAssertTrue(skipVideo.waitForExistence(timeout: timeout), "START MISSION did not open the intro video")
        skipVideo.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Skipping the intro video did not open Set Up")
        XCTAssertTrue(app.staticTexts["Put your iPad on the Floor"].exists)
        let mascot = app.images["The mascot standing an iPad up on the floor"]
        let hands = app.images["Two hands holding an iPad"]
        XCTAssertTrue(mascot.waitForExistence(timeout: timeout), "The mascot did not appear automatically")
        XCTAssertTrue(hands.waitForExistence(timeout: timeout), "The illustrations did not loop")
        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back from Set Up did not return Home")

        // Camera setup opens on the stage with the session's own controls; leaving returns Home.
        LaserHeistJourney.startCameraSetup(app, timeout: timeout)
        let leave = app.buttons["navigationBack"]
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
        XCTAssertFalse(app.buttons["debugSkipToReplay"].exists)
        XCTAssertFalse(app.buttons["leaveLiveSetup"].exists)
        leave.tap()
        XCTAssertTrue(next.waitForExistence(timeout: timeout), "Back did not return to iPad placement")
        leave.tap()
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "Back from placement did not return Home")

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
        app.launchArguments.append("-enableCalibrationReplaySkip")
        LaserHeistJourney.markTutorialCompleted(app)
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
