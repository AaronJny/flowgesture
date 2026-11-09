import CoreGraphics
import FlowGestureCore

/// Experimental decoder only. Installing this type does not install a tap or
/// consume events. Field provenance and activation gates are documented in
/// docs/development/native-horizontal-arbitration.md.
enum NativeHorizontalSwipeDecoder {
    static let selectorField: UInt32 = 55
    static let hidTypeField: UInt32 = 110
    static let axisField: UInt32 = 123
    static let progressField: UInt32 = 124
    static let velocityXField: UInt32 = 129
    static let phaseField: UInt32 = 132

    static func decode(type: CGEventType, event: CGEvent, senderRegistryID: UInt64?,
                       sourceProvenance: NativeHorizontalSwipeEvent.SourceProvenance = .unverified) -> NativeHorizontalSwipeEvent? {
        guard type.rawValue == 29 || type.rawValue == 30,
              let selector = CGEventField(rawValue: selectorField),
              let hidType = CGEventField(rawValue: hidTypeField),
              let axis = CGEventField(rawValue: axisField),
              let progress = CGEventField(rawValue: progressField),
              let velocity = CGEventField(rawValue: velocityXField),
              let phase = CGEventField(rawValue: phaseField),
              event.getIntegerValueField(selector) == Int64(type.rawValue) else { return nil }
        return NativeHorizontalSwipeEvent(eventClass: Int64(type.rawValue),
                                          hidType: event.getIntegerValueField(hidType),
                                          axis: event.getIntegerValueField(axis),
                                          phase: event.getIntegerValueField(phase),
                                          senderRegistryID: senderRegistryID,
                                          sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                                          progress: event.getDoubleValueField(progress),
                                          velocityX: event.getDoubleValueField(velocity),
                                          sourceProvenance: sourceProvenance)
    }
}
