import SwiftUI

extension View {
    /// Publishes a number as an accessibility value, so a test reads it directly instead of
    /// scraping digits out of a sentence. The label stays a human phrase that includes the
    /// number, so a reader hears "Frames written 13" and a test reads `element.value == "13"`.
    ///
    /// Every number the journeys assert on goes through here. A test that can only see whether
    /// an element exists has nothing to read.
    func measuring(_ identifier: String, _ label: String, _ value: some CustomStringConvertible) -> some View {
        stating(identifier, label, String(describing: value))
    }

    /// The same, for a word rather than a number: a phase name, a scenario name.
    func stating(_ identifier: String, _ label: String, _ value: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("\(label) \(value)")
            .accessibilityValue(value)
    }
}
