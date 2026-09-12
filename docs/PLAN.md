# LieDAR — re-plan after red team (v2, 2026-09-12)

_Supersedes the design in `docs/LIDAR_SIMULATOR.md` and the seam in `docs/TEST_HARNESS.md` where
they conflict. Every change below traces to a numbered red-team finding (RT-n)._

**Name: `LieDAR`** — Luke's suggestion (2026-09-12), chosen over `LieDAR`. It lies to your
app about LiDAR, which is the pitch in one word, and it is memorable where `LieDAR` was
merely searchable; in an empty niche the README carries the search terms. Casing mirrors LiDAR.
Collision check: free under `Jolley71717` in every casing; globally five hobby repos named
"liedar" (lie-detector projects, ★0–1), zero Swift packages. Module name `LieDAR`, repo
`github.com/Jolley71717/LieDAR`, local `~/git/liedar`.

## What the red team proved and what it changed

**Proved (probe on a throwaway iOS 26.5 simulator, M4 Pro):** Metal is available in the
simulator ("Apple iOS simulator GPU"), runtime shader compilation works, depth readback returns
correct values, 30 frames of 256×192 render + readback in 20 ms. Not proved: GPU availability
inside GitHub's macOS VMs, or under Rosetta.

**Three blockers in the v1 design, all architectural:**

- **RT-1** `RawCaptureView` disables Start when `RawCaptureSession.isSupported` is false, and that
  is a static `ARWorldTrackingConfiguration` query — false on every simulator. A journey test
  cannot tap Start. `EmptyCaptureReason.diagnose` has the same root: on the simulator it returns
  `.unsupportedDevice`, never the reason under test.
- **RT-2** The seam at the writer is one line too low. Everything between the ARKit delegate and
  the writer — tracking tallies that feed the quality score, motion/interval gating, sweep and
  loop-closure voice, anchor add/update/remove bookkeeping — lives in `handle(_:)`, and `stop()`
  takes its mesh from `arSession.currentFrame`, which is nil on the simulator. A replay branch
  would re-implement `handle` and get `[]` for the mesh: an untested copy of exactly the code the
  harness exists to test.
- **RT-3** `CVPixelBuffer` is not `Sendable`; a payload carrying one cannot cross an
  `AsyncStream` in a Swift 6 package. Meshwise only gets away with it under Swift 5 minimal
  concurrency.

## Architecture (v2)

### The seam: a `CaptureSource` injected into `RawCaptureSession` (RT-1, RT-2, RT-7)

```
protocol CaptureSource: AnyObject, Sendable {
    var isAvailable: Bool { get }            // replaces the static ARKit query (RT-1)
    var cameraAuthorized: Bool { get }       // replaces AVCaptureDevice query in diagnose (RT-1)
    func start() throws
    func stop()
    var samples: AsyncStream<CameraSample> { get }
    var anchorEvents: AsyncStream<AnchorEvent> { get }   // .added/.updated/.removed (RT-5)
    func meshSnapshot() -> [MeshAnchorPayload]            // replaces arSession.currentFrame (RT-2)
    func makeCaptureView() -> CaptureViewRepresentable    // ARView on device, RealityKit .nonAR /
                                                          // SceneKit on the simulator (RT-7)
    func raycast(screenPoint: CGPoint) -> SIMD3<Float>?   // annotation placement (RT-7)
}
```

`CameraSample` is cheap and constructed at the delegate boundary: transform, timestamp,
trackingState, and `materialize() -> FramePayload?`, which copies the buffers **while the ARFrame
is alive** and is only called for frames that pass gating. `RawCaptureSession.handle(_ sample:)`
becomes the **single path** for ARKit and replay; there is no `#if DEBUG` branch inside
`start()` or `stop()`. `ARKitCaptureSource` wraps `ARSession` and its delegate; every other source
is a peer, not a special case.

### Payloads are `Sendable` (RT-3, RT-13)

`FramePayload { depth: Plane<Float32>, confidence: Plane<UInt8>?, color: ColorPlanes?,
meta: FrameMeta }` where planes are `Data` + width/height/bytesPerRow and `ColorPlanes` carries
the two 420f planes or one BGRA plane with an explicit `pixelFormat`. Colour is rendered at
≤ 960×720 with matching `imageResolution`/intrinsics — the writer downsizes to 640 anyway.
`MeshAnchorPayload { id: UUID, transform, vertices: Data, faces: Data, classes: Data, counts }`.
The package builds in **Swift 6 language mode from day one**.

