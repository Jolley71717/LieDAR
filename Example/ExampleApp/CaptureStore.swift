import Foundation
import LieDAR

/// One finished capture on disk, as the home list shows it.
struct SavedCapture: Identifiable, Equatable, Hashable {
    /// The folder name; also the row's identity in the list.
    var id: String
    var folderURL: URL
    /// Every byte under the folder, which is what "how big is my capture" means to a user.
    var byteCount: Int
    var frameCount: Int
    var anchorCount: Int
}

/// The home list's model: captures that have been finished and published, newest first.
///
/// The list is held in memory and loaded from disk once, at launch. Saving a capture publishes
/// it here. Nothing else re-scans the folder behind the list's back, so the save signal is one
/// line, which is the line `tools/journey_mutation.sh` removes.
@MainActor
final class CaptureStore: ObservableObject {
    @Published private(set) var captures: [SavedCapture] = []

    let rootURL: URL

    init(rootURL: URL = CaptureStore.defaultRoot, reset: Bool = false) {
        self.rootURL = rootURL
        if reset { emptyOnDisk() }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        captures = Self.scan(rootURL)
    }

    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Captures", isDirectory: true)
    }

    /// Publishes a finished capture to the home list.
    func add(_ capture: SavedCapture) {
        // THE SAVE SIGNAL. `tools/journey_mutation.sh` deletes exactly this line and requires
        // journey 1 to fail on its "a row was added" assertion, then restores it byte-identical.
        captures.insert(capture, at: 0)
    }

    /// A fresh, empty folder for the next capture. Numbered so the name a person sees is
    /// `capture-1`, `capture-2`, and so on.
    func newCaptureFolder() -> URL {
        var next = captures.count + 1
        var url = rootURL.appendingPathComponent("capture-\(next)", isDirectory: true)
        while FileManager.default.fileExists(atPath: url.path) {
            next += 1
            url = rootURL.appendingPathComponent("capture-\(next)", isDirectory: true)
        }
        return url
    }

    func capture(id: String) -> SavedCapture? { captures.first { $0.id == id } }

    private func emptyOnDisk() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func scan(_ root: URL) -> [SavedCapture] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().reversed().compactMap { name -> SavedCapture? in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let contents = CaptureFormat.contents(of: folder)
            guard CaptureFormat.disposition(of: contents) != .discardEmpty else { return nil }
            return SavedCapture(id: name, folderURL: folder, byteCount: byteCount(of: folder),
                                frameCount: contents.frameCount, anchorCount: contents.meshAnchorCount)
        }
    }

    /// Total bytes of every regular file under `folder`.
    nonisolated static func byteCount(of folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
