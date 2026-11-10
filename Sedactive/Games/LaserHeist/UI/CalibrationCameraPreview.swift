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
/// PENDING Edo: `CameraPipeline` keeps its `AVCaptureSession` private, and
/// the release composition has no pipeline yet, so nothing passes a session
/// here. Not verified with a real camera (Simulator only).
struct CalibrationCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.levelWithHorizon()
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
        view.previewLayer.session = nil
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        /// Keeps the preview level as the iPad turns, and unmirrored.
        func levelWithHorizon() {
            stopObserving()
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
