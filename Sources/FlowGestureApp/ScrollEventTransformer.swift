#if os(macOS)
import CoreGraphics
import FlowGestureCore

/// Device-aware, in-place scroll transformation. It never posts or creates an
/// event, so native phase, momentum, timestamp and pointer metadata survive.
enum ScrollEventTransformer {
    static func shouldTransform(_ event: CGEvent, deviceKind: TouchDeviceKind,
                                configuration: ScrollConfiguration) -> Bool {
        guard event.type == .scrollWheel else { return false }
        return shouldTransform(deviceKind: deviceKind,
                               isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                               scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                               momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                               configuration: configuration)
    }

    static func shouldTransform(deviceKind: TouchDeviceKind, isContinuous: Bool,
                                scrollPhase: Int64 = 0, momentumPhase: Int64 = 0,
                                configuration: ScrollConfiguration) -> Bool {
        guard configuration.isEnabled else { return false }
        if configuration.affectsContinuousScrolling { return true }
        switch deviceKind {
        case .mouse: return true
        case .trackpad: return false
        case .unknown:
            // Sender IDs are unavailable on some mice/drivers. Discrete,
            // phase-free wheels remain usable without treating touch-like
            // unknown events as a mouse just because one flag is absent.
            return !isContinuous && scrollPhase == 0 && momentumPhase == 0
        }
    }

    /// Returns false without mutation when policy excludes this event. All three
    /// representations of each axis must change: clients choose different fields.
    @discardableResult
    static func transform(_ event: CGEvent, deviceKind: TouchDeviceKind,
                          configuration: ScrollConfiguration) -> Bool {
        guard shouldTransform(event, deviceKind: deviceKind, configuration: configuration) else { return false }
        // Routing already distinguishes continuous mice from trackpads. Asking
        // the core to gate continuous events again would incorrectly skip mice.
        let scale = configuration.transform(vertical: 1, horizontal: 1, isContinuous: false)
        transformAxis(event, integerFields: [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1],
                      fixedField: .scrollWheelEventFixedPtDeltaAxis1, scale: scale.vertical)
        transformAxis(event, integerFields: [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2],
                      fixedField: .scrollWheelEventFixedPtDeltaAxis2, scale: scale.horizontal)
        return true
    }

    private static func transformAxis(_ event: CGEvent, integerFields: [CGEventField],
                                      fixedField: CGEventField, scale: Double) {
        // Read all representations before writing any one, so the result is
        // independent of whether CoreGraphics normalizes related fields.
        let integerValues = integerFields.map { event.getIntegerValueField($0) }
        let fixedValue = event.getDoubleValueField(fixedField)
        for (field, value) in zip(integerFields, integerValues) {
            event.setIntegerValueField(field, value: Int64(bounded(Double(value) * scale).rounded()))
        }
        event.setDoubleValueField(fixedField, value: bounded(fixedValue * scale))
    }

    private static func bounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -1_000_000_000), 1_000_000_000)
    }
}
#endif
