# Release notes

## 0.1.1 (unreleased)

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
