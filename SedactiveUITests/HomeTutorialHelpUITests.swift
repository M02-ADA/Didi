import XCTest

/// Real Home and LaserScene; only the explicit DEBUG fixture supplies SYNTHETIC practice input.
final class HomeTutorialHelpUITests: XCTestCase {
    func testPlacementSurvivesBackgroundButForceCloseReturnsHome() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-homeHelpFTUEPreview"]
        app.launchEnvironment["FTUE_ONBOARDING_TEST_SUITE"] = "LaserHeist.FTUEOnboardingTest.\(UUID())"
        let start = app.buttons["startMission"]
        let next = app.buttons["setupNext"]

        func openPlacement() {
            XCTAssertTrue(start.waitForExistence(timeout: 15))
            XCTAssertFalse(next.exists)
            start.tap()
            let skip = app.buttons["skipIntroVideo"]
            XCTAssertTrue(skip.waitForExistence(timeout: 15))
            skip.tap()
            XCTAssertTrue(next.waitForExistence(timeout: 15))
        }

        app.launch()
        openPlacement()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(next.waitForExistence(timeout: 15), "Backgrounding keeps the current placement page")
        XCTAssertFalse(start.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertFalse(next.exists)
    }

    func testOnboardingCompletionAndHelpReplayReturnHome() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-homeHelpFTUEPreview"]
        app.launchEnvironment["FTUE_ONBOARDING_TEST_SUITE"] = "LaserHeist.FTUEOnboardingTest.\(UUID())"
        let next = app.buttons["setupNext"]
        let start = app.buttons["startMission"]
        let help = app.buttons["replayTutorial"]
        let elements = app.descendants(matching: .any)

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let skip = app.buttons["skipIntroVideo"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        skip.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        capture("first-mission-placement")
        for visit in 1...2 {
            next.tap()
            XCTAssertTrue(elements["leanTutorialTitle"].waitForExistence(timeout: 45))
            XCTAssertTrue(app.staticTexts["RETRIEVE THE DIAMONDS"].waitForExistence(timeout: 130))
            capture("synthetic-diamond-time-\(visit)")
            XCTAssertFalse(elements["roundCountdown"].exists)
            XCTAssertTrue(start.waitForExistence(timeout: 55))
            XCTAssertTrue(start.isHittable, "START MISSION is interactive after the reveal")
            XCTAssertTrue(help.isHittable, "Help is interactive after the reveal")
            XCTAssertFalse(elements["gameplayProgressBar"].exists)
            XCTAssertFalse(elements["roundCountdown"].exists)
            XCTAssertFalse(app.staticTexts["RETRIEVE THE DIAMONDS"].exists)
            capture("home-after-completion-\(visit)")
            app.terminate()
            app.launch()
            XCTAssertTrue(help.waitForExistence(timeout: 15))
            XCTAssertFalse(next.exists)
            if visit == 1 {
                help.tap()
                XCTAssertTrue(next.waitForExistence(timeout: 10))
                capture("help-replay-placement")
            }
        }
    }

