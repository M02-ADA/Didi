# PR_SecurityDrone — asset brief

```text
ASSET      PR_SecurityDrone (prop; LaserHeist security drone, future destructible enemy)
CATEGORY   prop, hard-surface, hovering; rigid articulated parts (no deformation)
VIEWS      ref/drone-concept-sheet.png (1510 x 960, painted concept, perspective, no orthographic sheet)
             hero_threequarter  az ~ -30 (front-left), el ~ 10, ~50 mm look; subject fills ~0.85 of the crop
             front              az 0, el ~ 5; front_threequarter az ~ +35; side az ~ +90 (right side)
             rear / rear_threequarter / bottom: rear from slightly above, bottom from below-front
             state_idle / state_charging / state_firing: front view, emitter states
           All views are perspective concept renders: used for proportions as ratios, silhouette and
           part layout, never for absolute measurement.
SCALE      no scale cue in the sheet. Body diameter 0.60 m (# inferred: reads as a hovering security
           orb next to the 1.6 m mascots, about a mascot head wide plus); antennas add ~0.10 m on top.
PROPORTIONS (front view, as shares of the body diameter D)
           emitter housing outer diameter 0.46 D, centre 0.06 D below the equator
           emitter core diameter 0.20 D; two concentric rings between core and housing
           face mask band (purple) from 0.12 D below to 0.10 D above the equator at the front; its top
             rises toward the back (visor) and meets the spine (hero view; revised after review v4)
           capsule lights 0.14 D wide, centred 0.30 D either side, 0.03 D above the equator
           antennas: base 0.17 D off centre, splayed ~18 deg outward, 0.25 D tall above the shell,
             radius 0.045 D, glowing band at 0.6 of their height
           dial on the upper front, 0.20 D across, centred 0.28 D above the equator, on ivory
           top spine (purple) 0.30 D wide over the crown, starting 0.45 D up the front, behind the
             dark marker triangle; lower front under the emitter is ivory
           side modules 0.54 D across (seen side-on; 0.70 D read as drums in review v2), protruding ~0.03 D, centred 0.05 D below the
             equator; purple plate 0.45 of the module, sun glyph in the plate
           orange accent panels: two slanted dashes per side on the purple visor above the side module
           lower front vents: three slanted slots each side under the capsule lights
           rear: purple panel from the crown down the back, ~0.55 D wide, three vertical vents
           bottom: purple cap with an amber hover light ring and core
PARTS      (construction and overlap order; all separate objects, origins at their pivots)
           MainBody         dark purple inner core sphere (housing; shows in every panel gap)
           ArmorPanels      ivory shells (upper L/R, lower L/R/back), purple top spine, rear panel,
                            face mask band, bottom cap, orange accent strips; rigid, detachable
           FrontEmitter     housing (purple lathe), two rings (rotate about the firing axis),
                            core (emissive, scales / pulses)
           Left/RightSideModule   ivory disc + purple plate + sun glyph; pivot at the disc centre
           Left/RightAntenna      mast + light band; pivot at the antenna base
           AccentLights     capsule lights L/R, hover light (emissive)
           Dial             ring, face, orange arc
           Vents            dark inset slots (front lower L/R, rear)
SILHOUETTE sphere + two splayed antennas + side discs breaking the outline + the raised emitter rim
MATERIALS  Ivory (cream, satin), DeepPurple (housing, satin), Violet (secondary plates), Orange
           (accent strips), EmitterCore (coral-pink emission, state-driven), EmitterRing (dim pink),
           AccentLight (warm amber emission), GlyphLight (warm cream emission)
ARTICULATION rigid parts only (no armature): emitter rings spin about the firing axis, core scales,
           antennas and side modules can detach for destruction, root floats/bobs/rotates
INFERRED   absolute size; exact rear and underside panel layout (rear and bottom views are small);
           depth of every recess; panel thickness; the far (left) side mirrors the right
TARGET     RealityKit (iPadOS), USDZ, Y up / front +Z on export; small-prop-plus budget
           (<= 12k triangles), flat UsdPreviewSurface materials, no textures (like VH_Hoverboard);
           seen at ~150-300 px on screen
```
