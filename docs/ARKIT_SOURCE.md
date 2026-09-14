# ARKitCaptureSource: what it is, and what only a phone can prove

`ARKitCaptureSource` is the `CaptureSource` backed by real hardware. It owns an `ARSession` and
its delegate, and it is the only type in this package that imports ARKit, AVFoundation, CoreVideo
or RealityKit. The synthetic and replay sources are peers of it; nothing downstream branches on
which source it has.

It lives in the `LieDARARKit` product. `import LieDARARKit` also re-exports `LieDAR`, so one
import gives both the source and the seam it satisfies.

## Using it

```swift
// docs-check: skip
import LieDARARKit

let source = ARKitCaptureSource()
guard source.isAvailable else { /* fall back to a synthetic or replayed source */ return }
try source.start()

Task {
    for await sample in source.samples {
        guard gate.admit(sample) else { continue }
        guard let payload = sample.materialize() else { continue }
        recorder.write(payload)
    }
}
Task {
    for await event in source.anchorEvents { tally.apply(event) }
}
Task {
    for await event in source.sessionEvents { banner.show(event) }
}

// At stop time, in this order.
let mesh = source.meshSnapshot()
let worldMap = await source.worldMapData()
source.stop()
```

Consuming a source through the protocol alone, which is what a capture session should do, needs
no ARKit at all:

```swift
import Foundation
import LieDAR

func drain(_ source: any CaptureSource) async -> (samples: Int, mesh: Int, worldMap: Int) {
    var samples = 0
    for await _ in source.samples { samples += 1 }
    for await _ in source.sessionEvents { }
    let worldMap = await source.worldMapData()?.count ?? 0
    return (samples, source.meshSnapshot().count, worldMap)
}

let counts = await drain(NullCaptureSource())
print("\(counts.samples) samples, \(counts.mesh) anchors, \(counts.worldMap) bytes of world map")
```

## Three decisions worth knowing about

**`isAvailable` is asked of the source, never of the framework (RT-1).**
`ARWorldTrackingConfiguration.supportsSceneReconstruction` is a static query that is false on
every Simulator whatever the source could actually do. A consumer that calls it directly can
never enable Start under a synthetic or replayed capture, which is the whole reason this package
exists. `ARKitCaptureSource.isAvailable` is the only place in the package that runs that query,
and `cameraAuthorized` is the only place that asks `AVCaptureDevice`.

**The type is thin, because most of it could not be tested otherwise (RT-2).** Three pieces that
would naturally live inside an ARKit wrapper are in the `LieDAR` core module instead, where a
test on a Mac can reach them:

| Piece | What it holds | Tested by |
|---|---|---|
| `CaptureStreams` | opening, closing and buffering the three streams | `CaptureStreamsTests` |
| `AnchorTable` | which anchors are held, after adds, updates and removals | `AnchorTableTests` |
| `BufferCopy` | row padding, vertex stride, index width, class padding | `BufferCopyTests` |

`meshSnapshot()` reads the table rather than `session.currentFrame?.anchors`, because
`currentFrame` is nil once the session is paused and a consumer asks for the mesh at stop time.

**`materialize()` copies from a frame that is still alive (RT-3).** `CVPixelBuffer` is not
`Sendable` and neither is `ARFrame`, so `CameraSample` carries a closure rather than a payload:
the pose, the timestamp and the tracking state are cheap and are yielded for every frame, and the
copy happens only for the frames a consumer's gate accepts. The closure retains its `ARFrame`,
which is what stops ARKit recycling the buffers underneath the copy. ARKit answers a retained
frame by not delivering the next one, so the sample stream buffers exactly one frame
(`Configuration.sampleBufferSize`), which bounds how many are alive at once. `RetainedFrame` is
the one `@unchecked Sendable` in the package and its doc comment states that invariant.

## The platform guard is not `canImport(ARKit)`

The macOS SDK ships an `ARKit.framework`, so `canImport(ARKit)` is true on a Mac. Measured on
Xcode 26.5 with the macOS 26.5 SDK: with the file guarded on `canImport(ARKit)` alone,
`swift build` compiled it for macOS and reported `cannot find type 'ARSession' in scope` eleven
times. The guard is `canImport(ARKit) && os(iOS) && !targetEnvironment(macCatalyst)`, because
`os(iOS)` is what names the platform the session API is actually on. It is deliberately not
`targetEnvironment(simulator)`: this source belongs in a Simulator build, where it compiles,
reports itself unavailable and lets a synthetic source take over.

## What a Mac and a Simulator can prove, and do

`ARKitCaptureSourceTests` runs on the Simulator leg of `tools/test.sh` and compiles away on
macOS. It asserts:

