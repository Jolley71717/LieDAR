# LieDAR

**It lies to your app about LiDAR.** Run iOS LiDAR and ARKit apps on the Simulator: replay recorded
captures or scan a synthetic room — depth, confidence, mesh anchors and camera poses, no hardware
required.

ARKit cannot be fed: it has no input path and its frame and anchor types have no public
initializers, and on the Simulator it does not run at all. LieDAR replaces ARKit *as your app sees
it* — a small `CaptureSource` façade with ARKit behind it on a device and a synthetic room, a
virtual camera and a deterministic CPU raycaster behind it on the Simulator. The cost is the one
thing adopters accept: capture code consumes LieDAR's `Sendable` payload types, not ARKit's.

Status: **pre-release, under construction.** See `docs/PLAN.md` for the design, the red-team
findings that shaped it, and the phase acceptance criteria. Nothing here is usable yet.

## The synthetic source (phase 2)

`SyntheticCaptureSource(seed:)` is a `CaptureSource` with no hardware behind it:

- `RoomModel` — a parametric room (width, depth, ceiling, doors and windows, a bulkhead,
  furniture, an optional L-shape) meshed into classified triangles, deterministic by seed; or
  any ASCII OBJ.
- `Raycaster` — CPU, no Metal: depth, confidence and a triangle id per pixel, bit-identical on
  every arm64 machine, about 12 ms per 256 × 192 frame in a release build on an M-series Mac.
- `VirtualCamera` — a scripted path at chest height with a little sway, iPhone Pro intrinsics,
  and a tracking script (`notAvailable` → `limited.initializing` → `normal`, with
  `limited.excessiveMotion` when the script moves too fast).
- `AnchorChunker` — metre-sized anchors that appear as the camera sees them, grow, overlap,
  are occasionally dropped and re-added under a new id, and all shift at once on a scripted
  loop closure.
- `DegradationModel` — 30 % of faces unlabelled, floor↔table confusion, per-anchor noise.

`ScriptedCapture.record(from:to:)` runs any source through the PLAN's write gate (`normal`
tracking and ≥ 0.15 m / 10° / 0.5 s since the last written frame) into `CaptureRecorder`, so
**`frameCount` is not the number of frames fed**: a 3-second tour at 30 Hz feeds 91 samples and
writes 13 frames. `tools/make_fixture.sh <seed>` writes `Fixtures/synthetic-<seed>/` the same way
and proves two runs are byte-identical; `tools/mutation_check.sh` proves the realism tests fail
when their code is removed. What the source cannot reproduce — sensor noise, drift,
relocalisation, lighting, reflective failures, RoomPlan — is spelled out in `docs/REALISM.md`.

## What it will never do

Make ARKit run on the Simulator; produce ARKit's own types; reproduce sensor noise, drift,
relocalisation, lighting or reflective-surface failures with fidelity; test RoomPlan-based apps
(RoomPlan consumes an `ARSession` directly). It moves the physical-device lane from "the only
test" to "the confirmation", and no further.

## License

MIT. Fixtures in this repository are generated from parametric rooms; no recorded scan of any
real home is or will be committed.
