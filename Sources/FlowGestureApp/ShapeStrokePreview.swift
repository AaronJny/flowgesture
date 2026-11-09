import AppKit
import SwiftUI
import FlowGestureCore

/// A simple stroke needs only CoreGraphics rasterization, not SwiftUI Canvas's
/// Metal renderer, avoiding a Metal-device requirement for this preview on Intel.
/// Input remains with the containing SwiftUI view's DragGesture.
struct ShapeStrokePreview: NSViewRepresentable {
    let points: [GesturePoint]
    let isRecording: Bool

    func makeNSView(context: Context) -> StrokeView { StrokeView(frame: .zero) }

    func updateNSView(_ view: StrokeView, context: Context) {
        view.update(points: points, isRecording: isRecording)
    }

    final class StrokeView: NSView {
        private var points: [GesturePoint] = []
        private var isRecording = false

        // SwiftUI uses a top-left origin, while gesture points increase upwards.
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(points: [GesturePoint], isRecording: Bool) {
            self.points = points
            self.isRecording = isRecording
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let first = points.first, let context = NSGraphicsContext.current?.cgContext else { return }
            func position(_ point: GesturePoint) -> CGPoint {
                CGPoint(x: bounds.minX + CGFloat(point.x), y: bounds.maxY - CGFloat(point.y))
            }

            context.saveGState()
            defer { context.restoreGState() }
            context.beginPath()
            context.move(to: position(first))
            for point in points.dropFirst() { context.addLine(to: position(point)) }
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor(isRecording ? Color.orange : Color.accentColor).cgColor)
            context.strokePath()

            let start = position(first)
            context.setFillColor(NSColor(Color.green).cgColor)
            context.fillEllipse(in: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10))
        }
    }
}
