//
//  AppDependencies.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

#if DEBUG
  /// Stable app composition: rebuilding/dismissing a diagnostics view never allocates another source.
  @MainActor final class AppDependencies {
    static let shared = AppDependencies()
    let camera: CameraPipeline
    let cameraDiagnostics: LiveInputDiagnosticsModel
    private init() {
      let camera = CameraPipeline()
      self.camera = camera
      cameraDiagnostics = LiveInputDiagnosticsModel(camera: camera)
    }
  }
#endif
