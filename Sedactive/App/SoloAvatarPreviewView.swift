#if DEBUG
import QuartzCore
import RealityKit
import SwiftUI

/// Uses the existing Solo calibration and pose feed, without attaching a gameplay frame host.
struct SoloAvatarPreviewView: View {
    let flow: LaserInputFlow
    let camera: CameraPipeline
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
                    if let capture = camera.previewSession {
                        CalibrationCameraPreview(session: capture)
                            .scaleEffect(x: -1, y: 1)
                            .accessibilityLabel("Live camera")
                    }
                }
                panel("Lemon", identifier: "soloAvatarStagePanel") {
                    if flow.message == nil, !flow.isStarting, !flow.isClosing,
                       let session = flow.session, session.isSoloPractice, session.inputContext?.isActive == true {
                        SoloAvatarStage(session: session, bridge: bridge)
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
        if session.hasLiveRoundPlan { return "Move your body to see Lemon follow your pose." }
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
                refresh = content.subscribe(to: SceneEvents.Update.self) { [weak scene] _ in
                    scene?.refreshLiveAvatars(now: CACurrentMediaTime())
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
#endif
