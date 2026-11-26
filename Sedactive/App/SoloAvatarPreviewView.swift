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
        HStack(spacing: 2) {
            panel("Live camera", identifier: "soloAvatarCameraPanel") {
                if let capture = bodyInput.camera.previewSession {
                    CalibrationCameraPreview(session: capture)
                        .environment(\.calibrationPreviewFill, true)
                        .scaleEffect(x: -1, y: 1)
                }
            }
            .overlay { standingGuide }

            panel("Live avatar", identifier: "soloAvatarStagePanel") {
                if flow.message == nil, !flow.isStarting, !flow.isClosing,
                   let session = flow.session, session.isSoloPractice, session.inputContext?.isActive == true {
                    SoloAvatarStage(session: session, bodyInput: bodyInput, bridge: bridge)
                        .id(session.inputConfiguration.sessionGeneration)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { controls.padding(16) }
        .overlay(alignment: .bottom) {
            Text(status)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(LaserHeistDesign.panel, in: Capsule())
                .padding(16)
                .allowsHitTesting(false)
                .accessibilityIdentifier("soloAvatarPreviewStatus")
        }
        .foregroundStyle(LaserHeistDesign.cream)
        .background(LaserHeistDesign.night.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await flow.startLiveSetup(solo: true) }
    }

    private var controls: some View {
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
        .padding(8)
        .background(LaserHeistDesign.panel.opacity(0.9), in: .rect(cornerRadius: 16))
    }

    private var standingGuide: some View {
        GeometryReader { geometry in
            let aspect = bodyInput.camera.negotiated.map {
                Double($0.outputWidth) / Double(max(1, $0.outputHeight))
            } ?? PlayerAcquisitionZones.builtInImageAspect
            let source = CalibrationStageLayout.contentRect(in: geometry.size, aspect: aspect, fill: true)
            let box = PlayerAcquisitionZones.box(.player1, solo: true, imageAspect: aspect)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(LaserHeistDesign.cream, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                .frame(width: min(geometry.size.width * 0.86, source.width * (box.upperBound - box.lowerBound)),
                       height: geometry.size.height * 0.76)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var status: String {
        if isLeaving || flow.isClosing { return "Stopping camera…" }
        if let message = flow.message { return message }
        if flow.isStarting { return "Starting camera…" }
        guard let session = flow.session else { return "Tap Restart Camera to start again." }
        if session.phase == .restartRequired || session.setup?.phase == .restartRequired {
            return "Tracking lost. Tap Restart Camera and stand in the box."
        }
        if session.hasLiveRoundPlan {
            return session.liveReadiness?.phase == .ready
                ? "Lean left or right, duck, or jump."
                : "Stand in the box with your whole body in view."
        }
        let copy = LaserAutomaticSetupCopy(.init(sessionPhase: session.phase, setupPhase: session.setup?.phase,
                                                  presence: session.presence, solo: true,
                                                  restartsAutomatically: false))
        if copy.action == .tryAgain { return "\(copy.instruction) Tap Restart Camera to try again." }
        return copy.instruction
    }

    private func panel<Content: View>(_ label: String, identifier: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        LaserHeistDesign.night
            .overlay { content() }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
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
                scene.attachLiveAvatars(mailbox: mailbox, templates: templates, pump: pump, players: [.player1],
                    liveEvidence: { [weak session] player, capturedAt in
                        guard player == .player1, let session else { return nil }
                        return SoloAvatarPreviewSteering.avatarEvidence(
                            context: session.inputContext, snapshot: session.latestSnapshot, capturedAt: capturedAt
                        )
                    })
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard size.width > 0, size.height > 0 else { return }
            let aspect = Float(size.width / size.height)
            let depth = scene.layout.cameraPosition.z - scene.mapping.interactionPlaneZ
            let framing = max(1, RobotAvatarLayer.narrowestDisplayAspect / aspect)
            scene.setCameraDolly([0, 0, depth * (framing - 1)])
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

    /// Uses the same validated sole and airborne evidence the live game renderer reads.
    static func avatarEvidence(context: BodyInputContext?, snapshot: BodySnapshot?,
                               capturedAt: Double) -> LiveAvatarEvidence? {
        guard let snapshot, context?.accepts(snapshot, playerID: .player1) == true,
              abs(snapshot.capturedAt - capturedAt) <= LiveAvatarPresenter.maximumPoseAge,
              let sample = snapshot.players[.player1], sample.trackingStatus == .reliable else { return nil }
        let geometry = sample.geometry
        let soles = [geometry.leftSoleY, geometry.rightSoleY]
            .filter { $0.validity == .valid }.compactMap(\.value)
        return LiveAvatarEvidence(lowerSoleY: soles.count == 2 ? soles.min() : nil,
                                  airborne: sample.jumpState.validity == .valid && sample.jumpState.phase == .airborne,
                                  centerX: geometry.centerX.validity == .valid ? geometry.centerX.value : nil)
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
