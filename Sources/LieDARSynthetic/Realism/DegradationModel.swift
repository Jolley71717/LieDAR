import Foundation

/// Makes anchor classifications look like a phone's rather than a renderer's. Real scene
/// reconstruction leaves a large share of faces unclassified, mistakes low tables for floor
/// and floor for tables, and is inconsistently noisy from one anchor to the next. Applied to
/// every anchor payload before it leaves `SyntheticCaptureSource`, on faces (the format's
/// classes are per face; a consumer that votes per vertex sees the same effect).
///
/// Seeded: the same `seed` and anchor id degrade the same anchor the same way every time, and
/// an anchor's degradation does not change when it is re-emitted with the same id.
public struct DegradationModel: Sendable, Equatable {
    public var seed: UInt64
    /// Share of faces relabelled `none`. The suite runs at 0.30 by default (PLAN RT-4).
    public var unlabelledFraction: Double
    /// Probability a `floor` face becomes `table` and a `table` face becomes `floor`.
    public var floorTableConfusion: Double
    /// Upper bound of the per-anchor noise rate: each anchor draws its own rate in
    /// `[0, labelNoise]`, and that share of its remaining faces gets a uniformly random class.
    public var labelNoise: Double

    public init(seed: UInt64, unlabelledFraction: Double = 0.30, floorTableConfusion: Double = 0.05, labelNoise: Double = 0.04) {
        precondition((0...1).contains(unlabelledFraction) && (0...1).contains(floorTableConfusion) && (0...1).contains(labelNoise))
        self.seed = seed
        self.unlabelledFraction = unlabelledFraction
        self.floorTableConfusion = floorTableConfusion
        self.labelNoise = labelNoise
    }

    /// The identity model: nothing is changed. For tests that want perfect labels.
    public static let none = DegradationModel(seed: 0, unlabelledFraction: 0, floorTableConfusion: 0, labelNoise: 0)

    /// `anchor` with its classes degraded; geometry, id and transform untouched.
    public func apply(to anchor: MeshAnchorPayload) -> MeshAnchorPayload {
        var out = anchor
        out.classes = Data(degrade(anchor.classArray(), anchorID: anchor.id))
        return out
    }

    /// Degrades a class list for the anchor `anchorID`.
    public func degrade(_ classes: [UInt8], anchorID: UUID) -> [UInt8] {
        var rng = SeededRandom(seed: seed, label: SeededRandom.label(of: anchorID))
        let anchorNoise = rng.nextDouble() * labelNoise
        var out = classes
        for i in out.indices {
            if rng.chance(unlabelledFraction) {
                out[i] = MeshClassification.none.rawValue
                continue
            }
            if out[i] == MeshClassification.floor.rawValue, rng.chance(floorTableConfusion) {
                out[i] = MeshClassification.table.rawValue
            } else if out[i] == MeshClassification.table.rawValue, rng.chance(floorTableConfusion) {
                out[i] = MeshClassification.floor.rawValue
            }
            if rng.chance(anchorNoise) {
                out[i] = UInt8(rng.nextInt(below: MeshClassification.allCases.count))
            }
        }
        return out
    }
}
