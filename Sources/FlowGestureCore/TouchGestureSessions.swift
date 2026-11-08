/// Keeps recognition and interruption state independent for each physical device.
/// Remembering an idle recognizer must not make the next gesture look like the
/// continuation of an interrupted one.
public struct TouchGestureSessions: Sendable {
    private let configuration: TouchGestureConfiguration
    private var recognizers: [UInt64: TouchGestureRecognizer] = [:]
    private var lastTimestamps: [UInt64: Double] = [:]
    private var activeDevices: Set<UInt64> = []
    private var blockedDevices: Set<UInt64> = []

    public init(configuration: TouchGestureConfiguration = TouchGestureConfiguration()) {
        self.configuration = configuration
    }

    public mutating func process(deviceID: UInt64, frame: TouchFrame, cancelled: Bool = false) -> TouchGesture? {
        // A cancellation often carries no contacts. It is not evidence that the
        // fingers actually lifted, even if this device was already blocked.
        if cancelled {
            recognizers.removeValue(forKey: deviceID)
            activeDevices.remove(deviceID)
            blockedDevices.insert(deviceID)
            return nil
        }
        // A malformed all-up cannot prove release. Keep this check outside the
        // recognizer because interruptions intentionally discard recognizers.
        guard frame.timestamp.isFinite,
              lastTimestamps[deviceID].map({ frame.timestamp >= $0 }) ?? true else {
            recognizers.removeValue(forKey: deviceID)
            activeDevices.remove(deviceID)
            blockedDevices.insert(deviceID)
            return nil
        }
        lastTimestamps[deviceID] = frame.timestamp
        if blockedDevices.contains(deviceID) {
            if frame.touches.isEmpty {
                blockedDevices.remove(deviceID)
                activeDevices.remove(deviceID)
            }
            return nil
        }
        if frame.touches.isEmpty { activeDevices.remove(deviceID) }
        else { activeDevices.insert(deviceID) }

        var recognizer = recognizers[deviceID] ?? TouchGestureRecognizer(configuration: configuration)
        let result = recognizer.process(frame: frame)
        recognizers[deviceID] = recognizer
        return result
    }

    /// On focus or configuration changes, discard only gestures already in
    /// progress. An idle device remains ready for its very next gesture.
    public mutating func cancelActiveGestures() {
        blockedDevices.formUnion(activeDevices)
        activeDevices.removeAll()
        recognizers.removeAll()
    }

    /// The adapter has atomically discarded pending frames and supplies its
    /// acquisition-time activity snapshot. A release may already have arrived
    /// even though its queued frame was never delivered to this recognizer.
    public mutating func interrupt(activeDeviceIDs: Set<UInt64>) {
        blockedDevices = activeDeviceIDs
        activeDevices.removeAll()
        recognizers.removeAll()
    }

    /// A new capture generation has its own device identities and clock.
    public mutating func reset() {
        recognizers.removeAll()
        lastTimestamps.removeAll()
        activeDevices.removeAll()
        blockedDevices.removeAll()
    }
}
