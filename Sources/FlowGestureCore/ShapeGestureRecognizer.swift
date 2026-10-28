import Foundation

/// Compares a single, ordered free-form stroke with a recorded template.
/// Translation and uniform scale are ignored; rotation, reflection, aspect ratio,
/// stroke direction, and the chosen starting point remain meaningful.
public struct ShapeGestureRecognizer: Sendable {
    public static let sampleCount = 64
    public static let maximumInputPoints = 2_048
    public init() {}

    /// Centers the bounding box, scales its longest side to one, then resamples
    /// at equal arc-length intervals. Invalid or degenerate paths are rejected.
    public static func normalizedPath(_ input: [GesturePoint]) -> [GesturePoint] {
        guard (2...maximumInputPoints).contains(input.count), input.allSatisfy(\.isFinite) else { return [] }
        let points = input.enumerated().filter { $0.offset == 0 || $0.element != input[$0.offset - 1] }.map(\.element)
        guard points.count > 1,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return [] }
        let width = maxX - minX, height = maxY - minY
        let scale = max(width, height)
        guard scale.isFinite, scale > 1e-9 else { return [] }
        // Subtract min before centering to avoid overflow in (min + max) / 2.
        let normalized = points.map {
            GesturePoint(x: ($0.x - minX) / scale - width / scale / 2,
                         y: ($0.y - minY) / scale - height / scale / 2)
        }
        guard normalized.allSatisfy(\.isFinite) else { return [] }
        var cumulative = [0.0]
        for index in 1..<normalized.count {
            cumulative.append(cumulative[index - 1] + normalized[index - 1].distance(to: normalized[index]))
        }
        guard let length = cumulative.last, length.isFinite, length > 1e-9 else { return [] }
        var result: [GesturePoint] = []
        result.reserveCapacity(sampleCount)
        var upper = 1
        for sample in 0..<sampleCount {
            if sample == sampleCount - 1 {
                result.append(normalized[normalized.count - 1])
                continue
            }
            let target = length * Double(sample) / Double(sampleCount - 1)
            while upper < cumulative.count - 1 && cumulative[upper] < target { upper += 1 }
            let lower = upper - 1
            let segment = cumulative[upper] - cumulative[lower]
            let fraction = segment > 0 ? min(1, max(0, (target - cumulative[lower]) / segment)) : 0
            result.append(GesturePoint(x: normalized[lower].x + (normalized[upper].x - normalized[lower].x) * fraction,
                                       y: normalized[lower].y + (normalized[upper].y - normalized[lower].y) * fraction))
        }
        return result
    }

    /// 1 is an exact normalized match; 0 is a mean point distance of at least one
    /// bounding-box unit. nil means one of the strokes was malformed/degenerate.
    public func similarity(_ candidate: [GesturePoint], to template: [GesturePoint]) -> Double? {
        let lhs = Self.normalizedPath(candidate), rhs = Self.normalizedPath(template)
        guard lhs.count == Self.sampleCount, rhs.count == Self.sampleCount else { return nil }
        let distance = zip(lhs, rhs).reduce(0.0) { $0 + $1.0.distance(to: $1.1) } / Double(Self.sampleCount)
        guard distance.isFinite else { return nil }
        return min(1, max(0, 1 - distance))
    }

    /// tolerance is the maximum mean normalized distance (0.15 = at least 85%
    /// similarity). Input adapters should also reject tiny physical mouse strokes.
    public func matches(_ candidate: [GesturePoint], template: [GesturePoint], tolerance: Double = 0.15) -> Bool {
        guard tolerance.isFinite, (0.03...0.4).contains(tolerance),
              let score = similarity(candidate, to: template) else { return false }
        return score + 1e-12 >= 1 - tolerance
    }

    /// Longest bounding-box side in the input coordinate system, useful for an
    /// adapter's physical-distance threshold before normalization removes scale.
    public static func strokeExtent(_ input: [GesturePoint]) -> Double? {
        guard (2...maximumInputPoints).contains(input.count), input.allSatisfy(\.isFinite),
              let minX = input.map(\.x).min(), let maxX = input.map(\.x).max(),
              let minY = input.map(\.y).min(), let maxY = input.map(\.y).max() else { return nil }
        let extent = max(maxX - minX, maxY - minY)
        return extent.isFinite ? extent : nil
    }
}
