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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        // The whole capture frame, never cropped: the stage sizes this view to the camera's
        // aspect, so aspect fit fills it exactly and players see what tracking sees.
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        view.levelWithHorizon()
        #if DEBUG
        print(String(format: "[LaserState] t %.3f · camera preview ATTACHED", CACurrentMediaTime()))
        #endif
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
            view.levelWithHorizon()
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
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

        /// Keeps the preview level as the iPad turns, and unmirrored.
        func levelWithHorizon() {
            stopObserving()
            watchSession()
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            guard let device = previewLayer.session?.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first(where: { $0.hasMediaType(.video) }) else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor [weak self] in self?.apply(angle) }
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
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotation = nil
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}
