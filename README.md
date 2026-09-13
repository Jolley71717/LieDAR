# LieDAR

**It lies to your app about LiDAR.** Run iOS LiDAR and ARKit apps on the Simulator: replay recorded
captures or scan a synthetic room. Depth, confidence, mesh anchors and camera poses, no hardware
required.

ARKit cannot be fed: it has no input path and its frame and anchor types have no public
initializers, and on the Simulator it does not run at all. LieDAR replaces ARKit *as your app sees
it*, with a small `CaptureSource` façade. ARKit sits behind it on a device, and a synthetic room, a
virtual camera and a deterministic CPU raycaster behind it on the Simulator. The cost is the one
thing adopters accept: capture code consumes LieDAR's `Sendable` payload types, not ARKit's.

Status: **pre-release.** The synthetic source works end to end and is tested, so you can point a
capture at it today. Not wired into a real app yet. `docs/PLAN.md` has the design, the red-team
findings that shaped it, and what each phase has to prove before it counts as done;
`docs/RELEASE_NOTES.md` has what changed in each version.

There is one library product, `LieDAR`. The `LieDARARKit` and `LieDARUI` targets are placeholders
for phases 1 and 3 and are not products yet, so nothing can depend on them until they hold code.

## Using it

Add the package, then pin an exact version. This is 0.x and the protocol will change when the
source is wired into a real app.

```swift
// docs-check: skip
.package(url: "https://github.com/Jolley71717/LieDAR", exact: "0.1.1")
```

### Render one depth frame

The smallest useful thing. No files, no capture, just a room and a camera pose.

```swift
import LieDAR
import simd

let room = RoomModel.parametric(.canonical)
let caster = Raycaster(model: room)

// Stand at chest height, two metres in and one across.
var cameraToWorld = matrix_identity_float4x4
cameraToWorld.columns.3 = SIMD4<Float>(2, CameraPath.chestHeight, 1, 1)

let frame = caster.render(cameraToWorld: cameraToWorld, intrinsics: .iPhonePro)
print("\(frame.width) by \(frame.height), \(frame.hitCount) rays hit something")
print("depth is metres, 0 for a miss; confidence is 0 low, 1 medium, 2 high")
```

### Record a whole capture, then read it back

`ScriptedCapture.record` runs a source through the frame gate into a recorder, which writes the
on-disk format in `docs/CAPTURE_FORMAT.md`. Note that frames written is not samples fed: the gate
drops frames the camera did not move far enough for, exactly as a real capture does.

```swift
import Foundation
import LieDAR

let folder = URL.temporaryDirectory.appending(path: "liedar-example")
let source = SyntheticCaptureSource(configuration: .init(seed: 7, seconds: 3))

let report = try await ScriptedCapture.record(from: source, to: folder)
print("fed \(report.samplesSeen) samples, wrote \(report.framesWritten) frames")

let reader = CaptureReader(folderURL: folder)
let manifest = try reader.manifest()
print("\(manifest.frameCount) frames, \(manifest.meshAnchorCount) anchors, \(manifest.totalFaces) faces")
```

### The integration pattern

This is the part that decides whether the package is useful to you. Write your capture code
against `CaptureSource` and never name a concrete source inside it. Then the same code runs
against ARKit on a device and against a synthetic room on the Simulator, and your tests drive the
real path rather than a mock of it.

```swift
import Foundation
import LieDAR

// Your code. It never mentions ARKit or LieDAR's synthetic source.
func record(with source: some CaptureSource, to folder: URL) async throws -> Int {
    guard source.isAvailable else { return 0 }
    return try await ScriptedCapture.record(from: source, to: folder).framesWritten
}

// Your app picks the source once, at the edge, and nothing downstream branches on it.
func makeSource() -> any CaptureSource {
    #if targetEnvironment(simulator)
    return SyntheticCaptureSource(configuration: .init(seed: 1, seconds: 2))
    #else
    return SyntheticCaptureSource(configuration: .init(seed: 1, seconds: 2))  // your ARKit source here
    #endif
}
```

Gate on `source.isAvailable`, never on a static query such as
`ARWorldTrackingConfiguration.supportsSceneReconstruction`. That query is false on every
Simulator, so a static check disables your capture button in the one place this package exists to
help.

### Performance, and the one thing that will surprise you

