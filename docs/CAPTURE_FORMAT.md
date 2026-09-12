# LieDAR capture format

_Version 2. This document is the contract; `Sources/LieDAR/Format/CaptureFormat.swift` is its
executable half and `Tests/LieDARTests/FormatGoldenTests.swift` pins every byte below._

A capture is one folder. Everything in it is readable on a Mac (Python/numpy, C++, Swift) with
no ARKit and no LieDAR: binary files are raw little-endian arrays with **no header**, their shapes
come from the JSON files beside them, and every distance is in metres. The world coordinate frame
is ARKit's: right-handed, +Y up (gravity-aligned), origin wherever tracking started. The format
was extracted from the first consumer's raw-capture writer so that its existing captures are
version 1/2 files of this spec unchanged; the package's `CaptureRecorder` writes it and
`CaptureReader` reads it.

## Directory layout

```
<capture>/
  capture.json                 manifest — written LAST; its presence means the capture finished
  mesh.ply                     merged mesh of every anchor in world space (ASCII PLY, derived)
  frames/
    000000.depth               Float32 LE, tightly packed, depthResolution.height × width
    000000.conf                UInt8, same shape                           (optional per frame)
    000000.jpg                 colour, JPEG, ≤ 640 px long edge              (optional per frame)
    000000.json                FrameMeta — written LAST; its presence means the frame is complete
    000001.depth … 
  mesh/
    anchors.json               [MeshAnchorMeta], one entry per anchor, in write order
    <UUID>.vertices            Float32 LE, xyz interleaved, vertexCount × 3, anchor-local
    <UUID>.faces               UInt32 LE, faceCount × 3, indices into .vertices
    <UUID>.classes             UInt8, one per FACE, faceCount
  worldmap.bin                 ARKit world map (NSKeyedArchiver) — device-only, OPTIONAL, never
                               written by this package, never committed as a fixture
```

Frame base names are the frame index as **at least six decimal digits, zero padded**
(`000000`, `000123`, `1234567`). Indices are the writer's frame numbers; a gated writer that
drops frames leaves no gap in the numbering because it only advances the index on acceptance,
but a reader must not assume contiguity — list the directory.

Anchor base names are the anchor's `UUID.uuidString`: upper-case hexadecimal, hyphenated,
36 characters (`0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9`).

`frames/` and `mesh/` are created at the start of a capture and may be empty.

## Completeness rules

| Marker | Meaning |
|---|---|
| `frames/NNNNNN.json` exists | frame NNNNNN is complete: its `.depth` (and `.conf`, `.jpg` if any) were fully written before it. A `.depth` with no `.json` is an interrupted write; ignore it. |
| `capture.json` exists | the capture finished: every frame write drained, mesh and manifest written. |

Every file is written atomically (write to a temporary, rename), so a file is either absent or
whole. The frame count a consumer should trust is the number of `frames/*.json` files, not
`capture.json`'s `frameCount` (see below).

## Binary files

All multi-byte values are little-endian. There is no header, padding, alignment or trailer.

### `frames/NNNNNN.depth`

| Property | Value |
|---|---|
| element | `Float32` (IEEE 754 binary32) |
| shape | `depthResolution.height` rows × `depthResolution.width` columns, row-major |
| row stride | exactly `width × 4` bytes — **no** `bytesPerRow` padding |
| file size | `width × height × 4` bytes (256 × 192 → 196 608 bytes) |
| meaning | distance from the camera plane in metres (not ray length); 0 or NaN where unknown |
| origin | pixel (0, 0) is top-left in the sensor's landscape orientation; u right, v down |

### `frames/NNNNNN.conf`

| Property | Value |
|---|---|
| element | `UInt8` |
| shape | same as `.depth` |
| file size | `width × height` bytes |
| values | `0` low, `1` medium, `2` high |
| presence | absent when the source produced no confidence map |

### `frames/NNNNNN.jpg`

