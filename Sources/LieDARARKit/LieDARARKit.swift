// LieDARARKit: the on-device `CaptureSource` that wraps `ARSession`.
//
// `ARKitCaptureSource` is the whole module. Everything ARKit-flavoured is guarded with
// `#if canImport(ARKit) && os(iOS) && !targetEnvironment(macCatalyst)`, so the target keeps
// compiling on macOS, where it builds to this re-export and nothing else, and on non-LiDAR
// devices, where the source compiles and reports itself unavailable.
//
// The re-export is here so `import LieDARARKit` gives a consumer `CaptureSource`,
// `FramePayload` and the rest of the seam without a second import.

@_exported import LieDAR
