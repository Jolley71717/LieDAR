import XCTest

/// Helpers shared by the journeys. They read numbers off the screen. A journey asserts the value
/// an element shows, never that an element with the right identifier exists. `exists` appears
/// below only where absence is the thing being checked.
enum Journey {
    /// How long to wait for the synthetic capture to make progress. Generous because the whole
    /// capture loop, raycaster included, runs unoptimized in a Debug build on a simulator.
    static let progressTimeout: TimeInterval = 120
    /// How long to wait for a screen to appear or a save to land.
    static let uiTimeout: TimeInterval = 30
}

extension XCUIApplication {
    /// Launches the app in a known state: one scenario, an empty capture list.
    static func launched(scenario: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LieDARScenario", scenario, "-LieDARResetStore"]
        app.launch()
        XCTAssertTrue(app.element(withIdentifier: "home.count").waitForExistence(timeout: Journey.uiTimeout),
                      "the home screen never appeared", file: file, line: line)
        return app
    }

    /// Any element with this identifier, whatever kind SwiftUI made it.
    func element(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

extension XCUIElement {
    /// The number this element publishes. Prefers the accessibility value, falls back to the
    /// digits in its label, and fails with the element's description when there is no number.
    func number(file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let parsed = parsedNumber() else {
            XCTFail("no number on \(self) (value: \(String(describing: value)), label: \(label))",
                    file: file, line: line)
            return -1
        }
        return Int(parsed)
    }

    /// The same as a decimal, for the elapsed-seconds readout.
    func decimal(file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard let parsed = parsedNumber() else {
            XCTFail("no number on \(self) (value: \(String(describing: value)), label: \(label))",
                    file: file, line: line)
            return -1
        }
        return parsed
    }

    /// The word this element publishes as its value, for the status readout.
    func word() -> String {
        if let text = value as? String, !text.isEmpty { return text }
        return label
    }

    private func parsedNumber() -> Double? {
        if let text = value as? String, let parsed = Self.firstNumber(in: text) { return parsed }
        return Self.firstNumber(in: label)
    }

    private static func firstNumber(in text: String) -> Double? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "0123456789.-").inverted
        return scanner.scanDouble()
    }
}

extension XCTestCase {
    /// Polls an element's number until it satisfies `condition`, then returns it. Fails with the
    /// last number seen, which is the thing you want in the log when a journey stalls.
    @discardableResult
    func waitForNumber(_ element: XCUIElement, _ description: String, timeout: TimeInterval,
                       until condition: (Double) -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1.0
        while Date() < deadline {
            if element.exists {
                last = element.decimal(file: file, line: line)
                if condition(last) { return last }
            }
            usleep(250_000)
        }
        XCTFail("\(description) never happened; last value was \(last)", file: file, line: line)
        return last
    }

    /// Polls a status readout until it reads `word`.
    func waitForStatus(_ app: XCUIApplication, _ word: String, timeout: TimeInterval,
                       file: StaticString = #filePath, line: UInt = #line) {
        let status = app.element(withIdentifier: "capture.status")
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if status.exists {
                last = status.word()
                if last == word { return }
            }
            usleep(250_000)
        }
        XCTFail("status never became \(word); last was \(last)", file: file, line: line)
    }

    /// The round-trip rule: a journey ends on the home list, with the expected number of rows,
    /// no capture screen behind it, and nothing modal or keyboard-shaped left open.
    func assertBackOnHome(_ app: XCUIApplication, captureCount: Int,
                          file: StaticString = #filePath, line: UInt = #line) {
        let count = app.element(withIdentifier: "home.count")
        XCTAssertTrue(count.waitForExistence(timeout: Journey.uiTimeout),
                      "not back on the home screen", file: file, line: line)
        XCTAssertEqual(count.number(file: file, line: line), captureCount,
                       "home shows the wrong number of captures", file: file, line: line)
        XCTAssertTrue(app.element(withIdentifier: "home.newCapture").isHittable,
                      "the New capture button is not reachable, so something is still on top",
                      file: file, line: line)
        XCTAssertFalse(app.element(withIdentifier: "capture.start").exists,
                       "the capture screen is still open", file: file, line: line)
        XCTAssertFalse(app.element(withIdentifier: "detail.list").exists,
                       "the detail screen is still open", file: file, line: line)
        XCTAssertEqual(app.keyboards.count, 0, "a keyboard is still up", file: file, line: line)
        XCTAssertEqual(app.sheets.count, 0, "a sheet is still up", file: file, line: line)
        XCTAssertEqual(app.alerts.count, 0, "an alert is still up", file: file, line: line)
    }

    /// Taps the navigation bar's back button.
    func goBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: Journey.uiTimeout), "no back button",
                      file: file, line: line)
        back.tap()
    }
}