The raycaster is deliberately on the CPU, with no Metal, so it returns identical bytes on every
arm64 machine. That determinism is what makes byte-exact goldens possible. It costs you nothing
in release and a great deal in debug:

| Build | Time per 256 by 192 depth frame |
|---|---|
| Release | about 10 ms |
| Debug | about 88 ms |

Measured on an M-series Mac. Nine times, which is ordinary for Swift: a debug build keeps bounds
checks, skips inlining and does no cross-function optimisation, and this is a tight loop over
49,152 pixels.

`swift test` and Xcode's test action both build debug by default. If a replay looks too slow to
keep up, check the configuration before you look at anything else. `tools/timing_check.sh`
asserts the release figure against a 20 ms ceiling so a regression is caught rather than noticed.

## The synthetic source (phase 2)

`SyntheticCaptureSource(seed:)` is a `CaptureSource` with no hardware behind it:

- `RoomModel` builds a parametric room (width, depth, ceiling, doors and windows, a bulkhead,
  furniture, an optional L-shape) meshed into classified triangles, deterministic by seed; or
  any ASCII OBJ.
- `Raycaster` runs on the CPU with no Metal: depth, confidence and a triangle id per pixel, bit-identical on
  every arm64 machine, about 12 ms per 256 × 192 frame in a release build on an M-series Mac.
- `VirtualCamera` walks a scripted path at chest height with a little sway, iPhone Pro intrinsics,
  and a tracking script (`notAvailable` → `limited.initializing` → `normal`, with
  `limited.excessiveMotion` when the script moves too fast).
- `AnchorChunker` emits metre-sized anchors that appear as the camera sees them, grow, overlap,
  are occasionally dropped and re-added under a new id, and all shift at once on a scripted
  loop closure.
- `DegradationModel` leaves 30 % of faces unlabelled, confuses floor with table, and adds per-anchor noise.

`ScriptedCapture.record(from:to:)` runs any source through the PLAN's write gate (`normal`
tracking and ≥ 0.15 m / 10° / 0.5 s since the last written frame) into `CaptureRecorder`, so
**`frameCount` is not the number of frames fed**: a 3-second tour at 30 Hz feeds 91 samples and
writes 13 frames. `tools/make_fixture.sh <seed>` writes `Fixtures/synthetic-<seed>/` the same way
and proves two runs are byte-identical; `tools/mutation_check.sh` proves the realism tests fail
when their code is removed. What the source cannot reproduce, meaning sensor noise, drift,
relocalisation, lighting, reflective failures and RoomPlan, is spelled out in `docs/REALISM.md`.

## The example app (phase 2)

`Example/` is a small capture app built on the package, and the black box the end-to-end tests
drive. Home list, a Start/Stop screen with a live HUD of frames written, anchors held and seconds
elapsed, and a detail screen that reads the saved folder back through `CaptureReader`. The
capture loop in `Example/ExampleApp/CaptureEngine.swift` is the part to copy. It is everything
an adopting app writes between Start and Stop, and nothing in it knows the source is synthetic.

Open `Example/Example.xcodeproj` and run. The project is committed and takes the package as a
local path dependency, so there is no generation step and nothing to fetch. Three XCUITest
journeys drive it on a throwaway simulator:

```
bash tools/journeys.sh          # RESULT: PASS 3 passed/0 failed/0 skipped (...)
bash tools/journey_mutation.sh  # RESULT: PASS 1/1 ...
```

The journeys assert values, not presence: the size the saved row shows must equal the bytes in
the folder, a capture that yielded nothing must add no row at all, and a degraded run must come
back with at least 15 % of its faces unlabelled. `tools/journey_mutation.sh` proves the first one
is load-bearing by deleting the single line that publishes a capture to the list and requiring
the journey to fail on its named assertion, then restoring the file byte-identical. See
`docs/EXAMPLE_APP.md`.

## What it will never do

Make ARKit run on the Simulator; produce ARKit's own types; reproduce sensor noise, drift,
relocalisation, lighting or reflective-surface failures with fidelity; test RoomPlan-based apps
(RoomPlan consumes an `ARSession` directly). It moves the physical-device lane from "the only
test" to "the confirmation", and no further.

## License

MIT. Fixtures in this repository are generated from parametric rooms; no recorded scan of any
real home is or will be committed.
