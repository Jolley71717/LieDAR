# The example app and the journeys

`Example/` is a small iOS capture app built on LieDAR, and it is the black box the end-to-end
tests drive. It exists for two reasons. It is the package's worked example, the code an adopter
copies. It is also the only place where the whole chain runs the way a user meets it, from tapping
Start to reading a saved capture back off disk.

There is no ARKit in it, no device, and no recorded data. Every capture it makes comes from a
parametric room, a scripted camera and a CPU raycaster.

## What the app does

Three screens, push navigation, no modals anywhere.

- **Home.** The captures that have been saved, newest first. Each row shows its size on disk,
  how many frames it holds and how many mesh anchors. A counter above the list says how many
  there are; a button starts a new capture.
- **Capture.** Start, a live HUD, Stop & Save. The HUD shows **frames written**, **anchors**
  currently held, and **elapsed** seconds of captured time. Frames written is not the number of
  samples fed, because the write gate rejects most of them. Stop & Save writes the mesh and the
  manifest, then either publishes the capture to the list or deletes the folder if nothing was
  captured.
- **Detail.** The folder read back through the package's own `CaptureReader`. How many frame
  files, how many mesh files, bytes in each, the frame count `capture.json` claims, the anchor
  count `anchors.json` claims, and how many faces came back unlabelled.

The capture loop lives in `Example/ExampleApp/CaptureEngine.swift` and is the part worth copying.
It pulls samples and anchor events from a `CaptureSource`, applies a `FrameGate`, materializes
only the frames the gate admits, hands them to a `CaptureRecorder`, and asks the source for its
mesh at stop time. Nothing in it knows the source is synthetic; `Scenario.makeSource()` is the
single place a source is chosen, and swapping in an ARKit source on a device changes that
function and nothing else.

## Scenarios

The app runs one of three scenarios, chosen with a launch argument. A person who just opens the
app gets `normal`. There is no "am I under test" branch anywhere in the app.

| Launch argument | What the source does |
|---|---|
| `-LieDARScenario normal` | A clean room: every face labelled, no loop closure. The default. |
| `-LieDARScenario zeroFrames` | Produces nothing at all. The streams finish on `start()`. |
| `-LieDARScenario degraded` | The realism defaults: ~30 % of faces unlabelled, floor/table confusion, per-anchor label noise, and a loop closure at 4.5 s that moves every anchor at once. |

`-LieDARResetStore` empties the capture list before the first screen appears. The journeys pass
it so every run starts from zero rows.

## Running it by hand

Open `Example/Example.xcodeproj` in Xcode, pick the `ExampleApp` scheme and any iOS simulator,
and run. The package is a **local path dependency** (`../`), so the app always builds against the
working copy. There is no version to bump and no remote to fetch.

From the command line, against a simulator you already have booted:

```
xcodebuild build -project Example/Example.xcodeproj -scheme ExampleApp \
  -destination 'platform=iOS Simulator,id=<UDID>' CODE_SIGNING_ALLOWED=NO
```

## Running the journeys

```
bash tools/journeys.sh
```

Expected last line:

```
RESULT: PASS 3 passed/0 failed/0 skipped (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max, com.apple.CoreSimulator.SimRuntime.iOS-26-5)
```

The device type and runtime are whatever the machine has; the counts are the part to read. The
script creates its own throwaway simulator and deletes it on every exit path, runs serially
(`-parallel-testing-enabled NO`) with one retry per failing test, and **fails when zero tests
execute**. An empty test bundle is the silent failure this script is here to catch.

Useful environment variables: `LIEDAR_JOURNEY_ONLY` to run a single journey,
`LIEDAR_JOURNEY_RETRY=0` to run once with no retry, `LIEDAR_JOURNEY_LOG` to put the xcodebuild
log somewhere you can read it, `LIEDAR_JOURNEY_DEVICE_TYPE` / `LIEDAR_JOURNEY_RUNTIME` to pin the
simulator, `LIEDAR_TIMEOUT_SECONDS` for the deadline.

## Running the mutation proof

```
bash tools/journey_mutation.sh
```

Expected last line:

```
RESULT: PASS 1/1 removing 'captures.insert(capture, at: 0)' fails journey 1 on its named assertion; restored byte-identical (sha256 <hash>)
```

