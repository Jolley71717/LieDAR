import Foundation
import LieDAR

/// `liedar-fixture --seed N --out DIR [--seconds S] [--depth WxH] [--rate R]`
///
/// Writes a seed-deterministic synthetic capture: `RoomSpec.random(seed:)`, a tour of it,
/// the suite's default degradation and a loop closure, through `ScriptedCapture` (the same
/// gate and recorder a consumer uses). Fixed dates and synthetic device strings, so the same
/// arguments produce the same bytes. Prints one summary line; `tools/make_fixture.sh` owns
/// the RESULT: line.
@main
struct FixtureTool {
    static func main() async {
        var seed: UInt64 = 1
        var out: String?
        var seconds: TimeInterval = 4
        var depth = PixelSize(width: 48, height: 36)
        var rate: Double = 30
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--seed": seed = args.next().flatMap { UInt64($0) } ?? seed
            case "--out": out = args.next()
            case "--seconds": seconds = args.next().flatMap { Double($0) } ?? seconds
            case "--rate": rate = args.next().flatMap { Double($0) } ?? rate
            case "--depth":
                let parts = (args.next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { depth = PixelSize(width: parts[0], height: parts[1]) }
            default:
                FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
                exit(2)
            }
        }
        guard let out else {
            FileHandle.standardError.write(Data("usage: liedar-fixture --seed N --out DIR [--seconds S] [--depth WxH] [--rate R]\n".utf8))
            exit(2)
        }

        var configuration = SyntheticCaptureSource.Configuration(seed: seed, seconds: seconds)
        configuration.realTime = false
        configuration.depthResolution = depth
        configuration.colorResolution = nil
        configuration.camera.frameRate = rate
        let source = SyntheticCaptureSource(configuration: configuration)

        var options = ScriptedCapture.Options()
        options.notes = "LieDAR synthetic fixture, seed \(seed), \(seconds) s tour, depth \(depth.width)x\(depth.height) at \(rate) Hz"
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: folder)
            let report = try await ScriptedCapture.record(from: source, to: folder, options: options)
            print("seed \(seed): \(report.samplesSeen) samples, \(report.normalSamples) normal, \(report.framesWritten) frames written, "
                  + "\(report.framesDropped) dropped, \(report.mesh.anchorCount) anchors, \(report.mesh.totalVertices) vertices, "
                  + "\(report.mesh.totalFaces) faces, events +\(report.anchorsAdded) ~\(report.anchorsUpdated) -\(report.anchorsRemoved), "
                  + "room \(configuration.room.triangleCount) triangles")
        } catch {
            FileHandle.standardError.write(Data("fixture generation failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