| Property | Value |
|---|---|
| encoding | JPEG (ImageIO `public.jpeg`), quality 0.6 by default |
| size | source image scaled so the long edge is ≤ 640 px, aspect preserved, rounded to nearest pixel; never upscaled (1920 × 1440 → 640 × 480; 960 × 720 → 640 × 480) |
| orientation | same as the sensor image (landscape, matches `intrinsics`), only scaled |
| presence | absent when the source had no colour or the recorder's `saveColorImages` is off |

The JPEG is a derived preview; its bytes are encoder-dependent and not part of the golden
contract (a reader may assert its dimensions and that it decodes).

### `mesh/<UUID>.vertices`

| Property | Value |
|---|---|
| element | `Float32` × 3 per vertex, `x y z` interleaved |
| count | `vertexCount` vertices → `vertexCount × 12` bytes |
| frame | **anchor-local**: `world = transform × [x y z 1]` with the anchor's `transform` from `anchors.json` |

### `mesh/<UUID>.faces`

| Property | Value |
|---|---|
| element | `UInt32` × 3 per triangle, counter-clockwise as the source produced them |
| count | `faceCount` triangles → `faceCount × 12` bytes |
| range | every index `< vertexCount` of the same anchor |

### `mesh/<UUID>.classes`

| Property | Value |
|---|---|
| element | `UInt8`, **one per face** (not per vertex) |
| count | `faceCount` bytes |
| values | `0` none, `1` wall, `2` floor, `3` ceiling, `4` table, `5` seat, `6` window, `7` door (ARKit `ARMeshClassification.rawValue`; `MeshClassification` in the package). Values above 7 are treated as 7 by the PLY merge and as unknown by readers. |

## JSON files

All JSON is written with `JSONEncoder` using **sorted keys, pretty printing (two-space
indent, `"key" : value` with a space before the colon), ISO 8601 dates** (`2026-01-02T03:04:05Z`,
UTC, whole seconds). Numbers are JSON numbers: integral floats print without a decimal point
(`1`, `0`, `100`), others in shortest round-trip form (`0.99999994`, `-1.4551915e-11`). A reader
must accept any valid JSON number for a float field.

### `capture.json` — `CaptureManifest`

| Field | Type | Meaning |
|---|---|---|
| `formatVersion` | Int | This spec's version. `2` for files this package writes. **Absent means 1.** |
| `deviceModel` | String | Hardware identifier of the producer (`"iPhone15,2"`), or a synthetic marker for generated captures (`"LieDAR-synthetic"`). Public fixtures must never carry a real model string. |
| `iosVersion` | String | Producer OS version (`"26.0.1"`) or a synthetic marker. The key name is historical and kept for compatibility. |
| `startedAt` | Date (ISO 8601) | Wall-clock start. |
| `endedAt` | Date (ISO 8601) | Wall-clock end. `startedAt < endedAt`. |
| `frameCount` | Int | Frames ACCEPTED for writing. A frame whose write failed is missing on disk, so `frames/*.json` count ≤ `frameCount`; the disk is the truth. |
| `meshAnchorCount` | Int | Anchors in `mesh/anchors.json`. |
| `totalVertices` | Int | Sum of `vertexCount` over the anchors; equals `mesh.ply`'s `element vertex`. |
| `totalFaces` | Int | Sum of `faceCount` over the anchors; equals `mesh.ply`'s `element face`. |
| `worldMapSaved` | Bool | Whether `worldmap.bin` exists. Always `false` from this package. |
| `notes` | String | Free text from the user; `""` when none. Optional on read (absent → `""`). |
| `normalTrackingFrameCount` | Int | Frames the session observed with `normal` tracking while running, written or not. **Version 2; absent in version 1 → 0.** |
| `totalTrackingFrameCount` | Int | Frames the session observed while running, any tracking state. **Version 2; absent in version 1 → 0.** |

Canonical example (exact bytes the golden test asserts):

