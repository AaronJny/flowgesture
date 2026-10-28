#if os(macOS)
import AppKit
import CoreGraphics
import FlowGestureNative

/// Evidence-based device category. Unknown is deliberately not a mouse fallback.
enum TouchDeviceKind: UInt32, Sendable {
    case unknown = 0, mouse = 1, trackpad = 2
}
enum DeviceClassificationEvidence: UInt32, Sendable {
    case unknown = 0, productName = 1, hidUsage = 2
}
enum RawTouchPhase: UInt32, Sendable {
    case notTracking = 0, enteringRange = 1, hovering = 2, began = 3
    case touching = 4, ended = 5, lingering = 6, outOfRange = 7
    var isActive: Bool { self == .began || self == .touching }
}
struct RawTouchContact: Sendable {
    let id: Int32
    let phase: RawTouchPhase
    let x: Double
    let y: Double
    let quality: Double
    var isActive: Bool { phase.isActive }
    /// Multitouch contact quality/density is NOT calibrated Force Touch pressure.
    var pressure: Double? { nil }
}
struct RawTouchFrame: Sendable {
    let deviceID: UInt64
    let timestamp: Double
    let frameNumber: UInt64
    let contacts: [RawTouchContact]
    let cancelled: Bool
    var activeContacts: [RawTouchContact] { contacts.filter(\.isActive) }
}
struct TouchDeviceInfo: Identifiable, Sendable {
    let id: UInt64
    var deviceID: UInt64 { id }
    let registryID: UInt64?
    let multitouchID: UInt64?
    let kind: TouchDeviceKind
    let classificationEvidence: DeviceClassificationEvidence
    let vendorID: UInt32?
    let productID: UInt32?
    let isBuiltIn: Bool?
    let isStarted: Bool
    let startError: Int32
    let productName: String
}
struct TouchMonitorStatus: Sendable {
    enum State: Int32, Sendable {
        case stopped = 0, running = 1, noDevices = 2, unavailable = 3, failed = 4, busy = 5
    }
    var state: State = .stopped
    var message = "Touch capture stopped."
    var enumeratedDevices = 0
    var startedDevices = 0
    var receivedFrames: UInt64 = 0
    var rejectedFrames: UInt64 = 0
}

/// Owns the callback context independently of the monitor. All native memory is
/// copied before callback return. A bounded queue protects against a stalled UI.
private final class TouchCallbackBox: @unchecked Sendable {
    weak var owner: TouchMonitor?
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var pending: [RawTouchFrame] = []
    private var blockedDevices: Set<UInt64> = []
    private var scheduled = false

    func activate() {
        lock.lock()
        generation &+= 1
        active = true
        pending.removeAll(keepingCapacity: true)
        blockedDevices.removeAll()
        lock.unlock()
    }
    func deactivate() {
        lock.lock()
        generation &+= 1
        active = false
        pending.removeAll(keepingCapacity: true)
        blockedDevices.removeAll()
        lock.unlock()
    }
    func enqueue(_ frame: RawTouchFrame) {
        lock.lock()
        guard active else { lock.unlock(); return }
        if frame.cancelled { blockedDevices.insert(frame.deviceID) }
        if blockedDevices.contains(frame.deviceID), !frame.cancelled {
            // Never resume mid-gesture after loss; wait until all fingers lift.
            guard frame.activeContacts.isEmpty else { lock.unlock(); return }
            blockedDevices.remove(frame.deviceID)
        }
        if pending.count >= 256 {
            let affected = Set(pending.map(\.deviceID)).union([frame.deviceID])
            blockedDevices.formUnion(affected)
            pending = affected.map {
                RawTouchFrame(deviceID: $0, timestamp: frame.timestamp, frameNumber: frame.frameNumber,
                              contacts: [], cancelled: true)
            }
        } else {
            pending.append(frame)
        }
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }
    private func drain() {
        lock.lock()
        let frames = pending
        let currentGeneration = generation
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        let shouldDeliver = active
        lock.unlock()
        guard shouldDeliver else { return }
        for frame in frames {
            lock.lock()
            let isCurrent = active && generation == currentGeneration
            lock.unlock()
            guard isCurrent else { return }
            owner?.receive(frame)
        }
    }
}

