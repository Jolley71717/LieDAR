import Foundation

/// SplitMix64. Every seeded decision in the package, from room layout and anchor churn to
/// replacement UUIDs and label degradation, draws from this and only this, so a seed reproduces a capture
/// byte for byte on any arm64 machine. The generator itself is pure integer arithmetic and is
/// identical everywhere; the arm64 qualification is for the capture as a whole, because the
/// camera path goes through libm trigonometry (`sin` in the hand-held sway, `acos` in the
/// motion gate), which is not bit-identical across architectures. The derived helpers
/// (`nextDouble`, `nextInt(below:)`, `nextUUID`) are written out here rather than taken from
/// the standard library's `random(in:using:)`, whose algorithm is not part of Swift's stability
/// guarantee.
public struct SeededRandom: RandomNumberGenerator, Sendable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// A generator for a sub-stream: the same `seed` and `label` always yield the same stream,
    /// independent of how many values the parent has drawn.
    public init(seed: UInt64, label: UInt64) {
        var mixer = SeededRandom(seed: seed ^ (label &* 0x9E37_79B9_7F4A_7C15))
        state = mixer.next()
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)` with 53 bits of precision.
    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform in `[0, bound)`. Traps on `bound <= 0`.
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return min(bound - 1, Int(nextDouble() * Double(bound)))
    }

    /// Uniform in `range`.
    public mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(nextDouble()) * (range.upperBound - range.lowerBound)
    }

    /// `true` with probability `probability`.
    public mutating func chance(_ probability: Double) -> Bool {
        nextDouble() < probability
    }

    /// A version-4-shaped UUID whose bytes come from this generator.
    public mutating func nextUUID() -> UUID {
        let a = next(), b = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xFF)
            bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A stable 64-bit label for a UUID, for seeding per-anchor sub-streams.
    public static func label(of id: UUID) -> UInt64 {
        let u = id.uuid
        let lo = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7]
        let hi = [u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var a: UInt64 = 0, b: UInt64 = 0
        for i in 0..<8 {
            a |= UInt64(lo[i]) << (8 * UInt64(i))
            b |= UInt64(hi[i]) << (8 * UInt64(i))
        }
        return a ^ (b &* 0x9E37_79B9_7F4A_7C15)
    }
}
