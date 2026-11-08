import Foundation

public struct TouchSample: Codable, Hashable, Sendable {
    /// Stable contact ID, retained by the adapter until that finger lifts.
    public var id: Int
    /// Normalized device coordinates (0...1), positive Y up.
    public var location: GesturePoint
    public init(id: Int, location: GesturePoint) { self.id = id; self.location = location }
}

public struct TouchFrame: Codable, Hashable, Sendable {
    /// Monotonic seconds, not a wall-clock date.
    public var timestamp: Double
    /// All contacts currently down. Send an empty frame when the last finger lifts.
    public var touches: [TouchSample]
    public init(timestamp: Double, touches: [TouchSample]) { self.timestamp = timestamp; self.touches = touches }
}

public struct TouchGestureConfiguration: Codable, Hashable, Sendable {
    public var maximumTapDuration: Double
    public var tapMovementTolerance: Double
    public var swipeDistance: Double
    public var pinchScaleChange: Double
    public var fingerJoinInterval: Double
    public var maximumGestureDuration: Double
    public var includesDiagonalSwipes: Bool
    public init(maximumTapDuration: Double = 0.3, tapMovementTolerance: Double = 0.025,
                swipeDistance: Double = 0.12, pinchScaleChange: Double = 0.22,
                fingerJoinInterval: Double = 0.08, maximumGestureDuration: Double = 2,
                includesDiagonalSwipes: Bool = false) {
        self.maximumTapDuration = maximumTapDuration
        self.tapMovementTolerance = tapMovementTolerance
        self.swipeDistance = swipeDistance
        self.pinchScaleChange = pinchScaleChange
        self.fingerJoinInterval = fingerJoinInterval
        self.maximumGestureDuration = maximumGestureDuration
        self.includesDiagonalSwipes = includesDiagonalSwipes
    }

    fileprivate var isValid: Bool {
        [maximumTapDuration, tapMovementTolerance, swipeDistance, pinchScaleChange, fingerJoinInterval, maximumGestureDuration]
            .allSatisfy { $0.isFinite && $0 >= 0 }
            && maximumTapDuration > 0 && swipeDistance > 0 && pinchScaleChange > 0
            && maximumGestureDuration >= maximumTapDuration
    }
}

/// A deterministic, device-independent recognizer. At most one result is emitted between
/// all-fingers-up frames. Touch interception and system-gesture arbitration are adapter concerns.
public struct TouchGestureRecognizer: Sendable {
    public var configuration: TouchGestureConfiguration
    private var session: Session?
    private var lastTimestamp: Double?
    private var suppressedUntilRelease = false

    public init(configuration: TouchGestureConfiguration = TouchGestureConfiguration()) { self.configuration = configuration }

    /// Reset when monitoring stops, the device disconnects, or focus changes.
    public mutating func reset() {
        session = nil
        lastTimestamp = nil
        suppressedUntilRelease = false
    }

