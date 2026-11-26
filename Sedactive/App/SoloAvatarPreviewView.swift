#if DEBUG
import QuartzCore
import RealityKit
import SwiftUI

/// Uses the existing Solo calibration and pose feed, without attaching a gameplay frame host.
struct SoloAvatarPreviewView: View {
    let flow: LaserInputFlow
    let bodyInput: BodyInputService
    let bridge: VisionNumericPoseBridge
    let onExit: () -> Void

    @State private var isLeaving = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Back", systemImage: "chevron.left") {
                    isLeaving = true
                    Task {
                        await flow.closeLiveSetup()
                        onExit()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLeaving || flow.isClosing)
                .accessibilityIdentifier("closeSoloAvatarPreview")

                Spacer()
                Text("Avatar Preview")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("soloAvatarPreviewTitle")
                Spacer()

                Button("Restart Camera", systemImage: "arrow.clockwise") {
                    Task {
                        if flow.canStartSolo { await flow.startLiveSetup(solo: true) }
                        else { await flow.retryLiveSetup() }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLeaving || flow.isStarting || flow.isClosing)
                .accessibilityIdentifier("restartSoloAvatarPreview")
            }

            HStack(spacing: 12) {
                panel("Camera", identifier: "soloAvatarCameraPanel") {
                    if let capture = bodyInput.camera.previewSession {
                        CalibrationCameraPreview(session: capture)
                            .scaleEffect(x: -1, y: 1)
                            .accessibilityLabel("Live camera")
                    }
                }
                panel("Lemon", identifier: "soloAvatarStagePanel") {
                    if flow.message == nil, !flow.isStarting, !flow.isClosing,
                       let session = flow.session, session.isSoloPractice, session.inputContext?.isActive == true {
                        SoloAvatarStage(session: session, bodyInput: bodyInput, bridge: bridge)
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                            .id(session.inputConfiguration.sessionGeneration)
                    }
                }
            }

            Text(status)
                .font(.callout)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("soloAvatarPreviewStatus")
        }
        .padding(20)
        .foregroundStyle(LaserHeistDesign.cream)
        .background(LaserHeistDesign.night.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await flow.startLiveSetup(solo: true) }
    }

    private var status: String {
        if isLeaving || flow.isClosing { return "Stopping camera…" }
        if let message = flow.message { return message }
        if flow.isStarting { return "Starting camera…" }
        guard let session = flow.session else { return "Tap Restart Camera to start again." }
        if session.phase == .restartRequired || session.setup?.phase == .restartRequired {
            return "Tracking lost. Tap Restart Camera and stand in the center."
        }
        if session.hasLiveRoundPlan { return "Lean left or right to steer Lemon." }
        return "Stand in the center with your whole body in view. Hold still briefly for calibration."
    }

    private func panel<Content: View>(_ title: String, identifier: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityIdentifier(identifier)
            Color.black
                .overlay { content() }
                .clipShape(.rect(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SoloAvatarStage: View {
    let session: GameSessionCoordinator
    let bodyInput: BodyInputService
    let bridge: VisionNumericPoseBridge
    @State private var scene = LaserScene()
    @State private var refresh: EventSubscription?
    @State private var error: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let environment = await LaserScene.loadAuthoredEnvironment()
            do {
                let templates = try await RobotAvatarLayer.sharedTemplates()
                guard !Task.isCancelled, session.inputContext?.isActive == true else { return }
                scene.installEnvironment(authored: environment)
                scene.isLaserVisible = false
                let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
                let pump = try VisionK03MailboxPump(bridge: bridge, mailbox: mailbox)
                scene.attachLiveAvatars(mailbox: mailbox, templates: templates, pump: pump, players: [.player1])
                content.add(scene.root)
                let steering = SoloAvatarPreviewSteering(layout: session.inputConfiguration.playerPlaneLayout)
                refresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene, weak session, weak bodyInput] _ in
                    guard let scene, let session, let bodyInput else { return }
                    let now = CACurrentMediaTime()
                    let context = bodyInput.currentContext
                    let x = steering.update(now: now, context: context == session.inputContext ? context : nil,
                                            snapshot: session.latestSnapshot,
                                            calibration: bodyInput.acceptedCalibrations[.player1])
                    scene.robotAvatars?.authoritativeBoardX = x.map { [.player1: scene.mapping.worldX(corridorX: $0)] } ?? [:]
                    scene.refreshLiveAvatars(now: now)
                }
            } catch {
                self.error = "Avatar unavailable. Restart the camera to try again."
            }
        }
        .overlay { if let error { Text(error).multilineTextAlignment(.center).padding() } }
        .onDisappear {
            refresh?.cancel()
            refresh = nil
            scene.detachLiveAvatars()
        }
    }
}
/// Preview-local board motion, using the gameplay input and board solver on the capture clock.
@MainActor
final class SoloAvatarPreviewSteering {
    private let layout: PlayerPlaneLayout
    private var context: BodyInputContext?
    private var board: LaserBoardField?
    private var frameID: UInt64?

    init(layout: PlayerPlaneLayout) {
        self.layout = layout
    }

    func update(now: Double, context: BodyInputContext?, snapshot: BodySnapshot?,
                calibration: @autoclosure () -> PlayerCalibration?) -> Double? {
        if self.context != context {
            self.context = context
            board = nil
            frameID = nil
        }
        guard let context, context.isActive, let revision = context.calibrationRevisions[.player1] else { return nil }
        if board == nil, let accepted = calibration(),
           accepted.sessionGeneration == context.sessionGeneration, accepted.revision == revision,
           accepted.cameraGeometryRevision == context.cameraGeometryRevision {
            let height = LaserLiveRoundGeometryV1.standingHeight(accepted, layout: layout)
            board = try? LaserBoardField(references: [.player1: .init(
                planeLaneX: layout.centerX(for: .player1), standingHeight: height
            )], at: now)
        }
        guard var board else { return nil }
        defer { self.board = board }

        guard let snapshot, context.accepts(snapshot, playerID: .player1),
              (0..<LiveAvatarPresenter.maximumPoseAge).contains(now - snapshot.capturedAt) else {
            board.halt()
            board.advance(to: now)
            return board.x(.player1)
        }
        if frameID.map({ snapshot.frameID > $0 }) ?? true {
            board.receive(snapshot.players[.player1], player: .player1, calibrationRevision: revision,
                          capturedAt: snapshot.capturedAt, arrivedAt: now)
            frameID = snapshot.frameID
        }
        board.advance(to: now)
        return board.x(.player1)
    }
}
#endif
