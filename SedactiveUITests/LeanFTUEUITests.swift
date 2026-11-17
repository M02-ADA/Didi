import XCTest

/// One bounded actual-scene scenario. Input is explicitly SYNTHETIC through K03, never physical QA.
final class LeanFTUEUITests: XCTestCase {
    func testAutomaticLeanSoloCoopPausePersistenceAndLayout() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let title = app.descendants(matching: .any)["leanTutorialTitle"]
        func capture(_ name: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        func waitTitle(_ text: String) {
            XCTAssertTrue(title.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: title)
            waitForExpectations(timeout: 25)
        }
        func noBottomControls() {
            for id in ["leanTutorialLeave", "leanTutorialSkip", "leanTutorialContinue", "leanPreviewInspect"] {
                XCTAssertFalse(app.buttons[id].exists)
            }
        }
        func complete() {
            let status = app.staticTexts["leanPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS 'tutorial complete'"), evaluatedWith: status)
            waitForExpectations(timeout: 30)
            XCTAssertFalse(title.exists)
        }
        for solo in [false, true] {
            let mode = solo ? "solo" : "coop"
            let args = ["-replay", "-leanFTUEPreview", "-hideDebugOverlay"] + (solo ? ["-leanFTUESolo"] : [])
            app.launchArguments = args + ["-leanFTUEReset"]
            app.launch()
            waitTitle("Lean your head"); noBottomControls(); capture("\(mode)-introduction")
            waitTitle("LEAN LEFT"); noBottomControls(); capture("\(mode)-lean-left")
            let left = title.frame
            if solo {
                app.buttons["pauseMenu"].tap()
                XCTAssertTrue(app.buttons["resume"].waitForExistence(timeout: 10))
                capture("paused-through-existing-hud")
                app.buttons["resume"].tap()
                waitTitle("LEAN LEFT")
            }
            waitTitle("LEAN RIGHT"); noBottomControls(); capture("\(mode)-lean-right")
            XCTAssertEqual(left.midY, title.frame.midY, accuracy: 1)
            XCTAssertEqual(left.height, title.frame.height, accuracy: 1)
            complete(); capture("\(mode)-completed-gameplay")
            app.buttons["leanPreviewRetry"].tap(); complete()
            app.terminate(); app.launchArguments = args; app.launch(); complete(); app.terminate()
        }
        // Developer entry arguments replace all visible testing controls during FTUE.
        for solo in [false, true] {
            for (index, layout) in ["center", "left", "right"].enumerated() {
                app.launchArguments = ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-hideDebugOverlay",
                    "-leanFTUEHold", index == 0 ? "left" : "right", "-leanFTUELayout", layout] + (solo ? ["-leanFTUESolo"] : [])
                app.launch(); waitTitle(index == 0 ? "LEAN LEFT" : "LEAN RIGHT"); noBottomControls()
                let audit = app.staticTexts["leanPreviewAudit"]
                XCTAssertTrue(audit.waitForExistence(timeout: 15))
                let text = audit.label
                let a = XCTAttachment(string: text); a.name = "\(solo ? "solo" : "coop")-\(layout)-projection"; a.lifetime = .keepAlways; add(a)
                if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let avatars = json["avatars"] as? [[String: Any]] {
                    XCTAssertEqual(avatars.count, solo ? 1 : 2)
                    for avatar in avatars { if let top = avatar["y"] as? Double { XCTAssertLessThan(title.frame.maxY + 12, top, text) } }
                } else { XCTFail("Missing actual RealityView projection") }
                capture("\(solo ? "solo" : "coop")-\(layout)-layout")
                app.terminate()
            }
        }
        // No movement: the tutorial must wait indefinitely for evidence, while ordinary Exit works.
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-hideDebugOverlay", "-leanFTUEHold", "left"]
        app.launch(); waitTitle("LEAN LEFT")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(title.label.contains("LEAN LEFT"))
        app.buttons["pauseMenu"].tap()
        XCTAssertTrue(app.buttons["leaveGame"].waitForExistence(timeout: 10))
        app.buttons["leaveGame"].tap()
        XCTAssertTrue(app.buttons["chooseReplay"].waitForExistence(timeout: 15))
        app.terminate()
        // Same finite poster path used for Reduce Motion; no system setting is modified.
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-hideDebugOverlay", "-leanFTUEReduceMotion", "-leanFTUESolo"]
        app.launch(); waitTitle("Lean your head"); noBottomControls()
        XCTAssertEqual(app.descendants(matching: .any)["leanIntroductionAnimation"].value as? String, "Static poster")
        capture("reduce-motion-poster")
        waitTitle("LEAN LEFT"); complete(); app.terminate()
    }
}