```json
{
  "deviceModel" : "LieDAR-test",
  "endedAt" : "2026-01-02T03:05:05Z",
  "formatVersion" : 2,
  "frameCount" : 2,
  "iosVersion" : "0",
  "meshAnchorCount" : 2,
  "normalTrackingFrameCount" : 7,
  "notes" : "golden",
  "startedAt" : "2026-01-02T03:04:05Z",
  "totalFaces" : 3,
  "totalTrackingFrameCount" : 9,
  "totalVertices" : 7,
  "worldMapSaved" : false
}
```

### `frames/NNNNNN.json` — `FrameMeta`

| Field | Type | Meaning |
|---|---|---|
| `index` | Int | Frame index; equals the file's base name as a number. |
| `timestamp` | Double | Seconds on a monotonic clock (ARKit's `ARFrame.timestamp`, since boot). Only differences between frames are meaningful. |
| `cameraTransform` | [Float] × 16 | Camera-to-world, **column-major**: element (row r, col c) is at index `c*4 + r`; translation is elements 12, 13, 14; element 15 is 1. Camera looks down its local −Z, +X right, +Y up. |
| `intrinsics` | [Float] × 9 | Pinhole matrix for `imageResolution`, column-major: `[fx 0 0  0 fy 0  cx cy 1]`. Pixel origin top-left, u right, v down, landscape. Scale by `depthResolution / imageResolution` to use with the depth map (same field of view). |
| `imageResolution` | `{ width: Int, height: Int }` | Full colour image size the intrinsics refer to (e.g. 1920 × 1440), regardless of the JPEG's scaled size. |
| `depthResolution` | `{ width: Int, height: Int }` | Depth and confidence map size (e.g. 256 × 192). |
| `trackingState` | String | `"normal"`, `"notAvailable"`, `"limited.initializing"`, `"limited.excessiveMotion"`, `"limited.insufficientFeatures"`, `"limited.relocalizing"`, `"limited.unknown"`, `"failed"`, `"interrupted"`, `"unknown"`. A gated writer writes only `"normal"` frames; readers must accept any string. |

Unprojecting a depth pixel: `z = depth[v][u]`, `x = (u − cx′) z / fx′`, `y = (v − cy′) z / fy′`
with the primed intrinsics scaled to `depthResolution`; camera point = `(x, −y, −z)`; world =
`cameraTransform × (x, −y, −z, 1)`.

Canonical example (exact bytes the golden test asserts; identity rotation, translation
(1.5, 2, −3.25), fx = fy = 100, cx = 64, cy = 48):

```json
{
  "cameraTransform" : [
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    1.5,
    2,
    -3.25,
    1
  ],
  "depthResolution" : {
    "height" : 3,
    "width" : 4
  },
  "imageResolution" : {
    "height" : 96,
    "width" : 128
  },
  "index" : 1,
  "intrinsics" : [
    100,
    0,
    0,
    0,
    100,
    0,
    64,
    48,
    1
  ],
  "timestamp" : 13.5,
  "trackingState" : "normal"
}
```

### `mesh/anchors.json` — `[MeshAnchorMeta]`

A JSON array, one object per anchor, in the order the anchors were written. `[]` when no mesh was
captured (the file is still written at finish; a reader treats a missing file as `[]` too).

| Field | Type | Meaning |
|---|---|---|
| `identifier` | String | The anchor's UUID string (upper-case, hyphenated). Also the base name of its three files. |
| `transform` | [Float] × 16 | Anchor-to-world, column-major as `cameraTransform`. |
| `vertexCount` | Int | Vertices in `.vertices`; `≥ 0`. |
| `faceCount` | Int | Triangles in `.faces` and bytes in `.classes`; `≥ 0`. |
| `verticesFile` | String | `"<identifier>.vertices"` — a plain file name inside `mesh/`, never a path. Readers reject names containing `/`, `\`, or equal to `.`/`..`. |
| `facesFile` | String | `"<identifier>.faces"`. |
| `classesFile` | String | `"<identifier>.classes"`. |

## `mesh.ply`

Derived, viewer-friendly copy of the whole mesh; the per-anchor files are canonical. ASCII PLY,
UTF-8, `\n` line endings, one trailing newline. Header, exactly:

```
ply
format ascii 1.0
comment <free text — writer identification, NOT part of the contract>
comment <free text>
element vertex <N>
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face <F>
property list uchar int vertex_indices
end_header
```

followed by `N` vertex lines `x y z r g b` and `F` face lines `3 i j k`.

- Vertices are in **world space** (each anchor's vertices transformed by its `transform`) and
  concatenated in anchor order; an anchor's face indices are offset by the number of vertices
  written before it. Overlapping anchors therefore produce duplicate geometry; that is expected.
- Floats are Swift's shortest round-trip decimal (`10.0`, `0.5`, `-2.0933394`, `1e-05`).
- The colour encodes the vertex's class — the **majority class of the faces touching the
  vertex, ties to the lowest class value** — through this exact table, so a reader can map
  colour back to class:

| class | value | r g b |
|---|---|---|
| none | 0 | 128 128 128 |
| wall | 1 | 230 138 46 |
| floor | 2 | 46 138 230 |
| ceiling | 3 | 46 200 120 |
| table | 4 | 200 200 60 |
| seat | 5 | 200 60 200 |
| window | 6 | 60 220 220 |
| door | 7 | 220 60 60 |

Readers must ignore `comment` lines; the two the package writes name LieDAR.

Canonical example (golden test): a quad at x + 10 with faces wall then floor, and a ceiling
triangle at y + 2.5:

```
10.0 0.0 0.0 230 138 46
11.0 0.0 0.0 230 138 46
11.0 1.0 0.0 230 138 46
10.0 1.0 0.0 46 138 230
0.0 2.5 0.0 46 200 120
2.0 2.5 0.0 46 200 120
0.0 2.5 2.0 46 200 120
3 0 1 2
3 0 2 3
3 4 5 6
```

## Writer behaviour (`CaptureRecorder`)

- One private serial queue does all file I/O. `write(frame)` is non-blocking and returns whether
  the frame was accepted. With `maxPendingFrames` (default 6) frames still queued, a further
  frame is **dropped** — `write` returns `false` and `droppedFrameCount` increments — rather
  than buffered. A slow disk costs frames, never memory or latency.
- Per frame, in order: `.depth`, `.conf` (if present), `.jpg` (if present and enabled), then
  `.json`. Each atomically.
- `writeMeshSnapshot(anchors)` writes each anchor's three files, then `anchors.json`, then
  `mesh.ply`. An anchor whose byte lengths disagree with its counts aborts the snapshot before
  anything is written.
- `finish(manifest)` runs behind every queued write and then writes `capture.json`. After it,
  every `write` is dropped; a second `finish` throws.
- A frame write that fails on the queue is counted in `frameWriteFailure` (first message + count)
  and leaves no `.json`, so the frame is absent by the completeness rule.

## Versions

| `formatVersion` | Change |
|---|---|
| 1 | Original: everything above except the two tracking-count manifest fields. `formatVersion` may be present as `1` or absent. |
| 2 | Adds `normalTrackingFrameCount` and `totalTrackingFrameCount` to `capture.json`. Byte-compatible with 1 otherwise. |

Readers accept 1…2 and reject anything higher (`CaptureReader.ReadError.unsupportedFormatVersion`).
A future version that changes any binary layout or removes a field must bump the number; adding
an optional JSON field with a documented default does not.

## Privacy note for fixtures

A committed fixture must be generated, never recorded in a real place: no `.jpg`, no
`worldmap.bin`, no real `deviceModel`/`iosVersion` strings, no file over 2 MB
(`tools/fixture_audit.sh` enforces this).
