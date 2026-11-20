# LaserHeist gate activation button (PR_GateButton)

One reusable 3D push button for both players' gate consoles, built in Blender from
`ref/gate-button-concept.webp`. Each console clones the same asset
(`Sedactive/Games/LaserHeist/Rendering/GateConsoleView.swift`). It sits on its side of the gate's door
frame (x ±2.45 m), facing the camera, on a compact 0.26 m collar 0.15 m deep that stands on the frame's jamb
(P1 left, P2 right; `LaserGateConsole.swift`). Nothing else is built at the gate.

| File | What it is |
| --- | --- |
| `PR_GateButton.blend` | Editable master (Blender 5.2). The five parts are separate children of the empty `GateButton`. |
| `gatebutton_build.py` | Rebuilds the master from scratch (bmesh, bevels, lathed cap and collar). Every dimension and colour is a named constant. `--render previews` writes the review renders. |
| `gatebutton_export.py` | Writes the game's USDZ, keeping the parts as separate prims. |
| `previews/` | Blender renders (front, three-quarter, side) and RealityKit Simulator captures. The `realitykit_framemount_*` files show the gate-frame mount: Co-op idle and activated, Solo, P1 and P2 reaching with the fist on the cap, a close-up, a side view of the collar, the door passing after opening, and before/after the side-wall layout. Older files show earlier placements. |
| `ref/` | The concept image. |

The runtime asset is
`RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateButton.usdz`, compiled
by the Reality Composer Pro package with the rest of the content. It is preloaded with the mascots
(`RobotAvatarLayer.sharedTemplates()` → `GateConsoleView.sharedTemplate()`). A simple stand-in with
the same part names is shown only if the asset has not loaded.

## Rebuild

```bash
cd Art/LaserHeist/GateButton
/Applications/Blender.app/Contents/MacOS/Blender --background --python gatebutton_build.py -- --out PR_GateButton.blend --render previews
/Applications/Blender.app/Contents/MacOS/Blender --background PR_GateButton.blend --python gatebutton_export.py -- \
  --out ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateButton.usdz
xcrun usdchecker --arkit ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateButton.usdz
```

If you change a dimension, update the matching constants in `LaserGateConsole` (`radius`,
`capFront`, `capEdgeFront`, `collarFront`, `plateHalf`, `bodyDepth`). `GateConsoleViewTests`
measures the loaded asset against them.

## Conventions

- **Units and axes:** metres. Blender is Z up, with the face toward −Y. The USD is Y up, with the face toward +Z (the game camera); the cap presses along −Z.
- **Origin:** the centre of the mounting plate's front face.
- **Parts (prims):**
  - `Housing`: a chamfered octagonal plate, 0.44 m across and 5 cm thick, with four screws. Behind it, a 0.34 m body extends to 0.25 m deep and sinks into the stand.
  - `Collar`: a bevelled ring, 0.40 m across, standing 3.4 cm proud, with four light-bar tabs.
  - `Socket`: a dark bore with its floor 3.5 cm behind the plate.
  - `Cap`: a red cap, 0.30 m across. It has a 4.2 cm deep-red sidewall, a 1.7 cm rounded edge and a 2 cm convex face. Its front centre is 7.9 cm proud of the plate and 4.5 cm proud of the collar. Its origin is at its back.
  - `Accents`: four light bars and the glow ring inside the socket. This is the only emissive part, and the game recolours it.
- **Materials:** UsdPreviewSurface only (flat colours, roughness, metallic, emission). There are no textures or UVs and no Blender-only nodes.
  - Housing: `0x241E58`.
  - Collar metal: `0x3B3480`.
  - Screws: `0x6E68B0`.
  - Socket: `0x0D0A20`.
  - Cap face: `CapRed 0xE3122C`, with a faint red emission and a clear coat.
  - Cap sidewall: `CapSide 0x9A0A1E`.
  - Accents: `AccentGlow 0xFF2A22`.
- **Budget:** 11,464 triangles, and the USDZ is about 0.5 MB.

## In the game

- **Press:** the game moves `Cap` along the mount's axis (converted into the cap's parent space).
  - Rest: 0.
  - Unavailable: −12 mm.
  - Pressed: −25 mm, which puts the cap's edge level with the collar.
  - Activated and locked: −20 mm.
- **Accent colours:** red while live (brighter as the fist approaches), white for the press and gate-open flash, green once activated, and dark while unavailable.
- **Cap colour:** red while idle. It turns green, lit from within, at the bottom of the press. A halo on the wall round it (red, then green) and a green point light make it read from the game camera.
- **Fist contact:** the fist touches the cap's front centre. During the gate the mascot glides 0.21 m sideways to the button's station (presentation only).

## Deviations from the concept

- **No PRESS lettering or chevron on the cap:** at gameplay scale the cap is about 180 px across (a 4:3 Simulator capture). Lettering there would be about 20 px tall and would fight the cap's highlight, so it would not read at a glance.
- **Light bars:** the concept's cream-and-red bars are drawn as single-colour emissive bars, because the game drives their colour by state.
