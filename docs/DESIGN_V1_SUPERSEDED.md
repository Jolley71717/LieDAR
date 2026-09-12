# LiDAR simulator: the v1 design for a synthetic-room capture backend

_Superseded. This was the first design, written before the red-team pass. The design that was
actually built is in `docs/PLAN.md`. Kept because the reasoning about what a synthetic backend
can and cannot do still holds._

_Written 2026-09-12. The ask that started it: "something that simulates a room and a LiDAR experience that
could feed fake info to ARKit, genuinely useful for everyone, not just us." This records what is
possible, what is not, and the shape of the thing worth building._

## The hard boundary, stated once

ARKit cannot be fed. It owns the camera and sensors through private frameworks with no input
path; `ARFrame`, `ARMeshAnchor`, `ARMeshGeometry` and `ARCamera` have no public initializers; and
on the simulator ARKit does not run. Constructing those types through runtime tricks is possible
in principle and fragile in practice, and it would still not make ARKit *produce* anything.

So the useful design does not inject into ARKit. It **replaces ARKit as the app sees it**: a
small façade the app codes against, with ARKit behind it on hardware and a synthetic backend
behind it on the simulator. Adopters accept one cost for that. Their
capture code consumes the façade's types, not ARKit's. Meshwise already pays that cost at
`RawCaptureWriter`'s payload seam (see `docs/TEST_HARNESS.md`), which is why this is reachable.

## What the synthetic backend produces, per frame

Everything the real one does, from a virtual camera looking at a virtual room:

| ARKit gives | Synthetic backend gives | How |
|---|---|---|
| `sceneDepth.depthMap` (Float32, metres) | depth map | render the room from the virtual camera and read back the depth buffer (SceneKit/RealityKit/Metal), scale to LiDAR resolution (256×192), optional noise |
| `sceneDepth.confidenceMap` | confidence map | high where the surface is near and facing the camera, lower at grazing angles and range limits. A simple function of depth and normal |
| `capturedImage` | colour frame | the same render, colour pass, scaled to camera resolution |
| `camera.transform`, `intrinsics`, `imageResolution` | pose + intrinsics | the virtual camera; intrinsics are constants matching a real iPhone Pro |
| `camera.trackingState` | tracking state | scripted: `notAvailable` → `limited(.initializing)` for the first second → `normal`, with optional `limited(.excessiveMotion)` when the virtual camera moves too fast |
| mesh anchors, growing over time | mesh anchor payloads | the room's geometry pre-chunked into anchor-sized blocks; a block is "discovered" once the virtual camera has seen it, and re-emitted with more triangles as it is seen from more angles, mimicking scene reconstruction |
| classification (wall/floor/ceiling/door/window) | classes | known exactly from the model, which helps tests and hurts realism |

## The virtual room

Two sources, both supported:

1. **Parametric.** Width, depth, ceiling height, a list of wall openings (doors, windows), a
   bulkhead, optional boxes for furniture. Enough to generate a basement in one line and to
   sweep parameters in tests (does extraction survive a 6-foot ceiling? a 40-foot room? an
   L-shape?). Deterministic by seed.
2. **Loaded.** Any USDZ/OBJ, including Meshwise's own exported models, which closes a loop:
   scan a real room on the phone, export it, and it becomes a simulator room you can re-scan.

## The virtual camera

Driven three ways:

- **Interactive** on the simulator: drag to look, keys or on-screen controls to walk, height
  fixed at chest level with a little sway. This is the "point it at a fresh wall" experience.
- **Scripted**: a path (waypoints + look targets + durations) for repeatable tests and demos.
- **Replay**: poses from a recorded capture (`docs/TEST_HARNESS.md`'s fixture format), so a real
  walk-through is re-rendered against the synthetic room, or against the recorded frames.

## The package (open-source shape)

`LiDARSim` is a Swift package, MIT licensed, with no Meshwise types in it:

- `CaptureSource` protocol: `start()`, `stop()`, an `AsyncStream<FramePayload>`, and
  `meshSnapshot() -> [MeshAnchorPayload]`.
- `ARKitCaptureSource`: the real thing, `#if !targetEnvironment(simulator)`.
- `SyntheticCaptureSource`: the room + camera + renderer above.
- `ReplayCaptureSource`: plays a recorded folder.
- `RoomModel` (parametric + loader), `VirtualCamera`, `DepthRenderer`, `AnchorChunker`.
- `SimulatorControls`: a SwiftUI overlay to drive the camera in a Debug build.
- `XCTest` helpers: run a scripted walk and collect the resulting payloads.

The recorder that produces replay fixtures already exists in Meshwise (`RawCaptureWriter`) and
would move into the package as `CaptureRecorder`.

## What it will never do

- Make ARKit run on the simulator, or produce ARKit's own types.
- Reproduce sensor noise, drift, relocalisation, lighting or reflective-surface failures with
  fidelity. Synthetic depth is too clean; noise models can approximate, not replicate.
- Test RoomPlan-based apps. RoomPlan consumes an `ARSession` directly and cannot be faced.
- Replace a real device for sensor-side questions. It moves the device lane from "the only
  test" to "the confirmation", which is the right relationship, and no further.

## Phases

1. **Now, in flight**: `docs/TEST_HARNESS.md` covers the seam, payload types, replay source, and the
   journey test inside Meshwise. This is `ReplayCaptureSource` and the fixture format.
2. **Render the replay**: draw recorded colour frames and arriving mesh in the capture view on
   the simulator, so a replayed scan is something a person can watch. Also the "Demo scan" mode
   for non-LiDAR devices.
3. **Synthetic room, scripted camera**: parametric room, depth/colour renderer, anchor chunking,
   scripted path. First interactive value: extraction tests across room shapes with no fixture
   files at all.
4. **Interactive camera + controls overlay**: the interactive experience described above.
5. **Extract the package**: move the ARKit-free pieces into `LiDARSim`, keep Meshwise as the
   first consumer, publish.

Phase 1 is being built by a worktree agent now. Phases 2 to 5 are a separate project from the App
Store submission and should not start until build 8 is resubmitted; they would otherwise compete
for the same simulator, the same files, and the same attention.
