import XCTest

/// Real Home and LaserScene; only the explicit DEBUG fixture supplies SYNTHETIC practice input.
final class HomeTutorialHelpUITests: XCTestCase {
    func testCollectibleJourneyInActualSceneForFirstPlayAndHomeHelp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func capture(_ id: String, _ prefix: String) {
            XCTAssertTrue(element(id).waitForExistence(timeout: 30), id)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "synthetic-\(prefix)-\(id)"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(element("gameplayProgressBar").exists)
        }
        for help in [false, true] {
            let prefix = help ? "home-help-solo" : "first-play-coop"
            app.launchArguments = help ? ["-homeHelpFTUEPreview", "-leanFTUESolo"]
                : ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-leanFTUEBoundary", "-hideDebugOverlay"]
            app.launch()
            if help {
                let replay = app.buttons["replayTutorial"]
                XCTAssertTrue(replay.waitForExistence(timeout: 30))
                app.segmentedControls["playerModeSelector"].buttons["1 Player · Solo Practice"].tap()
                replay.tap(); app.buttons["setupNext"].tap(); app.buttons["setupNext"].tap()
            }
            XCTAssertTrue(element("leanTutorialTitle").waitForExistence(timeout: 45))
            capture("ftueFreeLean", prefix)
            XCTAssertFalse(element("leanTutorialTitle").exists)
            capture("ftueCollectiblesTitle", prefix)
            XCTAssertFalse(element("heartTutorialTitle").exists)
            capture("ftueCollection-diamond", prefix)
            XCTAssertFalse(element("ftueCollection-heart").exists)
            capture("ftueCollection-heart", prefix)
            XCTAssertFalse(element("heartTutorialTitle").exists)
            capture("heartTutorialTitle", prefix)
            XCTAssertTrue(element("heartTutorialTitle").label.contains("This is your shared health"))
            XCTAssertEqual(element("sharedHealthHUD").label, "Team health 5 of 5")
            app.terminate()
        }
    }

    func testHomeHelpReturningPlayerReplayAndCancellation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let title = app.descendants(matching: .any)["leanTutorialTitle"]
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func waitTitle(_ label: String) {
            XCTAssertTrue(title.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS %@", label), evaluatedWith: title)
            waitForExpectations(timeout: 25)
            XCTAssertTrue(app.descendants(matching: .any)["ftueProgressBar"].exists)
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
            for id in ["leanTutorialLeave", "leanTutorialSkip", "leanTutorialContinue"] { XCTAssertFalse(app.buttons[id].exists) }
        }
        func heartSequence(_ prefix: String, pause: Bool = false) {
            let heart = app.descendants(matching: .any)["heartTutorialTitle"]
            func waitHeart(_ copy: String) {
                XCTAssertTrue(heart.waitForExistence(timeout: 20))
                expectation(for: NSPredicate(format: "label CONTAINS %@", copy), evaluatedWith: heart)
                waitForExpectations(timeout: 15)
            }
            waitHeart("This is your shared health")
            let health = app.descendants(matching: .any)["sharedHealthHUD"]
            XCTAssertTrue(health.exists)
            XCTAssertEqual(health.label, "Team health 5 of 5")
            XCTAssertLessThan(health.frame.maxY, heart.frame.minY)
            capture("\(prefix)-heart-introduction")
            if pause {
                app.buttons["pauseMenu"].tap()
                XCTAssertTrue(app.buttons["resume"].waitForExistence(timeout: 10))
                Thread.sleep(forTimeInterval: 4.5)
                XCTAssertFalse(heart.exists)
                app.buttons["resume"].tap()
                waitHeart("This is your shared health")
            }
            let encounter = app.descendants(matching: .any)["heartTrainingEncounter"]
            XCTAssertTrue(encounter.waitForExistence(timeout: 15))
            XCTAssertEqual(health.label, "Team health 5 of 5")
            capture("\(prefix)-heart-laser-approach")
            let zapped = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Zapped!'")).firstMatch
            XCTAssertTrue(zapped.waitForExistence(timeout: 10))
            capture("\(prefix)-heart-zapped")
            XCTAssertEqual(health.label, "Team health 4 of 5")
            waitHeart("Your health will be deducted"); capture("\(prefix)-heart-warning")
            XCTAssertEqual(health.label, "Team health 4 of 5")
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
            for id in ["leanTutorialLeave", "leanTutorialSkip", "leanTutorialContinue"] { XCTAssertFalse(app.buttons[id].exists) }
        }
        func practiceSequence(_ prefix: String) {
            waitTitle("Jump or Duck"); capture("\(prefix)-jump-duck-introduction")
            let status = app.staticTexts["ftuePracticeStatus"]
            let health = app.descendants(matching: .any)["sharedHealthHUD"]
            func waitStatus(_ text: String) {
                XCTAssertTrue(status.waitForExistence(timeout: 15))
                expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: status)
                waitForExpectations(timeout: 15)
            }
            func feedback(_ label: String, _ name: String) {
                let word = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                XCTAssertTrue(word.waitForExistence(timeout: 12))
                capture("\(prefix)-\(name)")
                XCTAssertEqual(health.label, "Team health 4 of 5", "practice never adds damage")
            }
            waitStatus("jump attempt 1"); capture("\(prefix)-jump-first-approach")
            feedback("Zapped!", "jump-failure")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.400")
            waitStatus("jump attempt 2"); capture("\(prefix)-jump-retry")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.400")
            feedback("Perfect!", "jump-clear")
            waitStatus("duck attempt 3"); capture("\(prefix)-duck-first-approach")
            feedback("Zapped!", "duck-failure")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.460")
            waitStatus("duck attempt 4"); capture("\(prefix)-duck-retry")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.460")
            feedback("Perfect!", "duck-clear")
            let explanation = app.descendants(matching: .any)["progressTutorialTitle"]
            XCTAssertTrue(explanation.waitForExistence(timeout: 12))
            XCTAssertEqual(explanation.label, "This bar shows how far\nyou've gone")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.500")
            capture("\(prefix)-progress-explanation")
            expectation(for: NSPredicate(format: "label CONTAINS 'Each circle is a vault door'"), evaluatedWith: explanation)
            waitForExpectations(timeout: 12)
            capture("\(prefix)-vault-explanation")
            XCTAssertEqual(explanation.label, "Each circle is a vault door\nto open")
            let pointer = app.descendants(matching: .any)["ftueVaultPointer"]
            XCTAssertTrue(pointer.exists)
            XCTAssertEqual(pointer.frame.midX, app.images["ftueCenterCheckpoint"].frame.midX, accuracy: 1)
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
        }
        func complete() {
            let status = app.staticTexts["leanPreviewStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 60))
            expectation(for: NSPredicate(format: "label CONTAINS 'tutorial complete'"), evaluatedWith: status)
            waitForExpectations(timeout: 30)
            XCTAssertFalse(title.exists)
            XCTAssertFalse(app.descendants(matching: .any)["ftueProgressBar"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["gameplayProgressBar"].exists)
            XCTAssertEqual(app.descendants(matching: .any)["sharedHealthHUD"].label, "Team health 5 of 5")
        }
        // Existing first-play path still works without an explicit Help replay request.
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-leanFTUEReset", "-hideDebugOverlay"]
        app.launch(); waitTitle("Lean your head"); XCTAssertTrue(app.descendants(matching: .any)["ftueFreeLean"].waitForExistence(timeout: 15)); heartSequence("first-time"); practiceSequence("first-time"); complete(); app.terminate()

        for solo in [false, true] {
            let mode = solo ? "solo" : "coop"
            // Home starts normally; only finishing the two setup-instruction screens enters the fixture.
            app.launchArguments = ["-homeHelpFTUEPreview"] + (solo ? ["-leanFTUESolo"] : [])
            app.launch()
            let help = app.buttons["replayTutorial"]
            XCTAssertTrue(help.waitForExistence(timeout: 30))
            XCTAssertEqual(help.label, "Replay tutorial")
            XCTAssertTrue(help.isHittable)
            XCTAssertEqual(help.frame.width, help.frame.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(help.frame.width, 44)
            XCTAssertGreaterThan(help.frame.minX, app.frame.width * 0.75)
            XCTAssertGreaterThan(help.frame.minY, 24)
            XCTAssertLessThan(help.frame.maxY, app.buttons["startMission"].frame.minY)
            if solo { app.segmentedControls["playerModeSelector"].buttons["1 Player · Solo Practice"].tap() }
            capture("\(mode)-home-after")
            let closeup = XCTAttachment(screenshot: help.screenshot()); closeup.name = "help-button-closeup"; closeup.lifetime = .keepAlways; add(closeup)
            help.tap()
            XCTAssertTrue(app.buttons["setupNext"].waitForExistence(timeout: 10))
            XCTAssertFalse(title.exists, "genuine practice never opens before setup")
            capture("\(mode)-help-required-setup")
            // Cancel and request again: no stale request and no duplicate live session.
            app.buttons["navigationBack"].tap()
            XCTAssertTrue(help.waitForExistence(timeout: 10))
            help.tap(); app.buttons["setupNext"].tap(); app.buttons["setupNext"].tap()
            waitTitle("Lean your head"); capture("\(mode)-manual-introduction")
            XCTAssertTrue(app.descendants(matching: .any)["ftueFreeLean"].waitForExistence(timeout: 15))
            capture("\(mode)-free-lean")
            heartSequence(mode, pause: !solo)
            practiceSequence(mode)
            complete(); capture("\(mode)-manual-completed")
            app.buttons["leanPreviewRetry"].tap(); complete()
            app.buttons["leaveReplay"].tap()
            XCTAssertTrue(help.waitForExistence(timeout: 15))
            // Ordinary replay entry has no manual request, so persisted completion wins.
            app.buttons["chooseReplay"].tap(); complete()
            app.terminate(); app.launch()
            XCTAssertTrue(help.waitForExistence(timeout: 15))
            app.buttons["chooseReplay"].tap(); complete()
            app.terminate()
        }
    }
}
