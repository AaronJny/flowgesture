/// Tracks acquisition-time contact state, before asynchronous frame delivery.
/// Call from one serialized context (the adapter holds its callback lock).
public struct TouchContactActivity: Sendable {
    public private(set) var activeDeviceIDs: Set<UInt64> = []
    private var timestamps: [UInt64: Double] = [:]
    public init() {}

    public mutating func observe(deviceID: UInt64, timestamp: Double, hasActiveContacts: Bool, cancelled: Bool) {
        guard !cancelled, timestamp.isFinite,
              timestamps[deviceID].map({ timestamp >= $0 }) ?? true else {
            // Loss or an invalid all-up cannot prove that a device is idle.
            activeDeviceIDs.insert(deviceID)
            return
        }
        timestamps[deviceID] = timestamp
        if hasActiveContacts { activeDeviceIDs.insert(deviceID) }
        else { activeDeviceIDs.remove(deviceID) }
    }

    public mutating func reset() {
        activeDeviceIDs.removeAll()
        timestamps.removeAll()
    }
}
