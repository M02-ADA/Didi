# Calibration camera preview — Kevin → Edo handoff

Status: **Proposed** (10 November 2026). Live camera display on the calibration screen is **blocked**: nothing exposes the running camera image to presentation code.

## What is ready (Kevin)

- `CalibrationStageView` is camera-first: a full-screen camera slot, mirrored for display only (CP2 rule: players see themselves as in a mirror, P1 in the left guide), the Sketch dashed P1/P2 guides, the session's setup card above them, Back, and a light top fade. Without a camera image it shows a dark viewport and "Camera preview unavailable…", never a fake room.
- `CalibrationCameraPreview(session:)` shows an existing `AVCaptureSession` through `AVCaptureVideoPreviewLayer`: aspect-fill, unmirrored, kept level with `AVCaptureDevice.RotationCoordinator`. It never creates, starts or stops a session. Not verified with a real camera.
- The stage never decides that anyone is placed or calibrated; `LaserSessionSetup` (Jevon) does.

## Missing (Edo)

`CameraPipeline` keeps its `AVCaptureSession` private (the driver's `private var session`), and the only preview, `CameraDiagnosticPreview`, is a DEBUG 5 fps diagnostics path tied to the diagnostics route. The smallest change, either:

1. a read-only accessor for the running session, e.g. `CameraPipeline.previewSession: AVCaptureSession?` (non-nil only while capture runs for the current generation), which `RootView` passes as `CalibrationStageView(cameraPreview: AnyView(CalibrationCameraPreview(session:)))`; or
2. a display frame source from the same session, at display rate.

**Also needed:** the active capture region. The camera image is aspect-filled to the screen, so the guides must be mapped to the camera region Vision measures, or players can stand inside a guide on screen but outside their camera region. Please share the capture format (aspect, rotation) once fixed so the guides can be placed in camera coordinates.

No second `AVCaptureSession`, producer or tracking path is added on the Kevin side.
