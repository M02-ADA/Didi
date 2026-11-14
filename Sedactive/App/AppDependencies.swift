import Foundation

/// App owns one retained capture composition and its live provider. Selecting replay/live and
/// driving setup/game phases remains an explicit Jevon integration, never an automatic switch.
@MainActor final class AppDependencies {
  static let shared = AppDependencies()
  /// Seconds of each live activity minute. 60 in every build; DEBUG `-liveShortRound <seconds>`
  /// (10–59) plays only the opening seconds of each minute from the same schedule, for quick
  /// end-to-end device checks. Players, tracking, verdicts and vaults are all still live.
  /// Automatic onboarding everywhere, except the DEBUG tools that drive setup step by step.
  nonisolated static func automaticSetup(arguments: [String]) -> Bool {
    #if DEBUG
    return !arguments.contains(where: { ["--live-avatar-smoke", "--ingame-camera-preview", "--live-wrist-mvp",
      "--camera-diagnostics", "--camera-diagnostics-run"].contains($0) })
    #else
    return true
    #endif
  }
  nonisolated static func liveSegmentLength(arguments: [String]) -> Double {
    #if DEBUG
    if let index = arguments.firstIndex(of: "-liveShortRound"), index + 1 < arguments.count,
       let value = Double(arguments[index + 1]), (10...59).contains(value) { return value }
    #endif
    return 60
  }
  let camera: CameraPipeline
  let bodyInput: BodyInputService
  let visionPoseBridge: VisionNumericPoseBridge
  let inputFlow: LaserInputFlow
  #if DEBUG
  let cameraDiagnostics: LiveInputDiagnosticsModel
  #endif
  private init() {
    let camera = CameraPipeline()
    self.camera = camera
    let bodyInput = BodyInputService(camera: camera)
    self.bodyInput = bodyInput
    visionPoseBridge = VisionNumericPoseBridge(gate: camera.frames.tracking)
    #if DEBUG
    let diagnostics = LiveInputDiagnosticsModel(camera: camera, bodyInput: bodyInput)
    cameraDiagnostics = diagnostics
    #endif
    #if DEBUG
    let route: LaserInputFlow.Route = ProcessInfo.processInfo.arguments.contains("--synthetic-gameplay-preview")
      ? .replay : LaserInputFlow.initialRoute(arguments: ProcessInfo.processInfo.arguments)
    #else
    let route = LaserInputFlow.initialRoute(arguments: ProcessInfo.processInfo.arguments)
    #endif
    #if DEBUG
    let soloSession: (@MainActor () throws -> GameSessionCoordinator)? = {
        // DEBUG Solo Test: the same camera, Vision, tracker, calibration and GameClock, with one
        // player (P1, Lemon). Nothing is created for P2; its lane is hidden.
        var configuration = BodyInputConfiguration(sessionGeneration: UUID(), calibrations: [:],
          playerPlaneLayout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2))
        configuration.soloPlayer = .player1
        let layout = configuration.playerPlaneLayout, roster = configuration.roster
        let segment = Self.liveSegmentLength(arguments: ProcessInfo.processInfo.arguments)
        return GameSessionCoordinator(liveProvider: bodyInput, inputConfiguration: configuration,
          liveRoundPlanner: { context, calibrations in
            try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
              layout: layout, seed: UInt64.random(in: 1...UInt64(UInt32.max)), segmentLength: segment, roster: roster)
          }, automaticSetup: true)
    }
    #else
    let soloSession: (@MainActor () throws -> GameSessionCoordinator)? = nil
    #endif
    inputFlow = LaserInputFlow(initialRoute: route,
      makeLiveSession: {
        // Preserve Edo's existing Vision setup layout. No round plan or collision tuning is
        // selected here; measured game/visual layout acceptance remains a separate gate.
        let configuration = BodyInputConfiguration(sessionGeneration: UUID(), calibrations: [:],
          playerPlaneLayout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2))
        let layout = configuration.playerPlaneLayout
        let segment = Self.liveSegmentLength(arguments: ProcessInfo.processInfo.arguments)
        // After both standing calibrations are accepted, the session installs the complete
        // round built from them. Every action and verdict still comes from live tracking.
        return GameSessionCoordinator(liveProvider: bodyInput, inputConfiguration: configuration,
          liveRoundPlanner: { context, calibrations in
            try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
              layout: layout, seed: UInt64.random(in: 1...UInt64(UInt32.max)), segmentLength: segment)
          }, automaticSetup: Self.automaticSetup(arguments: ProcessInfo.processInfo.arguments))
      }, makeSoloSession: soloSession, stopDiagnostics: {
        #if DEBUG
        await diagnostics.stopAndExport()
        #endif
        // Native loss can leave no camera context while the body-session lease still needs release.
        await bodyInput.stop()
      })
  }
}
