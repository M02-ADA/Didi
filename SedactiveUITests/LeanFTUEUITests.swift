import XCTest

/// One bounded actual-corridor review. All bodies here are explicitly SYNTHETIC K03 fixtures;
/// no physical tracking, calibration, or movement success is certified by this test.
final class LeanFTUEUITests: XCTestCase {
    func testLeanFlowSoloCoopPersistenceAndRetryInActualScene() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        func title(_ text: String) {
            let label = app.staticTexts["leanTutorialTitle"]
            XCTAssertTrue(label.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: label)
            waitForExpectations(timeout: 15)
        }
        func completed() {
            let label = app.staticTexts["leanPreviewStatus"]
            XCTAssertTrue(label.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS 'tutorial complete'"), evaluatedWith: label)
            waitForExpectations(timeout: 30)
            XCTAssertFalse(app.staticTexts["leanTutorialTitle"].exists)
        }
        for solo in [false, true] {
            let mode = solo ? "solo" : "coop"
            let arguments = ["-replay", "-leanFTUEPreview", "-hideDebugOverlay"] + (solo ? ["-leanFTUESolo"] : [])
            app.launchArguments = arguments + ["-leanFTUEReset"]
            app.launch()
            title("Lean your head")
            XCTAssertTrue(app.descendants(matching: .any)["leanIntroductionAnimation"].exists)
            capture("\(mode)-introduction")
            app.buttons["leanTutorialContinue"].tap()
            title("LEAN LEFT")
            XCTAssertFalse(app.descendants(matching: .any)["leanIntroductionAnimation"].exists)
            Thread.sleep(forTimeInterval: 1.2) // sample the existing synthetic K03 lean, never auto-complete
            capture("\(mode)-lean-left")
            let left = app.staticTexts["leanTutorialTitle"].frame
            app.buttons["leanTutorialContinue"].tap()
            title("LEAN RIGHT")
            Thread.sleep(forTimeInterval: 1.2)
            capture("\(mode)-lean-right")
            for layout in 1...3 {
                app.buttons["leanPreviewInspect"].tap()
                let audit = app.staticTexts["leanPreviewAudit"].label
                let record = XCTAttachment(string: audit); record.name = "\(mode)-layout-\(layout)-projection"; record.lifetime = .keepAlways; add(record)
                if let data = audit.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let avatars = json["avatars"] as? [[String: Any]] {
                    XCTAssertEqual(avatars.count, solo ? 1 : 2)
                    for avatar in avatars {
                        if let top = avatar["y"] as? Double {
                            XCTAssertLessThan(app.staticTexts["leanTutorialTitle"].frame.maxY + 12, top)
                        }
                    }
                } else { XCTFail("Missing actual RealityView projection") }
                capture("\(mode)-lateral-\(layout)")
            }
            let right = app.staticTexts["leanTutorialTitle"].frame
            XCTAssertEqual(left.midY, right.midY, accuracy: 1)
            XCTAssertEqual(left.height, right.height, accuracy: 1)
            app.buttons["leanTutorialContinue"].tap()
            completed()
            capture("\(mode)-completed-replay")
            app.buttons["leanPreviewRetry"].tap()
            completed()
            app.terminate()
            app.launchArguments = arguments
            app.launch()
            completed()
            capture("\(mode)-persisted-after-relaunch")
            app.terminate()
        }
        // Explicit Skip is distinct from inferred success and releases the fixture into replay.
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-hideDebugOverlay"]
        app.launch()
        title("Lean your head")
        app.buttons["leanTutorialSkip"].tap()
        completed()
        app.terminate()
    }
}
