import Foundation

/// App owns one retained capture composition and its live provider. Selecting replay/live and
/// driving setup/game phases remains an explicit Jevon integration, never an automatic switch.
@MainActor final class AppDependencies {
  static let shared = AppDependencies()
  let camera: CameraPipeline
  let bodyInput: BodyInputService
  let visionPoseBridge: VisionNumericPoseBridge
  #if DEBUG
  let cameraDiagnostics: LiveInputDiagnosticsModel
  #endif
  private init() {
    let camera = CameraPipeline()
    self.camera = camera
    bodyInput = BodyInputService(camera: camera)
    visionPoseBridge = VisionNumericPoseBridge(gate: camera.frames.tracking)
    #if DEBUG
    cameraDiagnostics = LiveInputDiagnosticsModel(camera: camera, bodyInput: bodyInput)
    #endif
  }
}
