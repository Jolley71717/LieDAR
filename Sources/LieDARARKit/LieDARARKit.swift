// LieDARARKit — the on-device `CaptureSource` that wraps `ARSession` (phase 1).
//
// Empty in phase 0. When it lands, everything ARKit-flavoured here is guarded with
// `#if canImport(ARKit)` plus a runtime availability check, so the target keeps compiling on
// macOS and on non-LiDAR devices. This file exists so the target has a source file to build.

@_exported import LieDAR
