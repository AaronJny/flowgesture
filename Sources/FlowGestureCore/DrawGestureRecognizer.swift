import Foundation

public struct GesturePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isFinite: Bool { x.isFinite && y.isFinite }
    public func distance(to other: GesturePoint) -> Double { hypot(x - other.x, y - other.y) }
}

public struct DrawGestureConfiguration: Codable, Hashable, Sendable {
    public var simplificationTolerance: Double
    public var minimumSegmentLength: Double
    public var includesDiagonals: Bool
    public var maximumDirections: Int
    public init(simplificationTolerance: Double = 8, minimumSegmentLength: Double = 16,
                includesDiagonals: Bool = true, maximumDirections: Int = 12) {
        self.simplificationTolerance = simplificationTolerance
        self.minimumSegmentLength = minimumSegmentLength
        self.includesDiagonals = includesDiagonals
        self.maximumDirections = maximumDirections
    }
}

public struct DrawGestureRecognizer: Sendable {
    public var configuration: DrawGestureConfiguration
    public init(configuration: DrawGestureConfiguration = DrawGestureConfiguration()) { self.configuration = configuration }

    /// Ramer–Douglas–Peucker simplification, iterative to avoid stack growth on long paths.
    /// Invalid coordinates reject the whole path rather than joining disconnected fragments.
    public static func simplify(_ input: [GesturePoint], tolerance: Double) -> [GesturePoint] {
        guard input.allSatisfy(\.isFinite), tolerance.isFinite, tolerance >= 0 else { return [] }
        let points = input.enumerated().filter { $0.offset == 0 || $0.element != input[$0.offset - 1] }.map(\.element)
        guard points.count > 2 else { return points }
        var retained: Set<Int> = [0, points.count - 1]
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var maximum = tolerance
            var furthest: Int?
            for index in (start + 1)..<end {
                let distance = segmentDistance(points[index], points[start], points[end])
                if distance > maximum { maximum = distance; furthest = index }
            }
            if let furthest {
                retained.insert(furthest)
                stack.append((start, furthest))
                stack.append((furthest, end))
            }
        }
        return retained.sorted().map { points[$0] }
    }

    public func directions(for points: [GesturePoint]) -> [GestureDirection] {
        guard configuration.minimumSegmentLength.isFinite, configuration.minimumSegmentLength > 0,
              configuration.maximumDirections > 0 else { return [] }
        let simplified = Self.simplify(points, tolerance: configuration.simplificationTolerance)
        guard var anchor = simplified.first else { return [] }
        var directions: [GestureDirection] = []
        for point in simplified.dropFirst() {
            guard anchor.distance(to: point) >= configuration.minimumSegmentLength else { continue }
            let direction = Self.direction(dx: point.x - anchor.x, dy: point.y - anchor.y,
                                           includesDiagonals: configuration.includesDiagonals)
            if let direction, directions.last != direction { directions.append(direction) }
            anchor = point
            // Do not truncate an overlong drawing into an unintended valid rule.
            if directions.count > configuration.maximumDirections { return [] }
        }
        return directions
    }

    public func matches(_ points: [GesturePoint], directions expected: [GestureDirection]) -> Bool {
        !expected.isEmpty && directions(for: points) == expected
    }

    public static func direction(dx: Double, dy: Double, includesDiagonals: Bool = true) -> GestureDirection? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        let count = includesDiagonals ? 8 : 4
        let sector = (Int((atan2(dy, dx) / (2 * .pi) * Double(count)).rounded()) + count) % count
        let directions: [GestureDirection] = includesDiagonals
            ? [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
            : [.right, .up, .left, .down]
        return directions[sector]
    }

    private static func segmentDistance(_ point: GesturePoint, _ start: GesturePoint, _ end: GesturePoint) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return point.distance(to: start) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return point.distance(to: GesturePoint(x: start.x + projection * dx, y: start.y + projection * dy))
    }
}
