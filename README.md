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

## What it will never do

Make ARKit run on the Simulator; produce ARKit's own types; reproduce sensor noise, drift,
relocalisation, lighting or reflective-surface failures with fidelity; test RoomPlan-based apps
(RoomPlan consumes an `ARSession` directly). It moves the physical-device lane from "the only
test" to "the confirmation", and no further.

## License

MIT. Fixtures in this repository are generated from parametric rooms; no recorded scan of any
real home is or will be committed.
