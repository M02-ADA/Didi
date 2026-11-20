# LaserHeist gate console stand (PR_GateConsole)

> **Superseded (20 November 2026).** The game no longer loads this stand. The gate button is now mounted directly on the corridor's original side wall, with no stand, box or jamb (`LaserGateConsole`, `GateConsoleView`). This folder and `RealityKitContent/.../GateConsole.usdz` remain only as history and can be deleted.

The front-facing stand that holds the approved gate button
(`Art/LaserHeist/GateButton/`). It was built in Blender after `ref/gate-console-concept.webp`.

- **Rendering code:** each console clones it in `Sedactive/Games/LaserHeist/Rendering/GateConsoleView.swift`. The geometry lives in `LaserGateConsole.swift`.
- **Placement:** the head is placed in the button's frame. The post and foot stand at the stand's existing floor position, yawed with the head.
- **Mirroring:** the head is symmetric, so P1 and P2 mirror the placement, never the mesh.
- **What it replaced:** the leaning column housing, which faced along the corridor wall, so the game camera saw it side-on.

| File | What it is |
| --- | --- |
| `PR_GateConsole.blend` | Editable master (Blender 5.2). Its four parts are separate children of the empty `GateConsole`. |
| `gateconsole_build.py` | Rebuilds the master from scratch. Every dimension and colour is a named constant. `--render previews` links the button master in for review renders only. |
| `gateconsole_export.py` | Writes the game's USDZ, keeping the parts as separate prims. |
| `previews/` | Blender renders (front, three-quarter, side) and RealityKit Simulator captures: before/after, gameplay, P1 and P2 idle/pressing/activated, close-ups, and a wall-side profile. |
| `ref/` | The concept image. |

The runtime asset is
`RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateConsole.usdz`.

- **Loading:** `GateConsoleView.sharedTemplate()` loads it together with the button, preloaded alongside the mascots.
- **Fallback:** if it has not loaded, a simple stand-in with the same part names and proportions is shown instead.

## Rebuild

```bash
cd Art/LaserHeist/GateConsole
/Applications/Blender.app/Contents/MacOS/Blender --background --python gateconsole_build.py -- --out PR_GateConsole.blend --render previews
/Applications/Blender.app/Contents/MacOS/Blender --background PR_GateConsole.blend --python gateconsole_export.py -- \
  --out ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateConsole.usdz
xcrun usdchecker --arkit ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateConsole.usdz
```

If you change the head's size, update `LaserGateConsole`:

- the constants `headHalfWidth`, `headHalfHeight`, `headFront`, `headDepth` and `headCorner`;
- `GateConsoleView.postModelHeight`.

`GateConsoleViewTests` measures the loaded head against the console's box. `LaserGateConsoleTests` checks that the docked mascot's body clears it by more than 2 cm.

## Conventions

- **Units and axes:** metres. Blender is Z up, with the face toward −Y. The USD is Y up, with the face toward +Z (the game camera).
- **Head:** its origin is the button's mount, the centre of the button plate's front face.
  - **Front:** an octagonal outline 0.58 × 0.54 m with 0.12 m cut corners. It is 5 cm behind the mount, where the button plate's back meets it.
  - **Front frame:** 5 cm wide, around a dark panel recessed 1.4 cm.
  - **Depth:** 0.50 m at the bottom, the post rises into this lower back. The top is flat for 0.24 m, then chamfers down to the back.
  - **Edges:** all 2.6 cm bevels.
- **Post:** 0.17 m square, origin at its foot, modelled 0.80 m tall. The game stretches it from the foot to 0.10 m inside the head.
- **PostStrip:** the emissive strip on the post's front, with the same origin and height as the post. The game recolours it: dim while unavailable, violet while live, green once the side is done, and a white flash when the gate opens.
- **Foot:** a 0.30 × 0.34 × 0.03 m floor plate, origin at its bottom centre.
- **Materials:** UsdPreviewSurface only (flat colours, roughness, metallic, emission). There are no textures or UVs.
  - Shell: `0x3A2E8A`, with a light clear coat.
  - Recessed panel: `0x1B1645`.
  - Post: `0x30276F`.
  - Foot: `0x221C52`.
  - Strip: `0x8C7BFF`, emissive.
- **Budget:** 1,196 triangles, and the USDZ is about 57 KB.

## Placement in the game (measured, `LaserGateConsoleTests`)

- **Orientation:** the approved button is unchanged. It is level and faces 80 % of the way from the corridor toward the game camera (a head yaw of 46.9°).
- **Hand alignment (19 November 2026):** the button sits at the mascot's depth (`mountDepth` 0.011 m in front of the players' plane), 0.075 m outward of the console face (`standOff`).
  - Its contact point lies on the reach plane the mascot's hand already stops at. A straight arm's fist ends 0.10 m from it, sideways only; it was 0.26 m before, 0.20 m of that toward the camera.
- **Mascot stop and arm (20 November 2026, iPad review):** during a gate only, the mascot stops 20 cm further from its wall (`dockBack`; the gate's dock), so it stands clearly apart from its console. The rest of the round it keeps the full corridor up to the wall stop (`wallStopX`).
  - **Presentation only:** the game state (`LaserBoards`) is unchanged, with its docks and bounds at ±1.746. While a gate's consoles show (no laser is judged then), a mascot whose game-state board is beyond its gate dock is drawn eased back onto it over 0.2 s, and eased out again when the gate opens. The judge measures from the drawn mascot (`vaultReachShift`).
  - The button's contact is where the mascot's arm ends when it opens wide toward the wall: 97 % straight (`armReach`), 15° down (`armDown`), 20° into the scene (`armBack`).
  - The fist **snaps** onto the cap once the wrist is within 1.2 radii of its judged zone. It locks on in about 0.05 s and lets go beyond 1.4 radii.
  - The hand is kept on the console's surface (`LaserGateConsole.outsideConsole`), never inside it.
  - DEBUG launch arguments `-gateDockBack`, `-gateArmBack` (degrees), `-gateSetBack` and `-gateSetOut` try other placements on a device. They change the look only; the game state is unaffected.
- **Post:** the stand keeps its floor position (0.36 m outward of the face) except for the 23 cm it takes to keep the post under the head. The post sits flush with the head's outer side, 0.155 m behind the mount.
- **Clearances:** the docked body clears the button by at least 15 cm and the head by 16.7 cm. The docked board clears the post by 14 cm. The fist arrives on the cap's face.

## Deviations from the concept

- **Lettering:** the concept's PRESS text and chevron are not on the cap (see the button README).
- **Post position:** the post sits toward the head's back outer corner rather than under its middle, because the stand's floor position was kept.
