# Release notes

## 0.2.0 (unreleased)

### Breaking

**The package is two products now, and the synthetic room has moved out of `LieDAR` into
`LieDARSynthetic`.** If you use `RoomSpec`, `RoomModel`, `Raycaster`, `CameraIntrinsics`,
`VirtualCamera`, `CameraPath`, `AnchorChunker`, `DegradationModel`, `SeededRandom` or
`SyntheticCaptureSource`, you have to add a product and change an import.

In your `Package.swift`, change this:

```swift
// docs-check: skip
.package(url: "https://github.com/Jolley71717/LieDAR", exact: "0.1.1"),
// ...
.product(name: "LieDAR", package: "LieDAR")
```

to this:

```swift
// docs-check: skip
.package(url: "https://github.com/Jolley71717/LieDAR", exact: "0.2.0"),
// ...
.product(name: "LieDARSynthetic", package: "LieDAR")
```

Then change `import LieDAR` to `import LieDARSynthetic` in the files that name any of the types
above. `LieDARSynthetic` re-exports `LieDAR`, so one import still covers both and nothing else in
those files has to change. No type was renamed and no signature changed.

If you only record and replay real captures, keep `.product(name: "LieDAR", ...)` and change
nothing at all. That is the point of the split: you now stop at replay in the link map as well as
in the API.

`LieDARUI` and `LieDARARKit` are unchanged as products. `LieDARUI` now sits on `LieDARSynthetic`
and re-exports it, because the preview draws a `Raycaster.Frame`; `LieDARARKit` sits on `LieDAR`
alone, because recording a real sensor needs nothing synthetic.

**Why.** Meshwise adopted the package and its release binary grew by 306,432 bytes. The link map
attributed 309,964 of those to LieDAR and named `Raycaster.render`,
`SyntheticCaptureSource.produce`, `RoomModel.parametric` and `AnchorChunker.observe` among the
symbols it kept. The debug gate was
intact, so a release build could not reach any of it; a Swift package builds as one object file, so
it linked anyway. README.md already promised "You can stop at replay", and that promise was true of
the API and false of the binary. Splitting the target is what makes it true.

### Added

- `tools/layering_check.sh` holds the boundary. It reads the declared graph from
  `swift package dump-package` and fails if the `LieDAR` target gains a dependency on
  `LieDARSynthetic`, if a core file imports `LieDARSynthetic`, `LieDARUI` or `LieDARARKit`, or if
  a type declared in the synthetic target is named anywhere in core code.
- `simd_float4x4.forwardAngleDegrees(to:)` in the core. `FrameGate` needs the angle between two
  poses to decide whether the camera turned far enough to write a frame, and the gate applies to a
  real ARKit capture, so the maths could not stay with the virtual camera.
  `VirtualCamera.angleDegrees(_:_:)` still exists and calls it.

## 0.1.1

### Breaking

**The `LieDARARKit` and `LieDARUI` library products are gone.** In 0.1.0 both were declared in
`Package.swift` while their sources held one comment and `@_exported import LieDAR`. A package that
added the `LieDARARKit` product expecting an ARKit-backed capture source got a re-export of the core
module, with no warning from SwiftPM and nothing to import. The targets are still there and still
build, so the code can be written into them, and the products come back when there is something
behind them. `tools/products_check.sh` fails the build if an empty product is declared again.

If you depended on either product, depend on `LieDAR` instead. Neither one ever carried code, so
nothing else has to change.

### Fixed

- `RoomSpec.random(seed:)` no longer traps. A window's offset was drawn from a range that inverted
  on a wall between 1.6 and 1.8 m, while the wall filter admitted 1.6 m, so the generator crashed on
  roughly one seed in fifty (36, 254, 273, 280, 402, 423 and 447 among the first 500). Only an
  L-shaped room's short inner faces are ever that short. The minimum wall length is now derived
  from the opening widths, so the filter and the draw cannot disagree. The seed sweep in
  `RoomModelTests` went from 12 seeds to 500. Generated rooms for every seed that did not crash are
  unchanged, and `Fixtures/synthetic-1` is byte-identical.
- `CaptureReader` throws instead of trapping on three shapes of malformed input: a negative
  `depthResolution`, which made a negative byte count and trapped in `Data.prefix`; a `vertexCount`
  or `depthResolution` large enough to overflow the multiplication that turns it into bytes; and a
  file name that resolved, through a symlink, to somewhere outside the capture folder. Counts that
  are merely absurd still report `shortFile` with the expected and actual byte counts.
- `CaptureReader.anchor(_:)` throws `badAnchors` for an identifier that is not a UUID. It used to
  mint a fresh `UUID()`, so two reads of one folder disagreed about an anchor's identity.
- Every file a capture is read from must be a regular file inside the capture folder. A symlink or
  a directory throws `unsafeFileName` for an anchor file, and reads as absent for the manifest,
  a frame's JSON, `anchors.json` and a colour image. A symlink is refused even when its target is
  inside the folder: nothing that writes a capture emits one, and a link can be re-pointed after it
  has been checked. `colorJPEG(_:)` was the sharpest of these, because it handed the bytes it read
  straight back to the caller, so a symlink planted in a zip leaked an arbitrary readable file
  into whatever displayed or re-exported the image.

### Tests and tooling

- `CaptureReaderErrorTests` covers all fifteen reader error paths, which had no test at all.
- `JPEGColorTests` puts four known colours through the 420f and BGRA paths and reads them back out
  of the JPEG. The only colour test before this fed uniform grey, where every coefficient in the
  YCbCr matrix is interchangeable.
- `RaycasterTests` names a pixel inside the 3.5 to 5 m confidence band, which the byte-exact golden
  cannot see because the canonical frame holds no such pixel.
- `tools/test.sh` refuses to run with `LIEDAR_GOLDEN_OUT` set, and asserts which tests skipped
  rather than counting them. With that variable exported the run used to report 113 tests, 0
  failures and exit 0 while both golden files were rewritten and neither was compared.
- `tools/mutation_check.sh` gained the two cases that prove the new colour and confidence
  assertions bite.
- `tools/products_check.sh` is new.
