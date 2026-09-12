import SwiftUI

/// What is actually on disk, read back through the package's `CaptureReader`: how many files,
/// how many bytes, and what the mesh says about itself.
struct CaptureDetailView: View {
    let capture: SavedCapture
    @State private var detail: CaptureDetail?

    var body: some View {
        List {
            Section("Files") {
                row("Frame files", detail?.frameFileCount ?? 0, "detail.frameFiles")
                row("Mesh files", detail?.meshFileCount ?? 0, "detail.meshFiles")
            }
            Section("Bytes") {
                row("Frames", detail?.frameBytes ?? 0, "detail.frameBytes")
                row("Mesh", detail?.meshBytes ?? 0, "detail.meshBytes")
                row("Total", detail?.totalBytes ?? 0, "detail.totalBytes")
            }
            Section("Capture") {
                row("Frames written", detail?.manifestFrameCount ?? 0, "detail.frameCount")
                row("Mesh anchors", detail?.anchorCount ?? 0, "detail.anchorCount")
                row("Faces", detail?.faceCount ?? 0, "detail.faceCount")
                row("Unlabelled faces", detail?.unlabelledFaceCount ?? 0, "detail.unlabelledFaces")
                row("Unlabelled percent", detail?.unlabelledPercent ?? 0, "detail.unlabelledPercent")
            }
        }
        .navigationTitle(capture.id)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("detail.list")
        .task(id: capture.id) {
            let folder = capture.folderURL
            detail = await Task.detached(priority: .userInitiated) { CaptureDetail.read(folder) }.value
        }
    }

    private func row(_ title: String, _ value: Int, _ identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
        }
        .measuring(identifier, title, value)
    }
}
