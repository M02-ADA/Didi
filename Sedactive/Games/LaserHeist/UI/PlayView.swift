//
//  PlayView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI
import RealityKit

/// Hosts the LaserHeist RealityKit world. Uses RealityKit's virtual camera,
/// not the device camera; live input arrives through Edo's pipeline instead.
struct PlayView: View {
    @State private var scene = LaserScene()
    #if DEBUG
    @State private var preview = LaserApproachPreview()
    #endif

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let authored = await LaserScene.loadAuthoredEnvironment()
            #if DEBUG
            // Launch with `-showEditorPreviews` to overlay the Reality Composer Pro
            // stand-ins on the runtime players and laser and check that they line up.
            scene.installEnvironment(authored: authored, keepEditorPreviews: ProcessInfo.processInfo.arguments.contains("-showEditorPreviews"))
            #else
            scene.installEnvironment(authored: authored)
            #endif
            content.add(scene.root)
            #if DEBUG
            // Launch with `-hideDebugOverlay` to review visuals without debug aids.
            if !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay") {
                content.add(PoseDebugOverlay.make(for: scene))
            }
            preview.start(on: content, scene: scene)
            #endif
        }
        .ignoresSafeArea()
        .background(.black)
    }
}

#Preview(traits: .landscapeLeft) {
    PlayView()
}