### Deterministic depth from a CPU raycaster (RT-9)

Canonical depth, confidence and mesh come from a CPU raycaster over the room's triangles:
~49k rays × < 200 triangles ≈ 10 to 20 ms per frame, bit-identical on every arm64 machine, no Metal. The
GPU renders **only the on-screen preview**. Golden-value tests therefore do not drift between an
M4 and a CI runner, and x86_64/Rosetta simulators (where Metal is unavailable) still run every
test.

### Realism models, because perfect data lies (RT-4, RT-5, RT-14)

- **Classification degradation:** a fraction of vertices labelled `none` (default 30 %),
  floor↔table confusion, per-anchor label noise, seeded. `BasementExtractor` requires all three
  vertices of a wall triangle to be `.wall` and derives floor height from `.floor` vertices; a
  sweep on perfect labels would pass on data no phone produces. The suite runs at ≥ 30 %
  unlabelled by default.
- **Anchor churn:** chunks overlap their neighbours (duplicate triangles the PLY merge must
  survive), are occasionally removed and re-added under a new UUID, and a scripted loop-closure
  event translates every anchor a few centimetres at once.
- **Gating is real:** `handle` writes only `.normal`-tracking frames and only when the pose has
  moved ≥ 0.15 m / 10° or 0.5 s has passed. Scripted paths must move; the README states that
  `frameCount ≠ frames fed`.

### Fixtures are generated, never recorded from a home (RT-6, RT-11)

There is no recorded fixture in the public repo. `tools/make_fixture.sh <seed>` runs the
parametric room + scripted camera through the package's own recorder and writes a tiny,
seed-deterministic capture; the committed artefact is the generator call plus its output
(target < 300 KB). `tools/fixture_audit.sh` fails `RESULT: FAIL` on any `.jpg`/`.jpeg`, any
`worldmap.bin`, any file > N vertices, or any manifest carrying a real device model/OS string
under `Fixtures/`. Sample USDZ/OBJ rooms are generated or CC0; Apple sample assets are not
MIT-compatible. Meshwise's `samples/full` stays gitignored where it is (D10).

### Format spec first (RT-15)

Before any writer moves, the on-disk capture format (`RawCaptureFormat`) is extracted as a
versioned spec (`docs/CAPTURE_FORMAT.md` in the package, `formatVersion` in the manifest) that the
package owns and Meshwise consumes. `CaptureRecorder` in the package writes it with **no UIKit,
CoreImage or Meshwise types**; JPEG encoding uses ImageIO.

### Packaging (RT-10)

`platforms: [.iOS(.v16)]`. `ARKitCaptureSource` behind `#if canImport(ARKit)` plus a runtime
`isSupported` — not `targetEnvironment(simulator)`, because the synthetic source is wanted on
non-LiDAR *devices* too (demo mode). No `.metal` files in the package (SwiftPM compiles them only
under Xcode); the preview shader is a source string compiled at runtime, which the probe proved.
`LICENSE` (MIT) and a semver tag from the first release so Swift Package Index indexes it; macOS
builds stay green because ARKit imports are guarded.

## CI verdict (2026-09-12, first run on GitHub)

`tools/ci_smoke.sh` on `macos-15` with Xcode 26.1.1 (17B100): the runner created and booted an
iPhone simulator (device type `iPhone-15-Plus`, the newest the grep picked on that image) and
`MTLCreateSystemDefaultDevice()` on the host returned **"Apple Paravirtual device"**. So GitHub's
macOS VMs do expose a Metal device — the red team's one unverified assumption (RT-8/RT-9) is
resolved for the host. Whether the *simulator's* GPU supports depth-texture readback there is
answered by `MetalAvailabilityTests` once phase 0 lands (it skips with "no Metal device" rather
than failing). Timing: simulator create+boot took ~5 min on the runner; budget accordingly.
The unit job reported `RESULT: BLOCKED no Package.swift/tools/test.sh yet` and stayed green,
which is the intended behaviour before phase 0. The first run failed in 0 s because `hashFiles`
is not permitted in a job-level `if`; gating moved to a step.

