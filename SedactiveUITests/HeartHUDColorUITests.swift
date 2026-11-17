import XCTest

final class HeartHUDColorUITests: XCTestCase {
    func testHUDPaletteAnglesCollectionAndCleanupInActualCorridor() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let cases: [(String, [String])] = [
            ("previous-runtime", ["-heartPreviousPalette"]),
            ("hud-palette-no-glow", ["-heartNoGlow"]),
            ("hud-palette-old-glow", ["-heartOldGlow"]),
            ("hud-final-front", []),
            ("hud-final-quarter", ["-heartAngle", "quarter"]),
            ("hud-final-side", ["-heartAngle", "side"])
        ]
        for (name, args) in cases {
            app.launchArguments = ["-replay", "-heartAnimationPreview", "-heartColorStill", "-hideDebugOverlay"] + args
            app.launch()
            let status = app.staticTexts["heartPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            func wait(_ text: String) {
                expectation(for: NSPredicate(format: "label == %@", text), evaluatedWith: status)
                waitForExpectations(timeout: 60)
            }
            func capture(_ title: String) {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = title; shot.lifetime = .keepAlways; add(shot)
            }
            wait("Idle · visual collections 0")
            capture(name)
            if name == "hud-final-front" {
                let generation = app.staticTexts["heartPreviewGeneration"].label
                app.buttons["heartPreviewCollect"].tap()
                wait("Retired · visual collections 1")
                XCTAssertFalse(app.buttons["heartPreviewCollect"].isEnabled)
                capture("hud-collected-no-halo")
                app.buttons["heartPreviewNew"].tap()
                wait("Idle · visual collections 1")
                app.buttons["heartPreviewStop"].tap()
                wait("Stopped · visual collections 1")
                capture("hud-stopped-no-halo")
                app.buttons["heartPreviewRetry"].tap()
                wait("Idle · visual collections 0")
                XCTAssertNotEqual(app.staticTexts["heartPreviewGeneration"].label, generation)
                XCTAssertTrue(app.staticTexts["No game session · no health or score changes"].exists)
            }
            app.terminate()
        }
    }
}
