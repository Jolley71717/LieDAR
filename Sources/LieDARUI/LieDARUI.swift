// LieDARUI: what the synthetic camera sees, and the controls to walk it.
//
// `RoomPreview` draws a `Raycaster.Frame` three ways, using the same colour table as
// `tools/preview/main.swift`, so a screenshot of a running app matches `docs/images/`.
// `SimulatorControls` walks a person around the room and hands the pose back to the source.
//
// SwiftUI and Combine only. This module never imports ARKit, and the `LieDAR` core never
// imports either one.
//
// The preview draws a `Raycaster.Frame` and the controls walk a `SyntheticCaptureSource`, so
// this module sits on `LieDARSynthetic` and re-exports it along with the core. `import LieDARUI`
// is the only import a preview needs.

@_exported import LieDAR
@_exported import LieDARSynthetic