**Phase 0 merged and CI-proven (2026-09-12 18:25).** Run #34710583105 on `macos-15`/Xcode 26.1.1:
`RESULT: PASS macOS 41 tests/0 failures/4 skipped; simulator 41 tests/0 failures/4 skipped` on an
iPhone 17 Pro Max simulator (iOS 26.2 runtime on the runner). The 4 skips are the parity tests,
which need `LIEDAR_PARITY_CAPTURE` and correctly skip on a clean clone. See the line above the
layout section for the Metal-in-simulator result on the runner.

**Phase 2, package half, on branch `phase2-synthetic` (2026-09-12).** `RoomModel`, `Raycaster`,
`VirtualCamera`, `AnchorChunker`, `DegradationModel`, `SyntheticCaptureSource`, `FrameGate` and
`ScriptedCapture` are in; `Fixtures/synthetic-1` (13 frames, 41 anchors, 201 KB) is generated by
`tools/make_fixture.sh 1`. `docs/REALISM.md` is written. The Example app and the XCUITest
journeys (the other half of the phase-2 acceptance row) are a separate piece of work.

After the 2a review (three required changes: timing test out of the default suite, a confidence
golden with a grazing-angle pixel and a mutation proof for it, arm64 wording) the following was
run locally on an M4 Pro with Xcode 26.5 (17F42), Swift 6.3.2, in this order, each exit 0:

- `swift build -Xswiftc -warnings-as-errors`: clean, 0 warnings.
- `LIEDAR_SIM_NAME=LieDAR-2a bash tools/test.sh`: `RESULT: PASS macOS 80 tests/0 failures/1 skipped;
  simulator 80 tests/0 failures/1 skipped (iPhone-17-Pro-Max, iOS 26.5)`. The one skip on each
  leg is `RaycasterTests/testRenderTimeIsWithinBudget`, which skips without
  `LIEDAR_ASSERT_TIMING=1`. The parity tests ran because a consumer capture was present.
- `bash tools/timing_check.sh`: `RESULT: PASS raycaster 11.79 ms/frame in release (256×192,
  ceiling 20 ms), 245759 hits over 5 frames` (245 760 pixels, one seam miss).
- `bash tools/mutation_check.sh`: `RESULT: PASS 4/4 tests fail on their named assertion when
  their line is mutated, files restored`. Case D replaces `mediumCosine` 0.2 with 0.0 in
  `Raycaster.ConfidenceModel.init`, and `testConfidenceMatchesGoldenBytes` fails on
  `corridor pixel (105, 96)` (got 1, expected 0). The canonical frame's confidence histogram is
  30 541 high / 18 611 medium / 0 low, so `canonical-conf.bin` alone cannot see that mutation.
  The corridor pixel is what catches it.
- `bash tools/fixture_audit.sh`: `RESULT: PASS 165 file(s) under Fixtures/`.

## Repository layout (RT-8)

```
LieDAR/
  Package.swift                 library LieDAR + LieDARTests (XCTest, unit + golden)
  Sources/LieDAR/         CaptureSource, payloads, RoomModel, VirtualCamera, Raycaster,
                                AnchorChunker, DegradationModel, ReplayCaptureSource,
                                SyntheticCaptureSource, CaptureRecorder, format spec types
  Sources/LieDARARKit/    ARKitCaptureSource  (#if canImport(ARKit))
  Sources/LieDARUI/       SimulatorControls overlay, preview view (RealityKit .nonAR/SceneKit)
  Tests/LieDARTests/      unit + golden (CPU raycaster is deterministic → exact goldens)
  Example/                      COMMITTED Example.xcodeproj (no xcodegen on runners):
    ExampleApp/                 minimal capture app using the package end to end
    ExampleUITests/             the black-box journeys (XCUITest needs an app host)
  Fixtures/                     generated only; audited
  tools/                        make_fixture.sh, fixture_audit.sh, ci_smoke.sh — each one RESULT: line
  docs/CAPTURE_FORMAT.md, docs/REALISM.md (what it cannot reproduce), README, LICENSE
  .github/workflows/ci.yml
```

## CI (RT-8, RT-9)

`runs-on: macos-15` (arm64 image) with an explicit `xcode-select` to a pinned Xcode from the
runner-images list — never `macos-latest`. Jobs, in order, each failing loud:
1. **smoke** — `tools/ci_smoke.sh`: `xcrun simctl create` a named device, `boot`, `bootstatus -b`,
   and a 20-line Metal probe; prints `RESULT: BLOCKED` (not PASS) if `MTLCreateSystemDefaultDevice()`
   is nil, because GPU passthrough in GitHub VMs is unverified. Tests do not depend on Metal
   (RT-9), so a BLOCKED smoke only disables the preview job.
