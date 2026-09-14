import Foundation
import simd

/// The walls a person walking the room cannot pass through, on the floor plane.
///
/// Only the room's outline is in here, which for an L-shaped room includes the two inner faces
/// of the notch. Furniture is not, so a walker goes through a table. That is deliberate: the
/// preview exists to look at the room, and a body that snags on a chair is a worse experience
/// than one that walks through it.
public struct WalkBounds: Sendable, Equatable {
    /// One wall, as its two ends in the xz plane.
    public struct Wall: Sendable, Equatable {
        public var start: SIMD2<Float>
        public var end: SIMD2<Float>

        public init(start: SIMD2<Float>, end: SIMD2<Float>) {
            self.start = start
            self.end = end
        }

        /// The point on this wall nearest `p`, clamped to the ends.
        public func closestPoint(to p: SIMD2<Float>) -> SIMD2<Float> {
            let d = end - start
            let lengthSquared = simd_length_squared(d)
            guard lengthSquared > 1e-12 else { return start }
            let t = min(1, max(0, simd_dot(p - start, d) / lengthSquared))
            return start + d * t
        }
    }

    public var walls: [Wall]
    /// How close the camera may get to a wall, in metres. A body, not a point.
    public var radius: Float

    public init(walls: [Wall], radius: Float = 0.3) {
        self.walls = walls
        self.radius = radius
    }

    /// The outline of `spec`, taken from `RoomModel.wallSegments(of:)` so the walls a walker
    /// bumps into are the walls the raycaster draws.
    public static func outline(of spec: RoomSpec, radius: Float = 0.3) -> WalkBounds {
        WalkBounds(walls: RoomModel.wallSegments(of: spec).map { Wall(start: $0.start, end: $0.end) },
                   radius: radius)
    }

    /// The floor-plane bounding box of `model`, for a caller who has a mesh and no `RoomSpec`.
    /// This is the outline of a rectangular room exactly, and of an L-shaped one loosely: the
    /// notch is inside the box, so a walker gets into a corner the room does not have. Use
    /// `outline(of:)` when the spec is to hand.
    public static func box(of model: RoomModel, radius: Float = 0.3) -> WalkBounds {
        let (lo, hi) = model.bounds
        let corners = [SIMD2(lo.x, lo.z), SIMD2(hi.x, lo.z), SIMD2(hi.x, hi.z), SIMD2(lo.x, hi.z)]
        let walls = corners.indices.map { Wall(start: corners[$0], end: corners[($0 + 1) % corners.count]) }
        return WalkBounds(walls: walls, radius: radius)
    }

    /// Where a step from `from` to `to` actually ends: `to`, pushed back out of any wall it came
    /// within `radius` of. `from` is taken to be a legal place to stand, and decides which side
    /// of a wall the push goes when `to` landed exactly on one. Three passes, so a step into a
    /// corner is pushed out of both walls.
    public func resolve(from: SIMD2<Float>, to: SIMD2<Float>) -> SIMD2<Float> {
        var landed = to
        // A long step can pass clean through a wall and land far enough beyond it that the
        // push-out below sees nothing wrong, so the crossing is found first and the step is cut
        // short of it. Without this, holding forward for a few seconds walks out of the room.
        let travel = to - from
        let distance = simd_length(travel)
        if distance > 1e-6 {
            var nearest = Float.greatestFiniteMagnitude
            for wall in walls {
                let s = wall.end - wall.start
                let denominator = travel.x * s.y - travel.y * s.x
                guard abs(denominator) > 1e-12 else { continue }
                let q = wall.start - from
                let t = (q.x * s.y - q.y * s.x) / denominator
                let u = (q.x * travel.y - q.y * travel.x) / denominator
                guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                nearest = min(nearest, t)
            }
            if nearest <= 1 {
                landed = from + travel * max(0, nearest - radius / distance)
            }
        }
        // Then out of anything the step ended too close to, including the second wall of a
        // corner, which is why this runs more than once.
        for _ in 0..<3 {
            var pushed = false
            for wall in walls {
                let closest = wall.closestPoint(to: landed)
                var away = landed - closest
                var gap = simd_length(away)
                guard gap < radius else { continue }
                if gap < 1e-5 {
                    // Landed on the wall itself, so the side to push towards comes from where
                    // the step started.
                    away = from - wall.closestPoint(to: from)
                    gap = simd_length(away)
                    guard gap >= 1e-5 else { continue }
                }
                landed = closest + (away / gap) * radius
                pushed = true
            }
            if !pushed { break }
        }
        return landed
    }
}
