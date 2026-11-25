import XCTest

final class DeveloperModeUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = arguments
        LaserHeistJourney.markTutorialCompleted(app)
        app.launch()
        return app
    }

    func testHomeExposesOnlyThePlayerSelectorInDeveloperMode() {
        let app = launch()
        let picker = app.segmentedControls["playerModeSelector"]
        let logo = app.images["homeLogo"]
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        XCTAssertFalse(picker.exists)

        logo.press(forDuration: 3.2)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for id in ["openSFXReplayLab", "chooseReplay", "cameraDiagnostics", "chooseInGameCamera", "resetLeanTutorial"] {
            XCTAssertFalse(app.buttons[id].exists, id)
        }

        picker.buttons["1 Player"].tap()
        logo.press(forDuration: 3.2)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        logo.press(forDuration: 3.2)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.buttons["2 Players"].isSelected)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        XCTAssertFalse(picker.exists)
    }

    func testCleanCameraSetupAndReturnHomeHaveNoDebugCopy() {
        let app = launch()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 20))
        LaserHeistJourney.startCameraSetup(app, timeout: 30)
        XCTAssertTrue(app.buttons["setupNext"].waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.buttons["navigationBack"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["debugSkipToReplay"].exists)
        XCTAssertFalse(app.buttons["setupDiagnosticsToggle"].exists)

        let back = app.buttons["navigationBack"]
        back.tap()
        XCTAssertTrue(app.buttons["setupNext"].waitForExistence(timeout: 30))
        back.tap()
        XCTAssertTrue(app.buttons["startMission"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["inputFlowMessage"].exists)
    }

    func testDeveloperRoundPanelContainsOnlyTheTwoSkips() {
        // Replay supplies the same panel and a deterministic Pause menu without a camera.
        let app = launch(["-replay", "-showDebugTools", "-hudPauseMenu", "-hideDebugOverlay"])
        let open = app.buttons["openDeveloperTools"]
        let panel = app.otherElements["debugRoundControls"]
        XCTAssertTrue(open.waitForExistence(timeout: 60))
        XCTAssertFalse(panel.exists)
        open.tap()

        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resume"].exists)
        XCTAssertEqual(Set(panel.buttons.allElementsBoundByIndex.map(\.identifier)),
                       ["debugSkipToNextGate", "debugSkipToDiamondTime", "debugClose"])
        XCTAssertFalse(app.buttons["timingSelector"].exists)
        XCTAssertFalse(app.staticTexts["diamondFlightDiagnostics"].exists)

        app.buttons["debugClose"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resume"].exists)
        XCTAssertFalse(app.buttons["debugExpand"].exists)
    }
}
