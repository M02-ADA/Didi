import RealityKit
import simd

/// Posed body volumes in scene metres. The board and reach cursors have no volumes here.
nonisolated struct AvatarDiamondContactCapsule {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let radius: Float

    func overlaps(center: SIMD3<Float>, radius targetRadius: Float) -> Bool {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        let projection = lengthSquared > 0 ? min(1, max(0, simd_dot(center - start, segment) / lengthSquared)) : 0
        let reach = radius + targetRadius
        return simd_length_squared(center - (start + projection * segment)) <= reach * reach
    }
}

extension RobotAvatarLayer {
    func diamondContactBody(_ player: PlayerID) -> [AvatarDiamondContactCapsule] {
        guard let robot = robots[player], robot.container.isEnabled, robot.model.isEnabled else { return [] }
        let skeleton = robot.solver.skeleton
        // The live pose without any HIT reaction: the zap is cosmetic and never moves contact.
        guard let contact = contactPose(player) else { return [] }
        let transforms = contact.joints
        guard transforms.count == skeleton.paths.count else { return [] }
        let pose = skeleton.world(transforms)
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { contact.toWorld(p) }
        let scale = simd_distance(world([1, 0, 0]), world(.zero))
        var volumes: [AvatarDiamondContactCapsule] = []
        func add(_ a: String, _ b: String, radius: Float) {
            guard let start = skeleton(a), let end = skeleton(b) else { return }
            volumes.append(.init(start: world(pose.position[start]), end: world(pose.position[end]), radius: radius * scale))
        }
        add("Pelvis", "Chest", radius: 0.20)
        add("Chest", "Head", radius: 0.11)
        if let head = skeleton("Head") {
            // Both color variants use the same head mesh. Its cheeks are widest
            // below the midpoint, and the two lobes extend up from different Xs.
            // Offsets are from the head joint in its neutral axes, in model metres.
            func addHeadSphere(_ offset: SIMD3<Float>, radius: Float) {
                let center = world(pose.position[head] + pose.rotation[head].act(offset))
                volumes.append(.init(start: center, end: center, radius: radius * scale))
            }
            addHeadSphere([-0.105, 0.243, 0], radius: 0.28)
            addHeadSphere([0.075, 0.243, 0], radius: 0.273)
            addHeadSphere([-0.09, 0.408, 0], radius: 0.265)
            addHeadSphere([0.055, 0.428, 0], radius: 0.262)
        }
        for side in ["L", "R"] {
            add("Chest", "UpperArm_\(side)", radius: 0.10)
            add("UpperArm_\(side)", "Forearm_\(side)", radius: 0.07)
            add("Forearm_\(side)", "Hand_\(side)", radius: 0.07)
            add("Hand_\(side)", "Hand_\(side)", radius: 0.09)
            add("Thigh_\(side)", "Shin_\(side)", radius: 0.09)
            add("Shin_\(side)", "Foot_\(side)", radius: 0.08)
            add("Foot_\(side)", "Foot_\(side)", radius: 0.10)
        }
        return volumes
    }
}
