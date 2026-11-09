import AppKit
import SwiftUI
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class ShapeStrokePreviewTests: XCTestCase {
    private let points = [GesturePoint(x: 18, y: 15), GesturePoint(x: 18, y: 55), GesturePoint(x: 65, y: 55)]

    @MainActor func testBitmapSamplingUsesDrawingCoordinatesRatherThanScanlineOrder() async throws {
        // Calibrate the helper independently of StrokeView and its gesture-Y
        // conversion. These rectangles are asymmetric in both axes.
        let image = try renderBitmap(width: 32, height: 24) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 3, y: 4, width: 5, height: 7))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 21, y: 16, width: 4, height: 3))
        }
        try assertColor(image, x: 5, y: 6, equals: .red)
        try assertColor(image, x: 23, y: 17, equals: .blue)
        XCTAssertEqual(image.alpha(x: 5, y: 17), 0)
        XCTAssertEqual(image.alpha(x: 23, y: 6), 0)
    }

    @MainActor func testEmptyPreviewLeavesBackgroundTransparent() async throws {
        let view = makeView()
        view.update(points: [], isRecording: false)
        XCTAssertTrue(try render(view).bytes.allSatisfy { $0 == 0 })
    }

    @MainActor func testSinglePointShowsTenPointStartMarker() async throws {
        let view = makeView()
        view.update(points: [points[0]], isRecording: true)
        let image = try render(view)
        try assertColor(image, x: 18, y: 65, equals: NSColor(Color.green))
        try assertColor(image, x: 21, y: 65, equals: NSColor(Color.green))
        XCTAssertEqual(image.alpha(x: 24, y: 65), 0)
        XCTAssertEqual(image.alpha(x: 18, y: 71), 0)
        XCTAssertEqual(image.alpha(x: 18, y: 15), 0, "Gesture Y must be flipped exactly once")
    }

    @MainActor func testPreviewPreservesOrientationStrokeWidthAndRoundEndpoint() async throws {
        let view = makeView()
        view.update(points: points, isRecording: false)
        let image = try render(view)
        try assertColor(image, x: 18, y: 65, equals: NSColor(Color.green))
        try assertColor(image, x: 18, y: 40, equals: NSColor(Color.accentColor))
        try assertColor(image, x: 40, y: 25, equals: NSColor(Color.accentColor))
        try assertColor(image, x: 40, y: 24, equals: NSColor(Color.accentColor))
        XCTAssertEqual(image.alpha(x: 40, y: 27), 0, "The stroke must remain three points wide")
        XCTAssertEqual(image.alpha(x: 40, y: 55), 0, "An asymmetric path catches vertical mirroring")
        XCTAssertGreaterThan(image.alpha(x: 65, y: 25), 0, "A round cap extends beyond the final point")
        XCTAssertEqual(image.alpha(x: 68, y: 25), 0, "Only the start gets a larger marker")
    }

    @MainActor func testRecordingUsesOrangeAndKeepsGreenStartMarker() async throws {
        let view = makeView()
        view.update(points: points, isRecording: true)
        let image = try render(view)
        try assertColor(image, x: 40, y: 25, equals: NSColor(Color.orange))
        try assertColor(image, x: 18, y: 65, equals: NSColor(Color.green))
    }

    @MainActor func testUpdatesRedrawForRecordingCancelAndClear() async throws {
        let view = makeView()
        view.update(points: points, isRecording: true)
        _ = try render(view)
        view.resetDisplayRequests()
        view.update(points: points, isRecording: false)
        XCTAssertGreaterThan(view.displayRequests, 0, "Cancel must request repaint even before the view has a window")
        try assertColor(render(view), x: 40, y: 25, equals: NSColor(Color.accentColor))
        view.resetDisplayRequests()
        view.update(points: [], isRecording: false)
        XCTAssertGreaterThan(view.displayRequests, 0, "Clear must request repaint")
        XCTAssertTrue(try render(view).bytes.allSatisfy { $0 == 0 })
    }

    @MainActor func testResizeUsesCurrentBoundsForOrientation() async throws {
        let view = makeView()
        view.update(points: [points[0]], isRecording: false)
        view.setFrameSize(NSSize(width: 80, height: 120))
        let image = try render(view)
        try assertColor(image, x: 18, y: 105, equals: NSColor(Color.green))
        XCTAssertEqual(image.alpha(x: 18, y: 65), 0)
    }

    @MainActor func testPreviewDoesNotInterceptParentDragGesture() async {
        let view = makeView()
        view.update(points: points, isRecording: true)
        XCTAssertNil(view.hitTest(NSPoint(x: 18, y: 40)))
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertTrue(view.isFlipped)
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.wantsUpdateLayer, "The preview must use CoreGraphics draw(_:), not a GPU layer")
    }

    @MainActor func testAppearanceChangesInvalidateDynamicColors() async {
        let view = makeView()
        view.resetDisplayRequests()
        view.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(view.displayRequests, 0, "An appearance change must request repaint")
    }

    @MainActor private func makeView() -> RedrawTrackingView {
        RedrawTrackingView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    }

    /// AppKit need not retain dirty regions for an unattached view. Observe the
    /// production invalidation request rather than assuming its getter is true.
    private final class RedrawTrackingView: ShapeStrokePreview.StrokeView {
        private(set) var displayRequests = 0
        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { displayRequests += 1 }
                super.needsDisplay = newValue
            }
        }
        func resetDisplayRequests() { displayRequests = 0 }
    }

    /// Exercise the actual NSView draw implementation in a CPU bitmap. No
    /// window, Metal device, input permission, or synthetic mouse event is used.
    @MainActor private func render(_ view: ShapeStrokePreview.StrokeView) throws -> Bitmap {
        try renderBitmap(width: Int(view.bounds.width), height: Int(view.bounds.height)) { _ in
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        }
    }

    @MainActor private func renderBitmap(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Bitmap {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The flipped flag describes the view; it does not install AppKit's
        // usual view-to-device transform in this standalone CGContext. Keep its
        // default Y-up coordinates and map bitmap scanlines in Bitmap.components.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Bitmap(width: width, height: height, bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        func components(x: Int, y: Int) -> [CGFloat] {
            // CGContext Y starts at the bottom, but bitmap rows start at the
            // top. Sample the pixel square [y, y + 1), not the mirrored row.
            let row = height - 1 - y
            let offset = (row * width + x) * 4
            return (0..<4).map { CGFloat(bytes[offset + $0]) / 255 }
        }
        func alpha(x: Int, y: Int) -> CGFloat { components(x: x, y: y)[3] }
    }

    @MainActor private func assertColor(_ image: Bitmap, x: Int, y: Int, equals color: NSColor,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try XCTUnwrap(color.usingColorSpace(.sRGB), file: file, line: line)
        let actual = image.components(x: x, y: y)
        XCTAssertEqual(actual[0], expected.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual[1], expected.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual[2], expected.blueComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual[3], expected.alphaComponent, accuracy: 0.02, file: file, line: line)
    }
}
