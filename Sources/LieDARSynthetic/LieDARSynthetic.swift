// LieDARSynthetic: a sensor that is not there.
//
// The room, the renderer, the camera that walks it and the anchor stream it produces:
// `RoomSpec`, `RoomModel`, `Raycaster`, `CameraIntrinsics`, `VirtualCamera`, `CameraPath`,
// `AnchorChunker`, `DegradationModel`, `SeededRandom` and `SyntheticCaptureSource`.
//
// Depend on this when you want a fake sensor. If you only record and replay real captures,
// depend on `LieDAR` alone and none of this is linked into your binary.
//
// This module imports `LieDAR` and re-exports it, so `import LieDARSynthetic` is the only
// import a synthetic consumer needs. Nothing here imports ARKit or SwiftUI.

@_exported import LieDAR
