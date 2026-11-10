import Foundation

/// App owns one retained capture composition and its live provider. Selecting replay/live and
/// driving setup/game phases remains an explicit Jevon integration, never an automatic switch.
@MainActor final class AppDependencies {
  static let shared = AppDependencies()
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
    inputFlow = LaserInputFlow(initialRoute: route,
      makeLiveSession: {
        // Preserve Edo's existing Vision setup layout. No round plan or collision tuning is
        // selected here; measured game/visual layout acceptance remains a separate gate.
        let configuration = BodyInputConfiguration(sessionGeneration: UUID(), calibrations: [:],
          playerPlaneLayout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2))
        return GameSessionCoordinator(liveProvider: bodyInput, inputConfiguration: configuration)
      }, stopDiagnostics: {
        #if DEBUG
        await diagnostics.stopAndExport()
        #endif
        // Native loss can leave no camera context while the body-session lease still needs release.
        await bodyInput.stop()
      })
  }
}
