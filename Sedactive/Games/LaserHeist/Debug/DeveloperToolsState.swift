#if DEBUG
import SwiftUI
import Observation

/// Presentation-only debug access. Never persisted; each process starts clean unless Xcode opts in.
@MainActor
@Observable
final class DeveloperToolsState {
    static let shared = DeveloperToolsState()
    private(set) var isEnabled = ProcessInfo.processInfo.arguments.contains("-showDebugTools")
    private(set) var showsRoundPanel = false

    func toggleEnabled() {
        isEnabled.toggle()
        closeRoundPanel()
    }

    func openRoundPanel() {
        guard isEnabled else { return }
        showsRoundPanel = true
    }

    func closeRoundPanel() {
        showsRoundPanel = false
        RobotAvatarLayer.debugTestSteer = nil
    }
}

extension EnvironmentValues {
    @Entry var developerTools = DeveloperToolsState.shared
}
#endif
