import Foundation

/// Pixel-delta smoothing with independent axes and bounded, non-oscillating tails.
/// Fractional pixels are retained until future input supplies a whole pixel; reset
/// on focus/device/configuration changes so old input cannot leak into another app.
public struct ScrollSmoother: Sendable {
    public static let maximumPendingMagnitude = 1_000_000.0
    public static let maximumStepMagnitude: Int32 = 10_000
    public private(set) var pendingVertical = 0.0
    public private(set) var pendingHorizontal = 0.0

    public init() {}

    public mutating func add(vertical: Double, horizontal: Double) {
        Self.add(vertical, to: &pendingVertical)
        Self.add(horizontal, to: &pendingHorizontal)
    }

    public mutating func reset() {
        pendingVertical = 0
        pendingHorizontal = 0
    }

    /// `deltaTime` is elapsed monotonic time in seconds. Invalid/nonpositive time
    /// emits nothing. Long gaps are bounded rather than flushing a huge jump.
    public mutating func step(deltaTime: Double, duration: Double) -> (vertical: Int32, horizontal: Int32) {
        guard deltaTime.isFinite, deltaTime > 0 else { return (0, 0) }
        let duration = duration.isFinite ? min(max(duration, 0.03), 0.5) : 0.12
        let alpha = 1 - exp(-4 * min(deltaTime, 0.25) / duration)
        guard alpha > 0 else { return (0, 0) }
        return (Self.step(&pendingVertical, alpha: alpha), Self.step(&pendingHorizontal, alpha: alpha))
    }

    private static func add(_ input: Double, to pending: inout Double) {
        guard input.isFinite else { return }
        let bounded = min(max(input, -maximumPendingMagnitude), maximumPendingMagnitude)
        pending = min(max(pending + bounded, -maximumPendingMagnitude), maximumPendingMagnitude)
    }

    private static func step(_ pending: inout Double, alpha: Double) -> Int32 {
        // Never round a fractional tail up then subtract past zero. That would
        // alternate +1/-1 forever and create visible jitter in the destination.
        let wholePixels = floor(abs(pending))
        guard wholePixels >= 1 else { return 0 }
        let magnitude = min(wholePixels, ceil(abs(pending) * alpha), Double(maximumStepMagnitude))
        let signed = pending < 0 ? -magnitude : magnitude
        pending -= signed
        return Int32(signed)
    }
}
