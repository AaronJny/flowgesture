import AppKit

/// Transparent non-activating windows never intercept the user's pointer.
final class StrokeOverlay {
    private var windows: [(NSPanel, StrokeView)] = []
    func show(_ quartzPoints: [CGPoint]) {
        guard quartzPoints.count > 2, let primary = NSScreen.screens.first else { return }
        if windows.isEmpty {
            windows = NSScreen.screens.map { screen in
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .statusBar
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = StrokeView(frame: NSRect(origin: .zero, size: screen.frame.size))
                panel.contentView = view
                panel.orderFrontRegardless()
                return (panel, view)
            }
        }
        for (panel, view) in windows {
            view.points = quartzPoints.map { CGPoint(x: $0.x - panel.frame.minX, y: primary.frame.height - $0.y - panel.frame.minY) }
            view.needsDisplay = true
        }
    }
    func hide() { windows.forEach { $0.0.orderOut(nil) }; windows.removeAll() }
}
private final class StrokeView: NSView {
    var points: [CGPoint] = []
    override func draw(_ dirtyRect: NSRect) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.systemTeal.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}