private let flowGestureTouchCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<FGTouchFrame>?) -> Void = { context, pointer in
    guard let context, let pointer else { return }
    let box = Unmanaged<TouchCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let native = pointer.pointee
    var contacts: [RawTouchContact] = []
    if let base = native.contacts, native.contact_count > 0, native.contact_count <= 64 {
        contacts = UnsafeBufferPointer(start: base, count: Int(native.contact_count)).compactMap { value in
            guard let phase = RawTouchPhase(rawValue: value.state) else { return nil }
            return RawTouchContact(id: value.identifier, phase: phase, x: value.x, y: value.y, quality: value.quality)
        }
    }
    box.enqueue(RawTouchFrame(deviceID: native.device_id, timestamp: native.timestamp,
                              frameNumber: native.frame_number, contacts: contacts, cancelled: native.cancelled))
}

/// Start/stop and all observer callbacks are main-thread-only. It is safe to call
/// stop from onFrame: native callbacks only enqueue, never wait for the main queue.
final class TouchMonitor {
    var onFrame: ((RawTouchFrame) -> Void)?
    var onStatus: ((TouchMonitorStatus) -> Void)?
    var onDevicesChanged: (([TouchDeviceInfo]) -> Void)?
    var onReset: (() -> Void)?
    private(set) var devices: [TouchDeviceInfo] = []
    private(set) var status = TouchMonitorStatus()
    private var native: OpaquePointer?
    private let callbackBox = TouchCallbackBox()
    private var desiredRunning = false
    private var sleeping = false
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        callbackBox.owner = self
        native = FGTouchMonitorCreate(flowGestureTouchCallback, Unmanaged.passUnretained(callbackBox).toOpaque())
    }
    deinit {
        pollTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        callbackBox.deactivate()
        if let native { FGTouchMonitorDestroy(native) }
    }
    func start() {
        precondition(Thread.isMainThread)
        guard !desiredRunning else { return }
        desiredRunning = true
        installLifecycleObservers()
        restartCapture()
    }
    func stop() {
        precondition(Thread.isMainThread)
        desiredRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        sleeping = false
        stopCapture()
    }
    func refreshDevices() {
        precondition(Thread.isMainThread)
        EventDeviceIdentity.invalidateCache()
        guard desiredRunning, !sleeping else { return }
        restartCapture()
    }
    func refreshDiagnostics() {
        precondition(Thread.isMainThread)
        updateSnapshot()
    }
    fileprivate func receive(_ frame: RawTouchFrame) {
        precondition(Thread.isMainThread)
        guard desiredRunning, !sleeping else { return }
        onFrame?(frame)
    }
    private func stopCapture() {
        callbackBox.deactivate()
        if let native { FGTouchMonitorStop(native) }
        onReset?()
        updateSnapshot()
    }
    private func restartCapture() {
        callbackBox.deactivate()
        if let native { FGTouchMonitorStop(native) }
        onReset?()
        callbackBox.activate()
        if let native { _ = FGTouchMonitorStart(native) }
        updateSnapshot()
    }
    private func updateSnapshot() {
        guard let native else {
            status = TouchMonitorStatus(state: .failed, message: "Could not allocate the touch monitor.")
            onStatus?(status)
            return
        }
        let diagnostics = FGTouchMonitorGetDiagnostics(native)
        var buffer = [CChar](repeating: 0, count: 256)
        let capacity = buffer.count
        FGTouchMonitorCopyStatusMessage(native, &buffer, capacity)
        status = TouchMonitorStatus(state: .init(rawValue: diagnostics.status) ?? .failed,
                                    message: String(cString: buffer),
                                    enumeratedDevices: Int(diagnostics.enumerated_devices),
                                    startedDevices: Int(diagnostics.started_devices),
                                    receivedFrames: diagnostics.received_frames,
                                    rejectedFrames: diagnostics.rejected_frames)
        var snapshot: [TouchDeviceInfo] = []
        for index in 0..<FGTouchMonitorDeviceCount(native) {
            var info = FGTouchDeviceInfo()
            guard FGTouchMonitorGetDevice(native, index, &info) else { continue }
            let name = withUnsafePointer(to: &info.product_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            snapshot.append(TouchDeviceInfo(id: info.device_id, registryID: info.registry_id == 0 ? nil : info.registry_id,
                                           multitouchID: info.multitouch_id == 0 ? nil : info.multitouch_id,
                                           kind: .init(rawValue: info.kind) ?? .unknown,
                                           classificationEvidence: .init(rawValue: info.classification_evidence) ?? .unknown,
                                           vendorID: info.vendor_id == 0 ? nil : info.vendor_id,
                                           productID: info.product_id == 0 ? nil : info.product_id,
                                           isBuiltIn: info.built_in_known ? info.built_in : nil,
                                           isStarted: info.started, startError: info.start_error, productName: name))
        }
        devices = snapshot
        onDevicesChanged?(snapshot)
        onStatus?(status)
    }
    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.desiredRunning else { return }
            self.sleeping = true
            self.stopCapture()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.desiredRunning else { return }
            self.sleeping = false
            self.refreshDevices()
        })
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.desiredRunning, !self.sleeping, let native = self.native else { return }
            // Non-invasive enumeration; only restart on actual topology changes
            // or a prior start failure. No device is seized/exclusively opened.
            if FGTouchMonitorDevicesChanged(native) || self.status.state == .failed {
                self.refreshDevices()
            } else {
                self.updateSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}