    func testProgressExplanationSpotlightsInActualScene() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        // Use the existing DEBUG scene with the first three modules already completed.
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-hideDebugOverlay",
            "-laserHeist.ftue.lean.v1.completed", "YES",
            "-laserHeist.ftue.heart.v1.completed", "YES",
            "-laserHeist.ftue.jumpDuck.v1.completed", "YES",
            "-laserHeist.ftue.progress.v1.completed", "NO"]
        app.launch()
        let elements = app.descendants(matching: .any)
        let title = elements["progressTutorialTitle"]
        let bar = elements["ftueProgressBar"]
        let barPointer = elements["ftueProgressPointer"]
        let vaultPointer = elements["ftueVaultPointer"]
        let checkpoint = app.images["ftueCenterCheckpoint"]

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(barPointer.waitForExistence(timeout: 25))
        capture("progress-bar-explanation")
        XCTAssertEqual(title.label, "This bar shows how far\nyou've gone")
        XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.500")
        XCTAssertEqual(barPointer.frame.midX, bar.frame.midX, accuracy: 1)
        XCTAssertLessThan(barPointer.frame.maxY, title.frame.minY)
        XCTAssertFalse(vaultPointer.exists)

        XCTAssertTrue(vaultPointer.waitForExistence(timeout: 10))
        capture("vault-checkpoint-explanation")
        XCTAssertEqual(title.label, "Each circle is a vault\ndoor to open")
        XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.500")
        XCTAssertEqual(vaultPointer.frame.midX, checkpoint.frame.midX, accuracy: 1)
        XCTAssertGreaterThan(vaultPointer.frame.minY, checkpoint.frame.maxY)
        XCTAssertLessThan(vaultPointer.frame.maxY, title.frame.minY)
        XCTAssertFalse(barPointer.exists)

        XCTAssertTrue(elements["ftueVaultButtonTitle"].waitForExistence(timeout: 10))
        XCTAssertFalse(title.exists)
        XCTAssertTrue(bar.exists)
        XCTAssertFalse(barPointer.exists)
        XCTAssertFalse(vaultPointer.exists)
        XCTAssertFalse(elements["roundCountdown"].exists)
        XCTAssertFalse(elements["gameplayProgressBar"].exists)
    }

    func testVaultPracticeToDiamondTimeInActualScene() {
        vaultPracticeToDiamondTime(solo: false)
    }

    func testSoloVaultPracticeToDiamondTimeInActualScene() {
        vaultPracticeToDiamondTime(solo: true)
    }

    private func vaultPracticeToDiamondTime(solo: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-replay", "-leanFTUEPreview", "-hideDebugOverlay", "-leanFTUEVaultInitialDropout", "-leanFTUEDelayedVaultCapture", "-ftueVaultDiagnostics",
            "-leanFTUEDelayedDiamondTimeCapture",
            "-laserHeist.ftue.lean.v1.completed", "YES",
            "-laserHeist.ftue.heart.v1.completed", "YES",
            "-laserHeist.ftue.jumpDuck.v1.completed", "YES",
            "-laserHeist.ftue.progress.v1.completed", "NO"]
        if solo {
            app.launchArguments += ["-leanFTUESolo"]
        }
        let elements = app.descendants(matching: .any)
        let vault = elements["ftueVaultPointer"]
        let intro = elements["ftueVaultButtonTitle"]
        let countdown = elements["roundCountdown"]
        let diamond = elements["ftueDiamondPointer"]
        let bar = elements["ftueProgressBar"]
        let gameplay = elements["gameplayProgressBar"]

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func assertTutorialHUD() {
            XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.949")
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(countdown.exists)
            XCTAssertFalse(gameplay.exists)
        }

        app.launch()
        XCTAssertTrue(vault.waitForExistence(timeout: 25))
        XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.500")
        capture("vault-checkpoint")
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertEqual(intro.label, "Press the buttons\nto open vault door")
        XCTAssertFalse(diamond.exists)
        XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.500")
        XCTAssertFalse(countdown.exists)
        XCTAssertFalse(gameplay.exists)
        capture("press-button")

        let practice = app.staticTexts["ftueVaultPracticeStatus"]
        func waitForPractice(_ pressed: Int, opened: Bool) {
            let label = "SYNTHETIC VAULT · active: \(pressed) · opened: \(opened)"
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: practice)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
        }
        let scene = app.staticTexts["ftueVaultSceneStatus"]
        XCTAssertTrue(scene.waitForExistence(timeout: 10))
        XCTAssertEqual(scene.label, "SYNTHETIC VAULT SCENE · door: true · buttons: \(solo ? 1 : 2) · waiting: true")
        capture("synthetic-vault-before-fresh-evidence")
        waitForPractice(0, opened: false)
        let banner = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                 "PRESS THE BUTTONS", "TO OPEN THE DOOR")
        XCTAssertTrue(app.staticTexts.containing(banner).firstMatch.exists)
        XCTAssertEqual(bar.value as? String, "Tutorial fill endpoint 0.500")
        XCTAssertFalse(diamond.exists)
        capture("synthetic-vault-practice")
        if !solo {
            waitForPractice(1, opened: false)
            XCTAssertFalse(diamond.exists)
            XCTAssertFalse(countdown.exists)
            XCTAssertFalse(gameplay.exists)
            capture("synthetic-one-button-pending")
        }
        // The production opening is shorter than XCTest's polling interval.
        // The continuous scene recording captures it; the following overlay proves the handoff.
        XCTAssertTrue(diamond.waitForExistence(timeout: 10))
        XCTAssertFalse(intro.exists)
        XCTAssertEqual(elements["progressTutorialTitle"].label, "Reach the Diamond\nVault at the end!")
        XCTAssertEqual(diamond.frame.midX, bar.frame.minX + 0.949 * bar.frame.width, accuracy: 1)
        assertTutorialHUD()
        capture("diamond-vault")

        let collection = elements["ftueDiamondCollectionTitle"]
        XCTAssertTrue(collection.waitForExistence(timeout: 8))
        XCTAssertEqual(collection.label, "Collect as many diamonds as you can!")
        assertTutorialHUD()
        capture("diamond-collection-instruction")

        let title = app.staticTexts["RETRIEVE THE DIAMONDS"]
        XCTAssertTrue(title.waitForExistence(timeout: 16))
        assertTutorialHUD()
        capture("ftue-diamond-time")
        let counter = elements.matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* diamonds")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 8))
        XCTAssertTrue(elements.matching(NSPredicate(format: "label ENDSWITH %@", "seconds left")).firstMatch.exists)
        assertTutorialHUD()
        capture("ftue-diamond-time-pickup")

        XCTAssertTrue(gameplay.waitForExistence(timeout: 25))
        XCTAssertFalse(title.exists)
        XCTAssertNotEqual(gameplay.value as? String, "Diamond reached")
        XCTAssertFalse(bar.exists)
        XCTAssertFalse(diamond.exists)
        capture("normal-hud-after-tutorial")
        app.terminate()
    }

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
                replay.tap(); app.buttons["setupNext"].tap()
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

    func testCoopDiamondWithP1Contact() {
        verifyCoopCollectibleReplays(contact: "-ftueDiamondP1Only", player: "P1", runs: 1, duck: .hit)
    }

    func testRepeatedCoopDiamondWithP2Contact() {
        verifyCoopCollectibleReplays(contact: "-ftueDiamondP2Only", player: "P2", runs: 2)
    }

    func testCoopDuckUnavailableFeedbackThenClear() {
        verifyCoopCollectibleReplays(contact: "-ftueDiamondP1Only", player: "P1", runs: 1, duck: .unavailable)
    }

    func testCoopDuckClearsFirstAttempt() {
        verifyCoopCollectibleReplays(contact: "-ftueDiamondP1Only", player: "P1", runs: 1, duck: .clear)
    }

    private enum DuckFixture { case hit, unavailable, clear }

    private func verifyCoopCollectibleReplays(contact: String, player: String, runs: Int, duck: DuckFixture? = nil) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-homeHelpFTUEPreview", "-ftueCollectibleDiagnostics", "-ftueDuckDiagnostics", contact]
        if duck == .unavailable { app.launchArguments.append("-ftueDuckUnavailableFirst") }
        if duck == .clear { app.launchArguments.append("-ftueDuckClearFirst") }
        app.launch()
        let help = app.buttons["replayTutorial"]
        let elements = app.descendants(matching: .any)
        for run in 1...runs {
            XCTAssertTrue(help.waitForExistence(timeout: 30))
            help.tap()
            app.buttons["setupNext"].tap()
            for id in ["ftueCollection-diamond", "ftueCollection-heart", "heartTutorialTitle"] {
                XCTAssertTrue(elements[id].waitForExistence(timeout: 30), "Run \(run): \(id)")
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "synthetic-coop-\(player)-run-\(run)-\(id)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            if let duck {
                let status = app.staticTexts["ftuePracticeStatus"]
                func capturePractice(_ text: String) {
                    let match = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                    XCTAssertTrue(match.waitForExistence(timeout: 25), text)
                    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    shot.name = "synthetic-coop-\(text)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                capturePractice("jump attempt 2 · clear")
                if duck == .clear {
                    capturePractice("duck attempt 3 · clear")
                } else {
                    capturePractice("duck attempt 3 · \(duck)")
                    XCTAssertTrue(elements.matching(NSPredicate(format: "label == 'Zapped!'")).firstMatch.exists)
                    capturePractice("duck attempt 4 · clear")
                }
                XCTAssertTrue(elements["progressTutorialTitle"].waitForExistence(timeout: 15))
                XCTAssertFalse(status.exists)
            }
            app.buttons["pauseMenu"].tap()
            XCTAssertTrue(app.buttons["leaveGame"].waitForExistence(timeout: 10))
            app.buttons["leaveGame"].tap()
        }
        XCTAssertTrue(help.waitForExistence(timeout: 15))
    }

    func testThreeCollectibleJourneysInOneApplicationProcess() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-homeHelpFTUEPreview", "-leanFTUESolo", "-ftueCollectibleDiagnostics"]
        app.launch()
        let help = app.buttons["replayTutorial"]
        XCTAssertTrue(help.waitForExistence(timeout: 30))
        app.segmentedControls["playerModeSelector"].buttons["1 Player · Solo Practice"].tap()

        for run in 1...3 {
            XCTAssertTrue(help.waitForExistence(timeout: 15))
            help.tap()
            app.buttons["setupNext"].tap()
            for id in ["leanTutorialTitle", "ftueFreeLean", "ftueCollectiblesTitle",
                       "ftueCollection-diamond", "ftueCollection-heart", "heartTutorialTitle"] {
                let stage = app.descendants(matching: .any)[id]
                XCTAssertTrue(stage.waitForExistence(timeout: 30), "Run \(run): \(id)")
                if id == "heartTutorialTitle" {
                    XCTAssertTrue(stage.label.contains("This is your shared health"))
                    XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
                    XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
                }
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "synthetic-solo-run-\(run)-\(id)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            if run == 1 {
                let title = app.staticTexts["RETRIEVE THE DIAMONDS"]
                XCTAssertTrue(title.waitForExistence(timeout: 100))
                let counter = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label MATCHES %@", "[1-9][0-9]* diamonds")).firstMatch
                XCTAssertTrue(counter.waitForExistence(timeout: 12))
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "synthetic-solo-run-1-diamond-time-pickup"
                shot.lifetime = .keepAlways
                add(shot)
                let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
                XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 25), .completed)
                let back = app.buttons["leaveReplay"]
                XCTAssertTrue(back.waitForExistence(timeout: 15))
                back.tap()
            } else {
                app.buttons["pauseMenu"].tap()
                XCTAssertTrue(app.buttons["leaveGame"].waitForExistence(timeout: 10))
                app.buttons["leaveGame"].tap()
            }
        }
        XCTAssertTrue(help.waitForExistence(timeout: 15))
        app.terminate()
    }

    func testFreeLeanMovementAndTimeoutAcrossModeChanges() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let practice = app.descendants(matching: .any)["ftueFreeLean"]
        let overlay = app.descendants(matching: .any)["ftueCollectiblesTitle"]

        for (solo, moves) in [(false, true), (true, true), (false, false), (true, false)] {
            app.launchArguments = ["-homeHelpFTUEPreview"]
                + (solo ? ["-leanFTUESolo"] : []) + (moves ? [] : ["-leanFTUENoMotion"])
            app.launch()
            let help = app.buttons["replayTutorial"]
            XCTAssertTrue(help.waitForExistence(timeout: 30))
            if solo { app.segmentedControls["playerModeSelector"].buttons["1 Player · Solo Practice"].tap() }
            help.tap()
            app.buttons["setupNext"].tap()
            XCTAssertTrue(practice.waitForExistence(timeout: 45))
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(overlay.waitForExistence(timeout: 20))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let scenario = "\(solo ? "solo" : "coop")-\(moves ? "movement" : "timeout")"
            print("[FreeLean UI] \(scenario) practice-to-overlay observed \(elapsed)s")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "ftueCollectiblesTitle").count, 1)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "synthetic-\(scenario)-collectibles"
            attachment.lifetime = .keepAlways
            add(attachment)
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
        func practiceSequence(_ prefix: String, verifyRetries: Bool) {
            waitTitle("Jump or Duck"); capture("\(prefix)-jump-duck-introduction")
            if verifyRetries {
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
            }
            let explanation = app.descendants(matching: .any)["progressTutorialTitle"]
            XCTAssertTrue(explanation.waitForExistence(timeout: verifyRetries ? 12 : 35))
            XCTAssertEqual(explanation.label, "This bar shows how far\nyou've gone")
            XCTAssertEqual(app.descendants(matching: .any)["ftueProgressBar"].value as? String, "Tutorial fill endpoint 0.500")
            capture("\(prefix)-progress-explanation")
            expectation(for: NSPredicate(format: "label BEGINSWITH 'Each circle is a vault'"), evaluatedWith: explanation)
            waitForExpectations(timeout: 12)
            capture("\(prefix)-vault-explanation")
            XCTAssertEqual(explanation.label, "Each circle is a vault\ndoor to open")
            let pointer = app.descendants(matching: .any)["ftueVaultPointer"]
            XCTAssertTrue(pointer.exists)
            XCTAssertEqual(pointer.frame.midX, app.images["ftueCenterCheckpoint"].frame.midX, accuracy: 1)
            XCTAssertEqual(app.images.matching(identifier: "ftueCenterCheckpoint").count, 1)
            XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
        }
        func complete(finishingTutorial: Bool = false) {
            if finishingTutorial {
                let diamond = app.descendants(matching: .any)["ftueDiamondPointer"]
                XCTAssertTrue(diamond.waitForExistence(timeout: 25))
                XCTAssertTrue(app.staticTexts["RETRIEVE THE DIAMONDS"].waitForExistence(timeout: 25))
                XCTAssertFalse(app.descendants(matching: .any)["gameplayProgressBar"].exists)
            }
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
        app.launch(); waitTitle("Lean your head"); XCTAssertTrue(app.descendants(matching: .any)["ftueFreeLean"].waitForExistence(timeout: 15)); heartSequence("first-time"); practiceSequence("first-time", verifyRetries: true); complete(finishingTutorial: true); app.terminate()

        for solo in [false, true] {
            let mode = solo ? "solo" : "coop"
            // Home starts normally; only finishing the setup instruction enters the fixture.
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
            help.tap(); app.buttons["setupNext"].tap()
            waitTitle("Lean your head"); capture("\(mode)-manual-introduction")
            XCTAssertTrue(app.descendants(matching: .any)["ftueFreeLean"].waitForExistence(timeout: 15))
            capture("\(mode)-free-lean")
            heartSequence(mode, pause: !solo)
            // The first-time run checks attempt-level feedback. Replay checks the
            // stable checkpoints so transient feedback cannot be read from another attempt.
            practiceSequence(mode, verifyRetries: false)
            complete(finishingTutorial: true); capture("\(mode)-manual-completed")
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
