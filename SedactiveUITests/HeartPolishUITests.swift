import XCTest

final class HeartPolishUITests: XCTestCase {
    func testTipShadingInActualCorridor() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let cases: [(String, [String])] = [
            ("tip-before", ["-heartTipBefore"]), ("tip-unlit-diagnostic", ["-heartTipUnlit"]),
            ("tip-fixed-front", []), ("tip-fixed-quarter", ["-heartAngle", "quarter"]),
            ("tip-fixed-side", ["-heartAngle", "side"])
        ]
        for (name, args) in cases {
            app.launchArguments = ["-replay", "-heartAnimationPreview", "-heartColorStill", "-hideDebugOverlay"] + args
            app.launch()
            let status = app.staticTexts["heartPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label == %@", "Idle · visual collections 0"), evaluatedWith: status)
            waitForExpectations(timeout: 60)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    func testRedPaletteGlowAnglesAndCleanupInActualCorridor() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let cases: [(String, [String])] = [
            ("artifact-fixed-original-palette", ["-heartOriginalPalette"]),
            ("red-no-glow", ["-heartNoGlow"]), ("red-glow-front", []),
            ("red-glow-quarter", ["-heartAngle", "quarter"]), ("red-glow-side", ["-heartAngle", "side"]),
            ("red-alongside-diamond", ["-heartWithDiamond"])
        ]
        for (name, args) in cases {
            app.launchArguments = ["-replay", "-heartAnimationPreview", "-heartColorStill", "-hideDebugOverlay"] + args
            app.launch()
            let status = app.staticTexts["heartPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label == %@", "Idle · visual collections 0"), evaluatedWith: status)
            waitForExpectations(timeout: 60)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            if name == "red-glow-front" {
                app.buttons["heartPreviewCollect"].tap()
                expectation(for: NSPredicate(format: "label == %@", "Retired · visual collections 1"), evaluatedWith: status)
                waitForExpectations(timeout: 10)
                app.buttons["heartPreviewStop"].tap()
                let cleared = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                cleared.name = "polished-stopped-no-halo"; cleared.lifetime = .keepAlways; add(cleared)
                app.buttons["heartPreviewRetry"].tap()
                expectation(for: NSPredicate(format: "label == %@", "Idle · visual collections 0"), evaluatedWith: status)
                waitForExpectations(timeout: 60)
            }
            app.terminate()
        }
    }

}
