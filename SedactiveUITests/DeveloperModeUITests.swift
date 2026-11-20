import XCTest

final class DeveloperModeUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testHomeStartsCleanAndLongPressEnablesToolsUntilRelaunch() {
        let app = launch()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["openSFXReplayLab"].exists)
        XCTAssertFalse(app.buttons["cameraDiagnostics"].exists)
        XCTAssertFalse(app.buttons["chooseReplay"].exists)
        XCTAssertFalse(app.segmentedControls["playerModeSelector"].exists)

        app.images["homeLogo"].press(forDuration: 3.2)
        XCTAssertTrue(app.buttons["openSFXReplayLab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cameraDiagnostics"].exists)
        XCTAssertTrue(app.buttons["chooseReplay"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["openSFXReplayLab"].exists)
    }

    func testCleanCameraSetupHasNoDebugShortcuts() {
        let app = launch()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        LaserHeistJourney.startCameraSetup(app, timeout: 30)
        XCTAssertTrue(app.buttons["leaveLiveSetup"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["debugSkipToReplay"].exists)
        XCTAssertFalse(app.buttons["setupDiagnosticsToggle"].exists)
    }

    func testXcodeOptInCanBeTurnedOff() {
        let app = launch(["-showDebugTools"])
        XCTAssertTrue(app.buttons["openSFXReplayLab"].waitForExistence(timeout: 20))
        app.buttons["disableDeveloperMode"].tap()
        XCTAssertFalse(app.buttons["openSFXReplayLab"].exists)
        XCTAssertFalse(app.buttons["cameraDiagnostics"].exists)
        XCTAssertFalse(app.buttons["chooseReplay"].exists)
    }

    func testRoundToolsOpenFromPauseAndCloseWithoutLeavingAPill() {
        // The existing pause preview supplies a deterministic menu without camera calibration.
        let app = launch(["-replay", "-showDebugTools", "-hudPauseMenu", "-hideDebugOverlay"])
        XCTAssertTrue(app.buttons["openDeveloperTools"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.otherElements["debugRoundControls"].exists)
        XCTAssertFalse(app.buttons["timingSelector"].exists)
        app.buttons["openDeveloperTools"].tap()
        XCTAssertTrue(app.otherElements["debugRoundControls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["timingSelector"].exists)
        app.buttons["debugClose"].tap()
        XCTAssertTrue(app.otherElements["debugRoundControls"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["debugExpand"].exists)
        XCTAssertFalse(app.buttons["timingSelector"].exists)
        XCTAssertTrue(app.buttons["leaveReplay"].isHittable)
    }
}