2. **unit** — `xcodebuild test -scheme LieDAR-Package -destination 'platform=iOS Simulator,id=<UDID>'`.
3. **journeys** — `xcodebuild test -project Example/Example.xcodeproj -scheme ExampleApp
   -only-testing:ExampleUITests`, `-parallel-testing-enabled NO`, `-retry-tests-on-failure`,
   `timeout-minutes: 45`.
4. **fixture-audit** — `tools/fixture_audit.sh`.
5. **mutation** — the journey that guards the save signal must fail with the signal removed.
Expect 8–15 min per run; free on a public repo. Nothing to cache.

## Test strategy — black box in the middle

- **Journeys (Example app, XCUITest):** Home → Start → frames climb → Stop & Save → row with
  correct size and no empty badge → folder screen with non-zero counts → extraction yields ≥ 1
  room. A second journey: Start, Stop immediately → discarded, no row. A third: capture with the
  loop-closure event and 30 % unlabelled → extraction still yields a room. Values, not presence;
  every journey ends back on Home with no modal (Meshwise's round-trip rule).
- **Golden tests (package):** the raycaster's depth for a canonical room + pose is asserted to
  exact bytes; the chunker's anchor set for a scripted path is asserted by count and bounds.
- **Mutation proofs:** `tools/mutation_check.sh` removes one line at a time (the save signal, the
  loop-closure translation, the gating threshold) and demands the named test fail on the named
  assertion — Meshwise's Card 17 pattern, generalised.
- **What it cannot reproduce** is written in `docs/REALISM.md` and repeated in the README:
  sensor noise, drift, relocalisation, lighting, reflective failures, RoomPlan.

## Phases and acceptance

| # | Deliverable | Accepted when |
|---|---|---|
| 0 | Format spec + `CaptureRecorder` + Sendable payloads, in the package | `docs/CAPTURE_FORMAT.md` names every file, field and byte layout; the package's reader parses a real consumer capture (manifest, frame meta, anchor binaries, PLY header) with counts agreeing with the disk; the writer matches the spec by construction (same layout, encoder settings and PLY builder as the consumer's) and by golden tests that pin exact bytes, JSON and PLY text; `swift build -warnings-as-errors` clean and `tools/test.sh` PASS on macOS and a throwaway simulator |
| 1 | `CaptureSource` injected into Meshwise's `RawCaptureSession`; `ARKitCaptureSource`; `ReplayCaptureSource`; Start enabled by `isAvailable` | Meshwise's existing unit tests pass against the package's writer byte-for-byte on a fixture; Meshwise device lane green (Card 2) AND a replayed capture on the simulator reaches the list with no badge, via the real `handle`/`stop` |
| 2 | Parametric `RoomModel`, CPU `Raycaster`, `AnchorChunker`, `DegradationModel`, scripted `VirtualCamera`, generated fixtures + audit | Example journeys 1–3 green on a throwaway simulator; goldens exact; mutation proofs fail correctly |
| 3 | `SyntheticCaptureSource` wired into Meshwise behind a Debug launch argument; preview view; `SimulatorControls` | A person can walk a virtual basement in the Meshwise simulator build and extract a plan |
| 4 | CI on GitHub; README/REALISM/LICENSE; first tag | Green on `macos-15` from a clean clone; SPI builds |

Phase 1 replaces the seam built by the `capture-harness` agent; its fixture-format work and its
journey test are reused where they survive the seam change, and its evidence is reviewed against
RT-1/RT-2 before anything is merged.

## Changes to Meshwise itself

- `RawCaptureSession` takes a `CaptureSource`; `RawCaptureView.start` is gated on
  `source.isAvailable`; `EmptyCaptureReason.diagnose` takes availability and camera-auth from the
  source (RT-1).
- `DeviceFixtureTestHooks` stops writing a real device model, OS version and timestamps into a
  fixture that could be copied anywhere (RT-11); uses fixed synthetic values.
- Meshwise consumes the package as a local path dependency during development and a tagged
  version after the first release.

## Open decisions for Luke

1. Name: `LieDAR` — DECIDED (Luke, 2026-09-12).
2. Minimum iOS: 16 (package) while Meshwise stays iOS 18+ — fine, confirm.
3. First public push: after phase 2 is green (a usable thing), not after phase 0 (a skeleton).
