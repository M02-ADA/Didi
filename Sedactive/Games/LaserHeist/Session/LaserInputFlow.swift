import Foundation
import Observation

/// Route/source lifetime only. Gameplay and setup truth remain in the single injected coordinator.
@MainActor @Observable
final class LaserInputFlow {
    nonisolated enum Route: Equatable, Sendable { case selection, replay, liveSetup, diagnostics }
    private(set) var route: Route
    private(set) var session: GameSessionCoordinator?
    private(set) var isStarting = false
    private(set) var isClosing = false
    private(set) var message: String?
    private var operation: UUID?
    private let makeLiveSession: @MainActor () throws -> GameSessionCoordinator
    private let stopDiagnostics: @MainActor () async -> Void
    var canStartLive: Bool { route == .selection && !isStarting && !isClosing }

    init(initialRoute: Route = .selection,
         makeLiveSession: @escaping @MainActor () throws -> GameSessionCoordinator,
         stopDiagnostics: @escaping @MainActor () async -> Void = {}) {
        precondition(initialRoute == .selection || initialRoute == .replay || initialRoute == .diagnostics)
        route = initialRoute
        self.makeLiveSession = makeLiveSession
        self.stopDiagnostics = stopDiagnostics
    }

    nonisolated static func initialRoute(arguments: [String]) -> Route {
        #if DEBUG
        if arguments.contains("--camera-diagnostics") || arguments.contains("--camera-diagnostics-run") {
            return .diagnostics
        }
        let previews = ["-robotDemo", "-directorLaserPreview", "-environmentPreview", "-syntheticCutouts",
                        "-laserArtworkPreview", "-laserGateState", "-avatarPackets", "-avatarFairness",
                        "-normalizedLasers", "-diamondFixture", "-hudPauseMenu", "-replayDebugHUD",
                        "-showEditorPreviews", "-showWorldGuides", "-hideDebugOverlay"]
        if arguments.contains(where: { previews.contains($0) || $0.hasPrefix("-laserPreview") }) { return .replay }
        #endif
        return arguments.contains("-replay") ? .replay : .selection
    }

    func showReplay() {
        guard route == .selection, !isStarting, !isClosing else { return }
        message = nil
        route = .replay
    }

    /// Called after PlayView has awaited its replay session's stop.
    func leaveReplay() { if route == .replay { route = .selection } }

    func startLiveSetup() async {
        guard canStartLive else { return }
        route = .liveSetup
        isStarting = true
        message = nil
        let token = UUID()
        operation = token
        do {
            let session = try makeLiveSession()
            self.session = session
            try await session.start()
            guard operation == token, route == .liveSetup else { return }
        } catch {
            guard operation == token, route == .liveSetup else { return }
            message = Self.explain(error)
        }
        if operation == token { isStarting = false }
    }

    func closeLiveSetup() async {
        guard route == .liveSetup, !isClosing else { return }
        isClosing = true
        let token = UUID()
        operation = token
        await session?.stop()
        guard operation == token else { return }
        session = nil
        isStarting = false
        isClosing = false
        route = .selection
        message = "Camera setup has ended. You can start a fresh setup or use the replay demo."
    }

    /// Explicit user intent only. The same App-retained provider gets a new coordinator/generation.
    func retryLiveSetup() async {
        guard route == .liveSetup, !isStarting, !isClosing else { return }
        await closeLiveSetup()
        guard canStartLive else { return }
        await startLiveSetup()
    }

    func showDiagnostics() {
        guard canStartLive else { return }
        route = .diagnostics
    }

    func closeDiagnostics() async {
        guard route == .diagnostics, !isClosing else { return }
        isClosing = true
        await stopDiagnostics()
        isClosing = false
        route = .selection
        message = "Camera diagnostics have ended. Camera setup is available."
    }

    func handleBackground() async {
        if route == .liveSetup { await closeLiveSetup() }
        if route == .diagnostics { await closeDiagnostics() }
    }

    private static func explain(_ error: any Error) -> String {
        switch error {
        case CameraFailure.permissionDenied, CameraFailure.permissionRestricted:
            "Camera access is unavailable. Review camera access in Settings, then try camera setup again."
        case CameraFailure.unsupported, CameraFailure.cameraUnavailable:
            "Camera setup needs a supported front camera and an iPad held in landscape. Check the device and position before trying again. Replay is still available."
        case is CancellationError:
            "Camera setup was stopped. You can start a fresh setup when ready."
        default:
            "Camera setup could not continue. Try a fresh setup, or use the replay demo."
        }
    }
}
