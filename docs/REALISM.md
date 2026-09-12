# What the synthetic source is, and is not

`SyntheticCaptureSource` produces depth, confidence, colour, poses, tracking states and mesh
anchors that are *shaped* like a LiDAR iPhone's: the same resolutions, the same byte layouts,
the same coordinate frames, the same event sequence. It does not produce data that *looks* like
a phone's under scrutiny. This page says exactly where the line is, so nobody mistakes a green
run on the Simulator for a device test. The physical device lane is the confirmation; this
source moves it from "the only test" to "the confirmation", and no further.

## What it will never do

- **Run ARKit.** ARKit has no input path and its frame and anchor types have no public
  initializers. Your capture code consumes LieDAR's payload types, not `ARFrame` or
  `ARMeshAnchor`. Code that touches ARKit types directly is outside the seam and untested here.
- **Test RoomPlan.** RoomPlan consumes an `ARSession` directly; there is nothing to inject.
- **Reproduce sensor noise.** Depth here is the exact plane distance to a triangle, to `Float32`
  precision. A real depth map has per-pixel noise that grows with range, quantisation, flying
  pixels at depth edges, holes on dark, glossy or absorbent surfaces, and multipath errors in
  corners. None of that is modelled. A filter that behaves on this data may still fail on a phone.
- **Reproduce drift or relocalisation.** Poses are the scripted path plus a fixed sway, exact to
  the millimetre for the whole capture. A real session accumulates drift, jumps on
  relocalisation, and reports `limited(relocalizing)` and `limited(insufficientFeatures)`; the
  script never emits those two states. The one scripted `loopClosure` moves every anchor by a
  fixed translation at one instant — the *shape* of a correction, not a real map optimisation
  (which also rotates, scales locally, and re-triangulates).
- **Reproduce lighting.** The colour image is flat-shaded by class: one colour per surface type,
  no shading, no texture, no exposure change, no motion blur. It exists so the JPEG path runs and
  so a preview shows something; a feature detector or a colour-based classifier learns nothing
  from it.
- **Reproduce reflective, transparent or textureless failures.** Windows are meshed as opaque
  panes and classified `window`; mirrors, glass tables and glossy floors — where LiDAR returns
  nothing or returns the reflected geometry — are simply not in the model.
- **Reproduce reconstruction detail.** Real scene reconstruction produces ~5 cm triangles that
  wobble, smooth over edges, merge nearby surfaces and lag the camera by a second or more. The
  room here is planar quads split into 0.5 m cells, every edge crisp, every surface exactly
  where the spec put it, and an anchor grows the moment a ray hits its triangles.
- **Reproduce real classification behaviour.** ARKit's classifier is a network with its own
  biases (it loves calling low tables floor, confuses doors with walls, and labels almost nothing
  near the floor–wall junction). The degradation model below is a statistical stand-in, not an
  emulation.
- **Reproduce the camera pipeline.** Intrinsics are constants; a real device reports slightly
  different values per frame, per device and per orientation, and the depth map and colour image
  are captured at different instants.

## What the models approximate

| Model | What it stands in for | Parameters (defaults) |
|---|---|---|
| `Raycaster.ConfidenceModel` | ARKit's `confidenceMap` — undocumented, but it falls off with range and with grazing angle | high ≤ 3 m and \|cos θ\| ≥ 0.5; medium ≤ 5 m and \|cos θ\| ≥ 0.2; else low |
| `VirtualCamera` sway | The unsteadiness of a hand-held phone | 2 cm sideways at 0.7 Hz, 1.5 cm vertical at 1.1 Hz |
| Tracking script | A session's first second and its reaction to fast motion | tick 0 `notAvailable`; < 1 s `limited.initializing`; > 1.5 m/s or > 90°/s `limited.excessiveMotion`; otherwise `normal` |
| `AnchorChunker` blocks | ARKit's roughly-metre-sized mesh anchors | 1 m cells, grid shifted half a cell so room surfaces sit mid-block |
| Overlap margin | Duplicate triangles along anchor boundaries that a PLY merge must survive | 0.1 m |
| Discovery / update thresholds | Anchors appearing once enough of a region is seen, and growing afterwards | added at ≥ 4 seen triangles; updated every ≥ 8 more |
| Churn | ARKit occasionally dropping an anchor and re-adding the region under a new identifier | 8 % of updates become `.removed` + `.added` with a new seeded UUID |
| Loop closure | The map shifting when tracking recognises a place | one scripted translation (default 3 cm, 1 cm, −2 cm) applied to every anchor discovered so far |
| `DegradationModel.unlabelledFraction` | The large share of faces ARKit leaves as `none` | 0.30 of faces |
| `DegradationModel.floorTableConfusion` | Low tables read as floor and floor as table | 5 % each way |
| `DegradationModel.labelNoise` | Anchors that are noisier than their neighbours | each anchor draws its own rate in [0, 4 %]; those faces get a uniformly random class |

Every one of these is seeded (`SeededRandom`, SplitMix64) and applied per anchor id, so a seed
reproduces a capture byte for byte and an anchor's degradation does not change between its
`.added` and its `.updated` events.

## What is exact, and therefore testable to the byte

- The raycaster's depth, confidence and triangle ids for a given room, pose and intrinsics
  (`Tests/LieDARTests/Goldens/canonical-depth.bin`).
- A generated fixture for a given seed and tour (`tools/make_fixture.sh` generates twice and
  diffs).
- The tour's poses and tracking states for a given path and rate.
- The anchor set — count, ids, geometry and bounds — for a given room, path and seed.

## Reading a synthetic capture

A synthetic `capture.json` carries `deviceModel: "LieDAR-synthetic"` and
`iosVersion: "synthetic"`. Anything that switches behaviour on the device model will see a
string no phone reports; anything that parses `iosVersion` as a number will fail. Both are
deliberate: a synthetic capture must never pass for a recorded one, and
`tools/fixture_audit.sh` refuses real device strings under `Fixtures/`.
