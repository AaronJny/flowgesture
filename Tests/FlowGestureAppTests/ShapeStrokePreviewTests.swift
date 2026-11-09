import AppKit
import SwiftUI
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class ShapeStrokePreviewTests: XCTestCase {
    private let points = [GesturePoint(x: 18, y: 15), GesturePoint(x: 18, y: 55), GesturePoint(x: 65, y: 55)]

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
        view.needsDisplay = false
        view.update(points: points, isRecording: false)
        XCTAssertTrue(view.needsDisplay)
        try assertColor(render(view), x: 40, y: 25, equals: NSColor(Color.accentColor))
        view.needsDisplay = false
        view.update(points: [], isRecording: false)
        XCTAssertTrue(view.needsDisplay)
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
        view.needsDisplay = false
        view.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(view.needsDisplay)
    }

    @MainActor private func makeView() -> ShapeStrokePreview.StrokeView {
        ShapeStrokePreview.StrokeView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    }

    /// Exercise the actual NSView draw implementation in a CPU bitmap. No
    /// window, Metal device, input permission, or synthetic mouse event is used.
    @MainActor private func render(_ view: ShapeStrokePreview.StrokeView) throws -> Bitmap {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Mark the view's top-left coordinate convention without transforming
        // the bitmap. Tests sample CGContext device coordinates directly.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Bitmap(width: width, bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }

    private struct Bitmap {
        let width: Int
        let bytes: [UInt8]
        func components(x: Int, y: Int) -> [CGFloat] {
            let offset = (y * width + x) * 4
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
