//
//  CalibrationCameraPreview.swift
//  Sedactive
//

import AVFoundation
import SwiftUI
import UIKit

/// Shows an existing capture session's camera image, for the calibration
/// screen. Display only: it never creates, configures, starts or stops a
/// session; Edo's `CameraPipeline` owns all of that.
///
/// The image is the camera's own, unmirrored and level with the horizon.
/// `CalibrationView` mirrors it for display (the accepted CP2 rule: players
/// see themselves as in a mirror, P1 on the left); the capture data is never
/// mirrored.
///
/// The session is `CameraPipeline.previewSession`, the retained native
/// session. The layer attaches before the camera input exists and levels
/// itself each time the session starts running.
struct CalibrationCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onPreviewReady: () -> Void = {}
    @Environment(\.calibrationPreviewFill) private var fillsViewport

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        // Layout selects fill only after proving full source height / guide visibility.
        view.previewLayer.videoGravity = fillsViewport ? .resizeAspectFill : .resizeAspect
        view.onPreviewReady = onPreviewReady
        view.attach(to: session)
        #if DEBUG
        print(String(format: "[LaserState] t %.3f · camera preview ATTACHED", CACurrentMediaTime()))
        #endif
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        let gravity: AVLayerVideoGravity = fillsViewport ? .resizeAspectFill : .resizeAspect
        if view.previewLayer.videoGravity != gravity { view.previewLayer.videoGravity = gravity }
        if view.previewLayer.session !== session {
            view.attach(to: session)
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.onPreviewReady = nil
        view.stopObserving()
        view.stopWatchingSession()
        view.previewLayer.session = nil
        #if DEBUG
        print(String(format: "[LaserState] t %.3f · camera preview DETACHED", CACurrentMediaTime()))
        #endif
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var started: (any NSObjectProtocol)?
        private var previewObservation: NSKeyValueObservation?
        private weak var configuredConnection: AVCaptureConnection?
        private var startup = Startup()
        var onPreviewReady: (() -> Void)?

        struct Startup {
            enum Action: Equatable {
                case resume(CGFloat)
                case reveal
            }

            private enum Phase {
                case waitingForRotation
                case draining(CGFloat)
                case waitingForFrame
                case visible
            }

            private var phase = Phase.waitingForRotation

            var isVisible: Bool {
                if case .visible = phase { return true }
                return false
            }

            mutating func prepare(angle: CGFloat, allowsQuarterTurn: Bool) -> Bool {
                guard angle == 0 || angle == 180 || allowsQuarterTurn else { return false }
                phase = .draining(angle)
                return true
            }

            mutating func update(isPreviewing: Bool) -> Action? {
                switch (phase, isPreviewing) {
                case (.draining(let angle), false):
                    phase = .waitingForFrame
                    return .resume(angle)
                case (.waitingForFrame, true):
                    phase = .visible
                    return .reveal
                default:
                    return nil
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            levelWithHorizon()
        }

        func attach(to session: AVCaptureSession) {
            // The session can start delivering frames before the main queue
            // receives didStartRunning. Keep its default rotation offscreen.
            alpha = 0
            stopObserving()
            stopWatchingSession()
            previewLayer.session = session
            levelWithHorizon()
        }

        /// Keeps the preview level as the iPad turns, and unmirrored.
        private func levelWithHorizon() {
            watchSession()
            guard window != nil, !bounds.isEmpty, previewLayer.session?.isRunning == true,
                  let connection = previewLayer.connection, configuredConnection !== connection else { return }
            stopObserving()
            alpha = 0
            configuredConnection = connection
            previewObservation = previewLayer.observe(\.isPreviewing, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updatePreviewVisibility() }
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if ProcessInfo.processInfo.isiOSAppOnMac {
                // CalibrationStageView mirrors this layer horizontally. An extra
                // clockwise quarter-turn here appears counterclockwise on screen.
                if let output = previewLayer.session?.outputs.first(where: { $0 is AVCaptureVideoDataOutput }),
                   let capture = output.connection(with: .video) {
                    let corrected = (capture.videoRotationAngle + 90).truncatingRemainder(dividingBy: 360)
                    apply(corrected)
                }
                return
            }
            guard let device = previewLayer.session?.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first(where: { $0.hasMediaType(.video) }) else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                MainActor.assumeIsolated { self?.apply(angle) }
            }
        }

        /// The camera input attaches when setup starts the camera, after this
        /// layer exists, so level again whenever the session starts running.
        private func watchSession() {
            guard started == nil, let session = previewLayer.session else { return }
            started = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                             object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.levelWithHorizon() }
            }
        }

        func stopWatchingSession() {
            if let started { NotificationCenter.default.removeObserver(started) }
            started = nil
        }

        func stopObserving() {
            previewObservation?.invalidate()
            previewObservation = nil
            configuredConnection = nil
            startup = Startup()
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotation = nil
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = configuredConnection, previewLayer.connection === connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            if startup.isVisible {
                connection.videoRotationAngle = angle
                return
            }
            // The iPad capture path accepts mounted landscape (0° or 180°).
            // Mac uses the existing extra quarter-turn correction.
            guard startup.prepare(angle: angle, allowsQuarterTurn: ProcessInfo.processInfo.isiOSAppOnMac) else { return }
            connection.isEnabled = false
            updatePreviewVisibility()
        }

        private func updatePreviewVisibility() {
            guard let connection = configuredConnection, previewLayer.connection === connection else { return }
            switch startup.update(isPreviewing: previewLayer.isPreviewing) {
            case .resume(let angle):
                // Drain any frames from the default connection before restarting
                // this preview at the requested angle.
                connection.videoRotationAngle = angle
                connection.isEnabled = true
            case .reveal:
                alpha = 1
                onPreviewReady?()
            case nil:
                break
            }
        }
    }
}
