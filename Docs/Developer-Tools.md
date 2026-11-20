# Developer tools — clean game UI

Branch: `feat/game-clean-ui`, based on `origin/staging` at `3a48722`.
Jevon authorized the UI/App changes across ownership boundaries in this task.

## On an iPad (Debug builds)

- Home starts with the normal game UI only.
- Hold the DIDI logo for 3 seconds to toggle Developer Mode. VoiceOver also offers a named “Toggle Developer Mode” action on the logo.
- When enabled, Home reveals the player-mode selector, replay demo, camera diagnostics, game-scene preview and SFX Replay Lab. “Developer Mode · Turn off” hides them again.
- During a live round, use **Pause → Developer Tools** to open the round panel and timing selector. The round stays paused; use **Pause → Resume** when ready to continue with the tools visible.
- Close the panel with **×**. This also hides the timing selector and stops diagnostic steering. No minimized debug pill remains.
- Camera setup diagnostics and the camera-to-replay shortcut appear only in Developer Mode.
- Mode is kept only in memory. Fully closing and relaunching the app turns it off.

## Xcode and fixtures

Add `-showDebugTools` under Scheme → Run → Arguments Passed On Launch to enable Developer Mode automatically. This enables access; the round panel still opens through Pause.

Explicit fixture arguments continue to work independently: `-debugRoundControlsPreview` retains the existing minimizable panel for layout tests, and `-timingComparison` retains its fixture controls. Other explicit preview routes are unchanged. Release builds compile out Developer Mode and its tools.

No gameplay rules, clock progression, body-input contracts or coordinate mapping changed. Physical-iPad camera/recovery interaction still needs device validation.

## Changed files and integration

- `Sedactive/Games/LaserHeist/Debug/DeveloperToolsState.swift`: shared, main-actor UI state for mode/panel access and diagnostic-steering cleanup.
- `Sedactive/App/RootView.swift`: gate camera/setup diagnostics and the live-round panel.
- `Sedactive/Games/LaserHeist/UI/HomeView.swift`, `LaserHeistIntroView.swift`: hidden activation and gated development entries.
- `Sedactive/Games/LaserHeist/UI/GameplayHUD.swift`: Pause menu entry.
- `Sedactive/Games/LaserHeist/UI/DebugSoloTestControls.swift`: dismissible panel; explicit layout fixture keeps its existing minimize behavior.
- `Sedactive/Games/LaserHeist/UI/PlayView.swift`: gated timing/replay tools and removal of the extra live-round exit button.
- `SedactiveUITests/DeveloperModeUITests.swift`: clean default, long-press activation, relaunch reset, opt-in/off, clean camera setup and panel dismissal coverage.
- `SedactiveUITests/InGameCameraPreviewUITests.swift`, `LaserHeistJourneyUITests.swift`, `RoundSmokeUITests.swift`: opt into debug access for existing development routes.

Skills applied: `swiftui-expert-skill` (state/environment/UI integration), `write-swift` (shared state and actor isolation).

Kevin/Edo integration: UI/App edits were authorized by Jevon for this task. No contract migration is needed. Device validation should cover a live co-op round, Pause → Developer Tools → Resume, closing tools during diagnostic steering, and tracking recovery with tools open.

## Validation — 20 November 2026

Level reached: **builds, tests pass, Simulator checked**. Device not checked.

- Debug Simulator build: passed.
- Release Simulator build (arm64/x86_64): passed.
- `DeveloperModeUITests`: 4 passed on iPad Pro 11-inch (M5), iOS 26.5 Simulator.
- `DebugRoundControlsUITests`: 1 passed (existing explicit fixture).
- `InGameCameraPreviewUITests`: 1 passed.
- `LaserHeistJourneyUITests`: 2 passed.
- `RoundSmokeUITests`: 3 passed.
- Total: 11 distinct UI tests passed; `git diff --check` passed.

The first navigation rerun could not launch its runner because Simulator reported Busy. After explicitly booting the test simulator and waiting for readiness, all 10 navigation tests passed without rebuilding. Build/test logs are in `/private/tmp/game-clean-tests.log`, `/private/tmp/game-clean-navigation-retry.log`, and `/private/tmp/game-clean-release.log`.

The changes are in the original worktree at `/Users/jevon/ADA/Sedactive`. They remain uncommitted and unpushed. The previous `feat/laser-gameplay` edits are preserved in the stash.
