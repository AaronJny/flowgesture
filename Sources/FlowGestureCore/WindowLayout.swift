import Foundation

/// Platform-neutral rectangle. Its coordinate convention is specified by each API.
public struct GestureRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isFinite: Bool { [x, y, width, height].allSatisfy(\.isFinite) }
}

public enum WindowLayout {
    /// Convert a normalized bottom-origin custom layout into a top-origin global
    /// window frame (e.g. Accessibility coordinates). `screen` must already be a
    /// top-origin visible-screen rectangle; it may have negative global origins.
    /// Invalid geometry is rejected, never silently clamped into a different layout.
    public static func frame(forFraction fraction: GestureRect, inTopOriginScreen screen: GestureRect) -> GestureRect? {
        guard fraction.isFinite, screen.isFinite,
              screen.width > 0, screen.height > 0,
              fraction.x >= 0, fraction.y >= 0, fraction.width > 0, fraction.height > 0,
              fraction.x + fraction.width <= 1, fraction.y + fraction.height <= 1 else { return nil }
        let frame = GestureRect(x: screen.x + fraction.x * screen.width,
                                y: screen.y + (1 - fraction.y - fraction.height) * screen.height,
                                width: fraction.width * screen.width,
                                height: fraction.height * screen.height)
        return frame.isFinite && frame.width > 0 && frame.height > 0 ? frame : nil
    }
}