    public mutating func process(frame: TouchFrame) -> TouchGesture? {
        guard configuration.isValid, frame.timestamp.isFinite,
              lastTimestamp.map({ frame.timestamp >= $0 }) ?? true,
              Self.isValid(frame.touches) else {
            session = nil
            suppressedUntilRelease = true
            return nil
        }
        lastTimestamp = frame.timestamp
        if suppressedUntilRelease {
            if frame.touches.isEmpty { suppressedUntilRelease = false }
            return nil
        }
        if frame.touches.isEmpty {
            defer { session = nil }
            guard let session, !session.fired, !session.cancelled,
                  frame.timestamp - session.startedAt <= configuration.maximumGestureDuration else { return nil }
            // A complete short flick must not disappear while waiting for more fingers.
            if let pending = session.pending { return pending }
            guard frame.timestamp - session.startedAt <= configuration.maximumTapDuration,
                  session.maximumMovement <= configuration.tapMovementTolerance else { return nil }
            return .tap(fingers: session.origins.count)
        }
        let positions = Dictionary(uniqueKeysWithValues: frame.touches.map { ($0.id, $0.location) })
        let ids = Set(positions.keys)
        guard var current = session else {
            session = Session(startedAt: frame.timestamp, origins: positions, baseline: positions, activeIDs: ids)
            return nil
        }
        // Preserve the fired state until all contacts lift, even if contacts change.
        if current.fired || current.cancelled { return nil }
        let elapsed = frame.timestamp - current.startedAt
        if elapsed > configuration.maximumGestureDuration {
            current.cancelled = true
            session = current
            return nil
        }
        for (id, location) in positions {
            if let origin = current.origins[id] { current.maximumMovement = max(current.maximumMovement, origin.distance(to: location)) }
        }
        if ids != current.activeIDs {
            if ids.isStrictSuperset(of: current.activeIDs), !current.ending,
               elapsed <= configuration.fingerJoinInterval {
                // Accommodate fingers landing a few milliseconds apart, but do not erase
                // pre-join movement when deciding whether the whole interaction is a tap.
                for (id, location) in positions where current.origins[id] == nil { current.origins[id] = location }
                current.baseline = positions
                current.activeIDs = ids
                // Evidence from a smaller cohort cannot commit its finger count or pinch.
                current.pending = motionGesture(current: current, positions: positions)
            } else if ids.isStrictSubset(of: current.activeIDs) {
                // Staggered release is normal. Do not mistake its centroid jump for a swipe.
                current.ending = true
                current.activeIDs = ids
            } else {
                current.cancelled = true
            }
            session = current
            return nil
        }
        guard !current.ending else { session = current; return nil }
        // The window includes its exact endpoint, just like the join check above.
        // Keep the first threshold crossing for this cohort, including a quick reversal.
        if current.pending == nil { current.pending = motionGesture(current: current, positions: positions) }
        let gesture = elapsed > configuration.fingerJoinInterval ? current.pending : nil
        if gesture != nil { current.fired = true }
        session = current
        return gesture
    }

    private func motionGesture(current: Session, positions: [Int: GesturePoint]) -> TouchGesture? {
        // Stable ordering avoids hash-seed-dependent floating-point accumulation.
        // Origins preserve movement before a join. A new contact starts with zero
        // displacement, so only movement actually observed contributes to the swipe.
        let originPoints = positions.keys.sorted().compactMap { current.origins[$0] }
        let baselinePoints = positions.keys.sorted().compactMap { current.baseline[$0] }
        let points = positions.keys.sorted().compactMap { positions[$0] }
        let startCenter = Self.centroid(originPoints)
        let baselineCenter = Self.centroid(baselinePoints)
        let center = Self.centroid(points)
        let translation = startCenter.distance(to: center)
        let initialRadius = Self.meanRadius(baselinePoints, around: baselineCenter)
        let radius = Self.meanRadius(points, around: center)
        // Pinch baselines rebase when a finger joins: landing spread is not pinching.
        // Two-contact scale change and centroid translation compete on normalized evidence.
        let pinchEvidence = positions.count == 2 && initialRadius > 0.01
            ? abs(radius / initialRadius - 1) / configuration.pinchScaleChange : 0
        let swipeEvidence = translation / configuration.swipeDistance
        if pinchEvidence >= 1 && pinchEvidence > swipeEvidence {
            return .pinch(radius < initialRadius ? .inward : .outward)
        } else if swipeEvidence >= 1,
                  let direction = DrawGestureRecognizer.direction(dx: center.x - startCenter.x,
                                                                 dy: center.y - startCenter.y,
                                                                 includesDiagonals: configuration.includesDiagonalSwipes) {
            return .swipe(fingers: positions.count, direction: direction)
        }
        return nil
    }

    private struct Session: Sendable {
        var startedAt: Double
        var origins: [Int: GesturePoint]
        var baseline: [Int: GesturePoint]
        var activeIDs: Set<Int>
        var maximumMovement: Double = 0
        var pending: TouchGesture?
        var fired = false
        var ending = false
        var cancelled = false
    }

    private static func isValid(_ touches: [TouchSample]) -> Bool {
        touches.count <= 5 && Set(touches.map(\.id)).count == touches.count
            && touches.allSatisfy { $0.location.isFinite && (0...1).contains($0.location.x) && (0...1).contains($0.location.y) }
    }
    private static func centroid(_ positions: [GesturePoint]) -> GesturePoint {
        let count = Double(positions.count)
        return GesturePoint(x: positions.reduce(0) { $0 + $1.x } / count,
                            y: positions.reduce(0) { $0 + $1.y } / count)
    }
    private static func meanRadius(_ positions: [GesturePoint], around center: GesturePoint) -> Double {
        positions.reduce(0) { $0 + $1.distance(to: center) } / Double(positions.count)
    }
}
