import XCTest

final class HeartAnimationUITests: XCTestCase {
    func testSyntheticHeartInActualCorridorCollectStopAndRetry() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay", "-heartAnimationPreview", "-hideDebugOverlay"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let status = app.staticTexts["heartPreviewStatus"]
        let generation = app.staticTexts["heartPreviewGeneration"]
        func wait(_ value: String) {
            expectation(for: NSPredicate(format: "label == %@", value), evaluatedWith: status)
            waitForExpectations(timeout: 60)
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertTrue(status.waitForExistence(timeout: 90))
        wait("Idle · visual collections 0")
        let original = generation.label
        capture("heart-idle-SYNTHETIC-actual-corridor")
        // Observe actual native idle motion, then collect. Xcode/Simulator recording captures
        // the short pop and sparkles; these sleeps do not drive app animation or game time.
        Thread.sleep(forTimeInterval: 2)
        app.buttons["heartPreviewCollect"].tap()
        wait("Retired · visual collections 1")
        capture("heart-disappeared-SYNTHETIC")
        XCTAssertFalse(app.buttons["heartPreviewCollect"].isEnabled)
        app.buttons["heartPreviewNew"].tap()
        wait("Idle · visual collections 1")
        Thread.sleep(forTimeInterval: 1)
        app.buttons["heartPreviewCollect"].tap()
        wait("Retired · visual collections 2")
        app.buttons["heartPreviewNew"].tap()
        wait("Idle · visual collections 2")
        app.buttons["heartPreviewStop"].tap()
        wait("Stopped · visual collections 2")
        capture("heart-stopped-cleanup-SYNTHETIC")
        app.buttons["heartPreviewRetry"].tap()
        wait("Idle · visual collections 0")
        XCTAssertNotEqual(generation.label, original)
        capture("heart-retry-fresh-generation-SYNTHETIC")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Replay could not start:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["No game session · no health or score changes"].exists)
        app.terminate()
    }
}
