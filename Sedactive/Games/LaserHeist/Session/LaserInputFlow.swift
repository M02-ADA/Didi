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
    /// DEBUG Solo Test: the same flow with a P1-only session. Never set in Release.
    private let makeSoloSession: (@MainActor () throws -> GameSessionCoordinator)?
    /// The current (or last) camera setup is a DEBUG Solo Test.
    private(set) var isSolo = false
    private let stopDiagnostics: @MainActor () async -> Void
    var canStartLive: Bool { route == .selection && !isStarting && !isClosing }

    // MARK: TEMPORARY player-mode selector (testing; remove with the Home picker)
    /// The mode the next camera setup starts in: 2 Players (co-op, the default) or 1 Player
    /// (Solo Practice, the DEBUG solo session). Chosen on the pre-game screen only; a running
    /// setup keeps the mode it started with (`isSolo`). Always co-op without a solo factory
    /// (Release).
    private(set) var selectsSoloPractice = false
    /// The selector is shown and changeable only before a setup starts, with a solo factory.
    var canSelectPlayerMode: Bool { canStartLive && makeSoloSession != nil }
    func selectPlayerMode(soloPractice: Bool) {
        guard canSelectPlayerMode else { return }
        selectsSoloPractice = soloPractice
    }
    /// Starts camera setup in the selected mode (the Home Start path).
    func startSelectedSetup() async {
        await startLiveSetup(solo: selectsSoloPractice && makeSoloSession != nil)
    }

    init(initialRoute: Route = .selection,
         makeLiveSession: @escaping @MainActor () throws -> GameSessionCoordinator,
         makeSoloSession: (@MainActor () throws -> GameSessionCoordinator)? = nil,
         stopDiagnostics: @escaping @MainActor () async -> Void = {}) {
        #if DEBUG
        self.makeSoloSession = makeSoloSession
        #else
        self.makeSoloSession = nil
        #endif
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

    var canStartSolo: Bool { canStartLive && makeSoloSession != nil }

    /// - Parameter solo: DEBUG Solo Test (one player, P1). Ignored without a solo factory.
    func startLiveSetup(solo: Bool = false) async {
        guard canStartLive, !solo || makeSoloSession != nil else { return }
        isSolo = solo
        route = .liveSetup
        isStarting = true
        message = nil
        let token = UUID()
        operation = token
        do {
            let session = try (isSolo ? makeSoloSession! : makeLiveSession)()
            self.session = session
            #if DEBUG
            print("[LaserSetupRestart] flow: starting session")
            #endif
            try await session.start()
            #if DEBUG
            print("[LaserSetupRestart] flow: session started")
            #endif
            guard operation == token, route == .liveSetup else { return }
        } catch {
            guard operation == token, route == .liveSetup else { return }
            message = Self.explain(error)
            #if DEBUG
            print("[LaserSetupRestart] flow: start failed: \(error)")
            #endif
        }
        if operation == token { isStarting = false }
    }

    func closeLiveSetup() async {
        guard route == .liveSetup, !isClosing else { return }
        isClosing = true
        let token = UUID()
        operation = token
        #if DEBUG
        print("[LaserSetupRestart] flow: stopping session")
        #endif
        await session?.stop()
        #if DEBUG
        print("[LaserSetupRestart] flow: session stopped")
        #endif
        guard operation == token else { return }
        session = nil
        isStarting = false
        isClosing = false
        route = .selection
        automaticRestarts = 0
        message = "Camera setup has ended. You can start a fresh setup or use the replay demo."
    }

    /// Explicit user intent only. The same App-retained provider gets a new coordinator/generation.
    func retryLiveSetup() async {
        guard route == .liveSetup, !isStarting, !isClosing else { return }
        let solo = isSolo // Retry keeps the chosen mode; leaving resets it on the next start.
        await closeLiveSetup()
        guard canStartLive else { return }
        await startLiveSetup(solo: solo)
    }

    /// Automatic restarts used in this visit to camera setup (a fresh setup is the only safe
    /// recovery once player identity is lost; never after a round has begun).
    private(set) var automaticRestarts = 0
    static let maximumAutomaticRestarts = 2

    /// Restarts setup by itself when the current one can no longer link the players, before
    /// any round has started. Bounded; then the players choose "Restart setup".
    func restartAutomaticallyIfNeeded() async {
        guard route == .liveSetup, !isStarting, !isClosing, message == nil,
              automaticRestarts < Self.maximumAutomaticRestarts, let session, session.automaticSetup,
              session.state == nil, session.summary == nil,
              session.phase == .restartRequired || session.setup?.phase == .restartRequired else { return }
        automaticRestarts += 1
        let used = automaticRestarts
        // The caller is usually a view task tied to the current session; replacing the session
        // cancels that task. The restart must not inherit it (iPad: the new camera start was
        // cancelled, leaving a black screen), so it runs as its own task.
        #if DEBUG
        print("[LaserSetupRestart] flow: automatic restart \(used) (session \(session.phase), setup \(String(describing: session.setup?.phase)))")
        #endif
        await Task { await self.retryLiveSetup() }.value
        automaticRestarts = used
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
