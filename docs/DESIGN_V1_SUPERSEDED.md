# LiDAR simulator — design for a synthetic-room capture backend

_Written 2026-09-12. Luke's ask: "something that simulates a room and a LiDAR experience that
could feed fake info to ARKit — genuinely useful for everyone, not just us." This records what is
possible, what is not, and the shape of the thing worth building._

## The hard boundary, stated once

ARKit cannot be fed. It owns the camera and sensors through private frameworks with no input
path; `ARFrame`, `ARMeshAnchor`, `ARMeshGeometry` and `ARCamera` have no public initializers; and
on the simulator ARKit does not run. Constructing those types through runtime tricks is possible
in principle and fragile in practice, and it would still not make ARKit *produce* anything.

So the useful design does not inject into ARKit. It **replaces ARKit as the app sees it**: a
small façade the app codes against, with ARKit behind it on hardware and a synthetic backend
behind it on the simulator. The cost of this is the one thing adopters must accept — their
capture code consumes the façade's types, not ARKit's. Meshwise already pays that cost at
`RawCaptureWriter`'s payload seam (see `docs/TEST_HARNESS.md`), which is why this is reachable.

## What the synthetic backend produces, per frame

Everything the real one does, from a virtual camera looking at a virtual room:

| ARKit gives | Synthetic backend gives | How |
|---|---|---|
| `sceneDepth.depthMap` (Float32, metres) | depth map | render the room from the virtual camera and read back the depth buffer (SceneKit/RealityKit/Metal), scale to LiDAR resolution (256×192), optional noise |
| `sceneDepth.confidenceMap` | confidence map | high where the surface is near and facing the camera, lower at grazing angles and range limits — a simple function of depth and normal |
| `capturedImage` | colour frame | the same render, colour pass, scaled to camera resolution |
| `camera.transform`, `intrinsics`, `imageResolution` | pose + intrinsics | the virtual camera; intrinsics are constants matching a real iPhone Pro |
| `camera.trackingState` | tracking state | scripted: `notAvailable` → `limited(.initializing)` for the first second → `normal`, with optional `limited(.excessiveMotion)` when the virtual camera moves too fast |
| mesh anchors, growing over time | mesh anchor payloads | the room's geometry pre-chunked into anchor-sized blocks; a block is "discovered" once the virtual camera has seen it, and re-emitted with more triangles as it is seen from more angles, mimicking scene reconstruction |
| classification (wall/floor/ceiling/door/window) | classes | known exactly from the model — a strength for tests, a caveat for realism |

## The virtual room

Two sources, both supported:

1. **Parametric.** Width, depth, ceiling height, a list of wall openings (doors, windows), a
   bulkhead, optional boxes for furniture. Enough to generate a basement in one line and to
   sweep parameters in tests (does extraction survive a 6-foot ceiling? a 40-foot room? an
   L-shape?). Deterministic by seed.
2. **Loaded.** Any USDZ/OBJ — including Meshwise's own exported models, which closes a loop:
   scan a real room on the phone, export it, and it becomes a simulator room you can re-scan.

## The virtual camera

Driven three ways:

- **Interactive** on the simulator: drag to look, keys or on-screen controls to walk, height
  fixed at chest level with a little sway. This is the "point it at a fresh wall" experience.
- **Scripted**: a path (waypoints + look targets + durations) for repeatable tests and demos.
- **Replay**: poses from a recorded capture (`docs/TEST_HARNESS.md`'s fixture format), so a real
  walk-through is re-rendered against the synthetic room, or against the recorded frames.

## The package (open-source shape)

`LiDARSim` — a Swift package, MIT, no Meshwise types in it:

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

1. **Now, in flight**: `docs/TEST_HARNESS.md` — the seam, payload types, replay source, and the
   journey test inside Meshwise. This is `ReplayCaptureSource` and the fixture format.
2. **Render the replay**: draw recorded colour frames and arriving mesh in the capture view on
   the simulator, so a replayed scan is something a person can watch. Also the "Demo scan" mode
   for non-LiDAR devices.
3. **Synthetic room, scripted camera**: parametric room, depth/colour renderer, anchor chunking,
   scripted path. First interactive value: extraction tests across room shapes with no fixture
   files at all.
4. **Interactive camera + controls overlay**: the experience Luke described.
5. **Extract the package**: move the ARKit-free pieces into `LiDARSim`, keep Meshwise as the
   first consumer, publish.

Phase 1 is being built by a worktree agent now. Phases 2–5 are a separate project from the App
Store submission and should not start until build 8 is resubmitted; they would otherwise compete
for the same simulator, the same files, and the same attention.

## Verified inputs (2026-09-12, before the re-plan)

Facts checked directly, not assumed. The red-team pass and the re-plan start from these.

- **GitHub account.** `gh` is signed in as **`Jolley71717`**, whose account email is
  (account email withheld) — Luke's personal account under a different login than the email
  suggests. The repo goes at `github.com/Jolley71717/<name>`, public, per Luke. Token scopes
  include `repo`; git protocol is SSH. That account has 30 public repos already.
- **Name collisions.** Under `Jolley71717`, `LiDARSim`, `lidarsim`, `lidar-sim`, `LiDARKitSim` and
  `ARKitSim` are all free. Globally, "LiDARSim"/"LidarSim"/"lidarsim" are taken by five robotics
  simulators (ROS, Carla, raytracing, LES), none iOS or ARKit — a discoverability problem, not a
  legal one. **Recommended name: `VirtualLiDAR`** — zero exact-name repos anywhere on GitHub, free
  under `Jolley71717`, says what it is, and keeps "ARKit" (an Apple trademark) out of the name and
  in the description instead. Checked alternatives: `FauxLiDAR` and `LiDARStage` (also zero
  collisions), `DepthStage`/`SimLiDAR`/`LiDARPlayground` (taken by small repos). Searches for
  "ios lidar simulator", "arkit simulator", "arkit depth mock" and "lidar replay ios" return no
  repos at all — the niche is empty, so the README and description carry the keywords. Awaiting
  Luke's confirmation before the repo is created.
- **Toolchain here.** Xcode 26.5 (17F42), Swift 6.3.2. Local simulator runtimes: iOS 18.5,
  26.2, 26.5.
- **CI is feasible.** GitHub-hosted runners: `macos-26` defaults to **Xcode 26.6** (also 26.4.1,
  26.1.1, 26.0.1) with arm64 images; `macos-15` defaults to Xcode 16.4 with 26.x available;
  `macos-14` tops out at Xcode 15.4. So `xcodebuild test` against an iOS 26 simulator works on
  `macos-26`, and the runner is one Xcode point *newer* than this Mac — CI may surface warnings
  local builds do not. Pin the image and the Xcode version in the workflow.
- **Fixture privacy — DECIDED (Luke, 2026-09-12).** No scan of Luke's basement, or any of his
  real captures, goes into the public repo. Public fixtures are parametric/synthetic rooms; if a
  real recorded fixture is ever wanted, it is a scan of a neutral space made for the purpose.
  Meshwise keeps its real fixture gitignored as it is today. This is a hard rule for every agent
  that touches the package: check the fixture's provenance before committing it.