- `isAvailable` equals the scene-reconstruction query, for a classified mesh and a plain one.
- On a Simulator, `isAvailable` is false and `start()` throws `CaptureSourceError.unavailable`.
- `cameraAuthorized` equals the video authorization status.
- The streams are finished before `start()` and after `stop()`, so a `for await` loop ends.
- A source that never ran holds no anchors and archives no world map.
- `raycast(screenPoint:)` is nil before there is a capture view.
- `makeCaptureView()` returns the same `ARView` twice, and does not configure the session itself.
- Every `ARCamera.TrackingState` maps to the string the capture format stores.
- Depth, confidence and both colour layouts are copied correctly out of `CVPixelBuffer`s the test
  creates, including the interleaved Cb,Cr plane, and an unknown colour format is refused by name.

`CaptureStreamsTests`, `AnchorTableTests` and `BufferCopyTests` run on both legs.

## What only a device can prove

ARKit delivers no frames on a Simulator, and `ARFrame`, `ARMeshAnchor` and `ARMeshGeometry` have
no public initialisers, so nothing that consumes them can be exercised by a unit test on any
machine. A test that asserted otherwise would be asserting nothing. This is that list instead.

Run these on an iPhone Pro or iPad Pro with a LiDAR sensor, camera allowed, in a room with
furniture and at least one window.

| # | What is unproven | What to run | What you should see |
|---|---|---|---|
| 1 | `isAvailable` is true on real hardware | Open the capture screen on the device | Start is enabled; on a non-LiDAR iPhone of the same iOS version it is not |
| 2 | `start()` runs a session that delivers | Start a capture and hold still for five seconds | Frames arrive at about 60 Hz; the sample count climbs |
| 3 | `materialize()` reads a live frame | Capture for ten seconds, then open the folder | `frames/NNNNNN.depth` is 256 x 192 Float32, `.conf` is 256 x 192 bytes, `.jpg` looks like the room |
| 4 | Depth is metres from the camera plane | Stand two metres from a flat wall, face it, capture one frame | The centre depth pixel reads about 2.0 |
| 5 | The colour plane layout is what ARKit hands over | Point at something strongly coloured, capture, open the JPEG | Colours are right; a red wall is red, not blue or green |
| 6 | Anchor events arrive and the geometry copies | Sweep a whole room | Anchor count climbs past 20; `mesh/*.vertices` are non-empty; `mesh.ply` opens in a mesh viewer and looks like the room |
| 7 | Classification is real | Sweep floor, wall, ceiling, a table and a window | `mesh.ply` shows the class colours in the right places; some faces are unclassified, which is expected |
| 8 | Index width is handled on this device | The same capture | Faces are triangles, not confetti. A device that hands over two-byte indices read as four produces visible garbage |
| 9 | Anchors are removed and re-added | Sweep a region, walk away, come back | The anchor count falls and rises; `meshSnapshot()` at stop matches `anchors.json` |
| 10 | The snapshot survives the pause | Stop the capture, then write the mesh | `mesh/` is written; it is not empty, which is what reading `currentFrame` after `pause()` would give |
| 11 | The world map archives | Capture for thirty seconds, then stop | `worldmap.bin` exists and is tens of kilobytes or more |
| 12 | The capture view shows the camera | Start a capture | The camera feed is on screen with the reconstructed mesh drawn over it |
| 13 | `raycast(screenPoint:)` lands on a surface | Tap a wall, a floor and a table top | The marker sits on the surface, not in front of it or behind it |
| 14 | Interruption and failure reach `sessionEvents` | Start a capture, then take a phone call, then return | An `.interrupted` then an `.interruptionEnded` event; the capture keeps its frames |
| 15 | Tracking states other than normal arrive | Start a capture and wave the phone hard; cover the camera | `.limitedExcessiveMotion` and `.limitedInsufficientFeatures` appear; the gate stops writing frames |
| 16 | The sample buffer keeps ARKit delivering | Capture for a minute with the writer under load | Frames keep arriving. A stall means too many `ARFrame`s are being held |
| 17 | The per-update geometry copy is affordable | Sweep a large room for two minutes and watch the frame rate | The preview stays smooth. Every `.updated` anchor is copied off its Metal buffers in the delegate callback, which is the price of a payload that is safe to send anywhere, and it is the first thing to measure if a device drops frames |

Items 3 to 11 are all readable afterwards from the capture folder, so one recorded capture copied
off the device answers most of this list without a debugger.

## What this source does not do

No RoomPlan, no object capture, no image anchors, no collaborative sessions, no geo tracking. It
produces the capture format in `docs/CAPTURE_FORMAT.md` and nothing else. `docs/REALISM.md`
covers what the synthetic source cannot reproduce of what this one records.
