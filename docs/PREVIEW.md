# The preview and the controls

`LieDARUI` is what the synthetic source looks like on screen: the room the raycaster is drawing,
and the controls to walk around it. It exists so that running a capture app in the Simulator
shows a room instead of a black rectangle.

Import `LieDARUI` rather than `LieDAR`. It re-exports the core, so one import is enough.

## What the preview shows

`RoomPreview` draws one `Raycaster.Frame` from the pose the source is rendering from, in one of
three colourings:

| Mode | What you see |
| --- | --- |
| `.classification` | The class of the triangle each ray hit: orange walls, blue floor, green ceiling, yellow tables, magenta seats, cyan windows, red doors, grey unlabelled. |
| `.depth` | A grey ramp, white at the nearest hit and dark at the furthest. |
| `.confidence` | The three bands ARKit reports, as three flat colours: green high, amber medium, red low. |

A ray that hit nothing is black in every mode.

The colours are `FramePixels`, which is the same table `tools/preview/main.swift` writes
`docs/images/depth.png`, `confidence.png` and `classes.png` with, and the same
`CaptureFormat.classificationColor` the mesh PLY is coloured by. A screenshot of the running app
and the images in this repository are the same mapping, not two that were written twice.

The preview renders at 128 by 96 at 15 Hz by default, which is a quarter of the LiDAR depth map.
The raycaster runs on the CPU, so this is deliberate: the frames a capture writes come from the
source at full resolution, and the preview is only what a person looks at. Both numbers are
settable on `RoomPreviewModel`. A pose that has not moved is not redrawn.

## Putting it on screen

The whole surface, room and controls together:

```swift
import LieDARUI
import SwiftUI

struct CaptureScreen: View {
    let source: SyntheticCaptureSource

    var body: some View {
        SimulatorPreview(source: source)
    }
}
```

`SimulatorPreview` takes the camera off the scripted path while it is on screen and gives it
back when it goes away, so a capture recorded with the controls up follows the person.

If the app switches between sources, ask the source for its view and let `CapturePreview` work
out what to draw:

```swift
import LieDARUI
import SwiftUI

struct AnySourceScreen: View {
    let source: any CaptureSource

    var body: some View {
        CapturePreview(source.makeCaptureView(), mode: .depth)
    }
}
```

That draws the room for a `SyntheticCaptureSource`, wraps the platform view for a source that
has one, and says so plainly for a source that has neither. The app's screen does not change
when the source does.

To draw the room without any controls, hold a `RoomPreviewModel` and pass it to `RoomPreview`.

## Driving the controls

| Input | Keys | Buttons |
| --- | --- | --- |
| Walk forward and back | W and S | Up and down on the left pad |
| Step left and right | A and D | Left and right on the left pad |
| Turn | Q and E, or the left and right arrows | Turn arrows on the right pad |
| Look up and down | R and F, or the up and down arrows | Chevrons on the right pad |

Walking is 1.2 m/s, turning and looking are 90 degrees a second, and looking stops 30 degrees
short of vertical so the camera basis stays defined. Height is pinned to
`CameraPath.chestHeight`, which is the height the scripted tour walks at: nothing a person does
lifts the camera off it, and looking up changes where the camera points and never where it is.
Holding forward and a strafe together covers the same ground as holding one of them.

The keyboard needs iOS 17 or macOS 14, which is where `onKeyPress` starts. On anything older the
buttons are the only way in and they do the same thing.

The controls do not walk through the outline of the room. `Walker` keeps 0.3 m from every wall,
stops a step that would cross one, and pushes out of both walls of a corner. There are two ways
to say where the walls are:

- `WalkBounds.outline(of: spec)` is the room's real outline, including the two inner faces of an
  L-shaped notch. Use it when the `RoomSpec` is to hand.
- `WalkBounds.box(of: model)` is the floor-plane bounding box of a mesh, for a caller who has
  only a `RoomModel`. It is exact for a rectangular room and loose for an L-shaped one, because
  the notch is inside the box. `SimulatorPreview` uses this one, since a source keeps the model
  and not the spec.

Furniture is not in either, so a walker goes through a table. That is on purpose. The preview is
for looking at the room, and a body that snags on a chair is worse than one that does not.

## What it deliberately does not do

- **No Metal and no GPU.** The preview is the same CPU raycaster the capture uses, drawn small.
  The v2 plan reserved the GPU for the preview; it turned out not to be needed, and a CPU
  preview runs on an x86_64 simulator under Rosetta where Metal is unavailable.
- **No lighting, no textures, no perspective tricks.** Flat colour per triangle class, a grey
  ramp, or three confidence bands. It is a picture of what the sensor is being told, not a
  render of a room.
- **No tap-to-place.** `CaptureSource.raycast(screenPoint:)` still returns `nil` for a synthetic
  source. The preview is the only thing that knows the view's size and the mode it drew with, so
  the screen-point-to-world step belongs in this module, and it is not written.
- **No collision with furniture, and no gravity or stairs.** Walls only, at a fixed height.
- **No recording of the walk.** The controls move the camera the source renders from. They do
  not write a `CameraPath`, so a walk cannot be replayed as a fixture.
- **No test of how it looks.** `FramePixels` and `Walker` are pinned to exact values in
  `PreviewPixelsTests` and `WalkerTests`. The views themselves are checked by eye, which is why
  there is nothing between the gestures and the state machine for a test to miss.
