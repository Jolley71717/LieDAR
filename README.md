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