It removes the one line in `Example/ExampleApp/CaptureStore.swift` that publishes a finished
capture to the home list, requires journey 1 to fail on the assertion **"Stop & Save did not add
a row to the list"**, not on any failure but on that one, then restores the file and requires the
journey to pass again. Restoration is proven twice over: the file's SHA-256 matches what it was
before, and `git diff --stat` on it is empty. The script refuses to run (`RESULT: BLOCKED`) if
that file has uncommitted changes, because then the diff proves nothing.

## What each journey proves

Every journey asserts values, not presence, and every one ends back on the home list with no
sheet, alert or keyboard open.

**1. `testCaptureSavesARowWithSizeAndFiles`** (`normal`). A capture is recorded, saved and
readable. It waits for the HUD's frame count to climb above zero and its anchor count with it,
taps Stop & Save, and then asserts: the home counter reads exactly 1; the row's size on disk is
greater than zero; the detail screen counts at least one frame file and at least one mesh file;
the detail screen's total bytes **equal** the number the row shows, so the list and the folder
cannot drift apart; `capture.json` claims at least one frame and `anchors.json` at least one
anchor; and, because this scenario runs with the degradation model off, **zero** faces came back
unlabelled.

**2. `testEmptyCaptureIsDiscardedAndAddsNoRow`** (`zeroFrames`). A capture that produced nothing
is thrown away. The source finishes its streams the moment it starts, so Stop & Save is handed an
empty folder. It asserts the HUD stayed at zero frames and zero anchors, the app's status reads
`discarded` rather than `saved`, the home counter is **unchanged** from what it was before, and
no row exists. An empty folder in the list is the bug this journey is against.

**3. `testDegradedCaptureWithLoopClosureStillSaves`** (`degraded`). Degradation and a loop
closure do not stop a capture completing. It waits for the elapsed readout to pass 5 seconds,
which is past the loop-closure event at 4.5 s, and only then stops. It asserts the capture still
reaches the list with a non-zero size, the mesh has faces, at least one face is unlabelled, and
at least 15 % of them are. That is the degradation model's fingerprint, read back off disk rather
than taken on trust.

## Accessibility identifiers

Journeys read numbers, never text. Every number on screen is published through the `measuring`
modifier in `Example/ExampleApp/Accessibility.swift`, which sets the identifier, a human label
that includes the number, and the bare number as the accessibility value. A test that can only
see whether an element exists has nothing to read.

| Identifier | Screen | Value |
|---|---|---|
| `home.count` | Home | how many captures are saved |
| `home.newCapture` | Home | button |
| `home.empty` | Home | shown only when there are none |
| `home.scenario` | Home | the scenario's name |
| `home.list` | Home | the list |
| `capture.row.<n>` | Home | that row's size on disk, in bytes |
| `capture.start` / `capture.stopAndSave` / `capture.done` | Capture | buttons |
| `capture.status` | Capture | `idle`, `running`, `finishing`, `saved`, `discarded`, `failed` |
| `capture.message` | Capture | the sentence under the status |
| `capture.openSaved` | Capture | link to the capture just saved |
| `hud.frames` / `hud.anchors` / `hud.elapsed` | Capture | frames written, anchors held, seconds |
| `detail.list` | Detail | the list |
| `detail.frameFiles` / `detail.meshFiles` | Detail | file counts |
| `detail.frameBytes` / `detail.meshBytes` / `detail.totalBytes` | Detail | byte counts |
| `detail.frameCount` / `detail.anchorCount` / `detail.faceCount` | Detail | what the manifest and the mesh claim |
| `detail.unlabelledFaces` / `detail.unlabelledPercent` | Detail | the degradation model, read back |

## The Xcode project is committed on purpose

`Example/Example.xcodeproj` is checked in. CI runners have no xcodegen, and a clean clone must
build the app and run the journeys with no generation step. The journeys job proves that. `Example/project.yml` is kept so the project can be regenerated deliberately:

```
xcodegen generate --spec Example/project.yml
```

Commit the regenerated project with the change that prompted it. The project has no team, no
profile and no entitlements; simulator builds pass `CODE_SIGNING_ALLOWED=NO`.

## In CI

Three jobs in `.github/workflows/ci.yml` cover this directory, all on `macos-15` with Xcode
26.1.1: `journeys` runs `tools/journeys.sh`, `mutation` runs `tools/journey_mutation.sh` after it,
and `fixture-audit` runs `tools/fixture_audit.sh`. Each one's RESULT line is written to the run
summary, so the verdict is readable without opening a log.