struct DeviceEventIdentity: Sendable {
    let senderID: UInt64?
    let kind: TouchDeviceKind
    let classificationEvidence: DeviceClassificationEvidence
    let productName: String
    let vendorID: UInt32?
    let productID: UInt32?
    let senderAPIAvailable: Bool
    let registryFound: Bool
}

/// Resolves the actual optional HID sender, never wheel precision/phase guesses.
/// A small expiring cache keeps IORegistry traversal out of high-rate event taps.
enum EventDeviceIdentity {
    private static let lock = NSLock()
    private static var cache: [UInt64: (expires: TimeInterval, value: DeviceEventIdentity)] = [:]

    static var isAvailable: Bool { FGEventSenderAPIAvailable() }
    static func senderID(for event: CGEvent) -> UInt64? {
        let pointer = Unmanaged.passUnretained(event).toOpaque()
        let value = FGGetEventSenderID(pointer)
        return value == 0 ? nil : value
    }
    static func info(for event: CGEvent) -> DeviceEventIdentity {
        guard let sender = senderID(for: event) else {
            return DeviceEventIdentity(senderID: nil, kind: .unknown, classificationEvidence: .unknown,
                                       productName: "", vendorID: nil, productID: nil,
                                       senderAPIAvailable: isAvailable, registryFound: false)
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let item = cache[sender], item.expires > now { lock.unlock(); return item.value }
        lock.unlock()
        var native = FGGetSenderDeviceInfo(sender)
        let name = withUnsafePointer(to: &native.product_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
        let result = DeviceEventIdentity(senderID: sender, kind: .init(rawValue: native.kind) ?? .unknown,
                                         classificationEvidence: .init(rawValue: native.classification_evidence) ?? .unknown,
                                         productName: name, vendorID: native.vendor_id == 0 ? nil : native.vendor_id,
                                         productID: native.product_id == 0 ? nil : native.product_id,
                                         senderAPIAvailable: native.sender_api_available, registryFound: native.registry_found)
        lock.lock()
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[sender] = (now + (result.kind == .unknown ? 1 : 30), result)
        lock.unlock()
        return result
    }
    static func invalidateCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
#endif
