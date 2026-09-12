import XCTest

/// The three journeys. They drive the example app as a black box, with a launch argument going in
/// and taps and numbers coming out, and they never import the app or the package. What they prove
/// is that a capture written by LieDAR reaches disk, reaches the list, and reads back with the
/// counts it claims.
final class JourneyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Journey 1. A capture is recorded, saved and readable.
    ///
    /// Asserts, in order: the HUD's frame count climbs above zero and its anchor count with it;
    /// after Stop & Save the home list holds exactly one row; that row's size on disk is
    /// non-zero; the detail screen counts at least one frame file and at least one mesh file;
    /// the detail screen's total bytes equal the row's; and, because this scenario has the
    /// degradation model off, not one face came back unlabelled.
    func testCaptureSavesARowWithSizeAndFiles() {
        let app = XCUIApplication.launched(scenario: "normal")
        XCTAssertEqual(app.element(withIdentifier: "home.count").number(), 0, "the list did not start empty")

        app.element(withIdentifier: "home.newCapture").tap()
        XCTAssertEqual(app.element(withIdentifier: "capture.status").word(), "idle")
        XCTAssertEqual(app.element(withIdentifier: "hud.frames").number(), 0, "frames did not start at zero")
        app.element(withIdentifier: "capture.start").tap()

        let frames = waitForNumber(app.element(withIdentifier: "hud.frames"),
                                   "the frame count never climbed above zero",
                                   timeout: Journey.progressTimeout) { $0 >= 1 }
        XCTAssertGreaterThan(frames, 0)
        waitForNumber(app.element(withIdentifier: "hud.anchors"),
                      "no mesh anchor was ever discovered",
                      timeout: Journey.progressTimeout) { $0 >= 1 }

        app.element(withIdentifier: "capture.stopAndSave").tap()
        waitForStatus(app, "saved", timeout: Journey.progressTimeout)
        app.element(withIdentifier: "capture.done").tap()

        XCTAssertEqual(app.element(withIdentifier: "home.count").number(), 1,
                       "Stop & Save did not add a row to the list")
        let row = app.element(withIdentifier: "capture.row.0")
        XCTAssertTrue(row.waitForExistence(timeout: Journey.uiTimeout), "no capture row on the list")
        let rowBytes = row.number()
        XCTAssertGreaterThan(rowBytes, 0, "the saved capture claims to be zero bytes on disk")

        row.tap()
        XCTAssertTrue(app.element(withIdentifier: "detail.list").waitForExistence(timeout: Journey.uiTimeout))
        let frameFiles = waitForNumber(app.element(withIdentifier: "detail.frameFiles"),
                                       "the capture folder holds no frame files",
                                       timeout: Journey.uiTimeout) { $0 >= 1 }
        let meshFiles = waitForNumber(app.element(withIdentifier: "detail.meshFiles"),
                                      "the capture folder holds no mesh files",
                                      timeout: Journey.uiTimeout) { $0 >= 1 }
        XCTAssertGreaterThan(frameFiles, 0)
        XCTAssertGreaterThan(meshFiles, 0)
        XCTAssertEqual(app.element(withIdentifier: "detail.totalBytes").number(), rowBytes,
                       "the row's size and the folder's size disagree")
        XCTAssertGreaterThanOrEqual(app.element(withIdentifier: "detail.frameCount").number(), 1,
                                    "capture.json claims no frames were written")
        XCTAssertGreaterThanOrEqual(app.element(withIdentifier: "detail.anchorCount").number(), 1,
                                    "anchors.json claims no anchors were written")
        XCTAssertEqual(app.element(withIdentifier: "detail.unlabelledFaces").number(), 0,
                       "the clean-room scenario produced unlabelled faces")

        goBack(app)
        assertBackOnHome(app, captureCount: 1)
    }

    /// Journey 2. A capture that produced nothing is thrown away.
    ///
    /// The source finishes its streams the moment it starts, so Stop & Save has an empty folder
    /// to deal with. Asserts the HUD stayed at zero frames and zero anchors, the app reports the
    /// capture as discarded rather than saved, and the home list holds exactly as many rows as
    /// it did before, which is none.
    func testEmptyCaptureIsDiscardedAndAddsNoRow() {
        let app = XCUIApplication.launched(scenario: "zeroFrames")
        let before = app.element(withIdentifier: "home.count").number()
        XCTAssertEqual(before, 0, "the list did not start empty")

        app.element(withIdentifier: "home.newCapture").tap()
        app.element(withIdentifier: "capture.start").tap()

        let stop = app.element(withIdentifier: "capture.stopAndSave")
        XCTAssertTrue(stop.waitForExistence(timeout: Journey.uiTimeout), "Stop & Save never appeared")
        stop.tap()
        waitForStatus(app, "discarded", timeout: Journey.progressTimeout)

        XCTAssertEqual(app.element(withIdentifier: "hud.frames").number(), 0,
                       "a source that yields nothing still wrote frames")
        XCTAssertEqual(app.element(withIdentifier: "hud.anchors").number(), 0,
                       "a source that yields nothing still produced anchors")

        app.element(withIdentifier: "capture.done").tap()
        XCTAssertEqual(app.element(withIdentifier: "home.count").number(), before,
                       "an empty capture changed the number of rows")
        XCTAssertFalse(app.element(withIdentifier: "capture.row.0").exists,
                       "an empty capture was added to the list")
        XCTAssertTrue(app.element(withIdentifier: "home.empty").exists,
                      "the list is not showing its empty state")
        assertBackOnHome(app, captureCount: before)
    }

    /// Journey 3. Degraded labels and a loop closure do not stop a capture from completing.
    ///
    /// This scenario runs the realism defaults: about 30 % of faces unlabelled, floor/table
    /// confusion, and a loop-closure event three quarters of the way along the path that moves
    /// every anchor at once. The journey waits past that event by watching the elapsed readout,
    /// then asserts the capture still saves a row with non-zero size, and that the mesh really
    /// did come back degraded: at least one unlabelled face, and at least 15 % of them.
    func testDegradedCaptureWithLoopClosureStillSaves() {
        let app = XCUIApplication.launched(scenario: "degraded")
        XCTAssertEqual(app.element(withIdentifier: "home.count").number(), 0, "the list did not start empty")

        app.element(withIdentifier: "home.newCapture").tap()
        app.element(withIdentifier: "capture.start").tap()

        // The loop closure fires at 4.5 s of captured time. Waiting past it is what makes this
        // journey different from journey 1.
        let elapsed = waitForNumber(app.element(withIdentifier: "hud.elapsed"),
                                    "the capture never reached the loop-closure event at 4.5 s",
                                    timeout: Journey.progressTimeout) { $0 >= 5.0 }
        XCTAssertGreaterThanOrEqual(elapsed, 5.0)
        XCTAssertGreaterThanOrEqual(app.element(withIdentifier: "hud.frames").number(), 1,
                                    "no frames were written before the loop closure")

        app.element(withIdentifier: "capture.stopAndSave").tap()
        waitForStatus(app, "saved", timeout: Journey.progressTimeout)
        app.element(withIdentifier: "capture.done").tap()

        XCTAssertEqual(app.element(withIdentifier: "home.count").number(), 1,
                       "a degraded capture did not reach the list")
        let row = app.element(withIdentifier: "capture.row.0")
        XCTAssertTrue(row.waitForExistence(timeout: Journey.uiTimeout), "no capture row on the list")
        XCTAssertGreaterThan(row.number(), 0, "the degraded capture claims to be zero bytes on disk")

        row.tap()
        XCTAssertTrue(app.element(withIdentifier: "detail.list").waitForExistence(timeout: Journey.uiTimeout))
        waitForNumber(app.element(withIdentifier: "detail.faceCount"),
                      "the mesh has no faces", timeout: Journey.uiTimeout) { $0 >= 1 }
        XCTAssertGreaterThan(app.element(withIdentifier: "detail.unlabelledFaces").number(), 0,
                             "the degradation model left every face labelled")
        XCTAssertGreaterThanOrEqual(app.element(withIdentifier: "detail.unlabelledPercent").number(), 15,
                                    "far fewer faces are unlabelled than the model asks for")

        goBack(app)
        assertBackOnHome(app, captureCount: 1)
    }
}
