#if os(macOS)
import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import FlowGestureNative
import Foundation

private final class CaptureCallbackContext {
    let store: CaptureStore
    let senderAPIAvailable: Bool
    init(store: CaptureStore, senderAPIAvailable: Bool) {
        self.store = store; self.senderAPIAvailable = senderAPIAvailable
    }
}

private let passiveTouchCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<FGTouchFrame>?) -> Void = { context, pointer in
    let acquired = DispatchTime.now().uptimeNanoseconds
    guard let context, let pointer else { return }
    let box = Unmanaged<CaptureCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let frame = pointer.pointee
    var contacts: [CaptureContact] = []
    if frame.contact_count > 0, frame.contact_count <= 64, let base = frame.contacts {
        contacts = UnsafeBufferPointer(start: base, count: Int(frame.contact_count)).map {
            CaptureContact(identifier: $0.identifier, state: $0.state, normalizedX: $0.x, normalizedY: $0.y)
        }
    }
    box.store.observeRaw(deviceID: frame.device_id, sourceTimestamp: frame.timestamp, frameNumber: frame.frame_number,
                         bridgeContactCount: Int(clamping: frame.contact_count), contacts: contacts,
                         cancelled: frame.cancelled, acquiredAt: acquired)
}

private let passiveQuartzCallback: CGEventTapCallBack = { _, type, event, context in
    let acquired = DispatchTime.now().uptimeNanoseconds
    guard let context else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<CaptureCallbackContext>.fromOpaque(context).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        box.store.finish(.tapDisabled, at: acquired)
        // Never re-enable after loss and never replace or consume the input.
        return Unmanaged.passUnretained(event)
    }
    let eventClass = type.rawValue
    // Defense in depth: do not even query fields for excluded public classes.
    guard CaptureStore.allowedQuartzClasses.contains(eventClass) else {
        box.store.rejectUnexpectedQuartz(acquiredAt: acquired)
        return Unmanaged.passUnretained(event)
    }
    var fields: CapturePrivateFields?
    if eventClass == 29 || eventClass == 30 {
        // These six selectors are corroborated by WebKit CoreGraphicsTestSPI.h
        // b2d2c2de1c74e095233e4ed243272fa7f0f89698 and the existing inactive
        // NativeHorizontalSwipeDecoder. No other private event fields are read.
        if let selector = CGEventField(rawValue: 55), let hidType = CGEventField(rawValue: 110),
           let axis = CGEventField(rawValue: 123), let progress = CGEventField(rawValue: 124),
           let velocity = CGEventField(rawValue: 129), let phase = CGEventField(rawValue: 132) {
            fields = CapturePrivateFields(callbackClass: eventClass, selector: event.getIntegerValueField(selector),
                                          hidType: event.getIntegerValueField(hidType), axis: event.getIntegerValueField(axis),
                                          progress: event.getDoubleValueField(progress), velocityX: event.getDoubleValueField(velocity),
                                          phase: event.getIntegerValueField(phase))
        }
    }
    let sender = box.senderAPIAvailable ? FGGetEventSenderID(Unmanaged.passUnretained(event).toOpaque()) : 0
    let value = CaptureQuartzFields(callbackClass: eventClass, eventClass: event.type.rawValue,
                                    sourceTimestamp: event.timestamp, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                                    sourceUserData: event.getIntegerValueField(.eventSourceUserData), flagsRawValue: event.flags.rawValue,
                                    senderAPIAvailable: box.senderAPIAvailable, senderID: sender == 0 ? nil : sender,
                                    privateFields: fields,
                                    scrollPhase: type == .scrollWheel ? event.getIntegerValueField(.scrollWheelEventScrollPhase) : nil,
                                    momentumPhase: type == .scrollWheel ? event.getIntegerValueField(.scrollWheelEventMomentumPhase) : nil)
    box.store.observeQuartz(value, acquiredAt: acquired)
    return Unmanaged.passUnretained(event)
}

/// A standalone observer only. No production app types, recognizers, rules,
/// configuration, actions, or synthetic-event paths are linked into this target.
final class LiveCapture {
    private let options: CaptureOptions
    private let environment: CaptureEnvironment
    private let store: CaptureStore
    private var context: CaptureCallbackContext?
    private var monitor: OpaquePointer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
    private var runtime = CaptureRuntime()
    private var devices: [CaptureDevice] = []

    init(options: CaptureOptions) {
        self.options = options
        environment = CaptureHostMetadata.read(reportedRevision: options.reportedRevision)
        store = CaptureStore(options: options)
    }

    func run() -> CaptureReport {
        precondition(Thread.isMainThread)
        startAndObserve()
        // All callback contexts remain strongly held through disable/invalidation
        // and the C bridge's synchronous stop/drain. Snapshot ONLY afterward.
        stopAndDrain()
        return store.report(environment: environment, runtime: runtime, devices: devices)
    }

    private func startAndObserve() {
        runtime.listenPermissionPreflight = CGPreflightListenEventAccess()
        guard runtime.listenPermissionPreflight == true else { store.finish(.missingListenPermission); return }
        if let failure = CaptureSessionGate.afterInstallingObservers(install: { installLifecycleObservers() },
                                                                     read: { readSessionState() },
                                                                     interrupted: { store.isStopped }) {
            store.finish(failure); return
        }
        let senderAvailable = FGEventSenderAPIAvailable()
        runtime.senderAPIAvailable = senderAvailable
        let context = CaptureCallbackContext(store: store, senderAPIAvailable: senderAvailable)
        self.context = context
        store.checkDeadline()
        guard !store.isStopped else { return }
        guard validateSession() else { return }
        let mask = CGEventMask(CaptureStore.eventMask)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: passiveQuartzCallback,
                                          userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            store.finish(.tapCreationFailed); return
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            store.finish(.tapSourceFailed); return
        }
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        store.checkDeadline()
        guard !store.isStopped else { return }
        guard validateSession() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        runtime.quartzTapEnabledElapsedNanoseconds = String(store.elapsed(at: DispatchTime.now().uptimeNanoseconds))
        guard CGEvent.tapIsEnabled(tap: tap) else { store.finish(.tapDisabled); return }
        guard let monitor = FGTouchMonitorCreate(passiveTouchCallback, Unmanaged.passUnretained(context).toOpaque()) else {
            store.finish(.touchCreateFailed); return
        }
        self.monitor = monitor
        store.checkDeadline()
        guard !store.isStopped else { return }
        guard validateSession() else { return }
        let status = FGTouchMonitorStart(monitor)
        runtime.touchStartReturnedElapsedNanoseconds = String(store.elapsed(at: DispatchTime.now().uptimeNanoseconds))
        runtime.touchStatusCode = status
        let count = FGTouchMonitorDeviceCount(monitor)
        guard count <= 256 else { store.finish(.deviceLimit); return }
        for index in 0..<count {
            var device = FGTouchDeviceInfo()
            guard FGTouchMonitorGetDevice(monitor, index, &device) else { store.finish(.touchStartFailed); return }
            // Deliberately never convert or retain product_name from the bridge.
            devices.append(CaptureDevice(opaqueSessionDeviceID: String(device.device_id),
                                         registryEntryID: device.registry_id == 0 ? nil : String(device.registry_id),
                                         multitouchFrameworkDeviceID: device.multitouch_id == 0 ? nil : String(device.multitouch_id),
                                         kindCode: device.kind, classificationEvidenceCode: device.classification_evidence,
                                         vendorID: device.vendor_id == 0 ? nil : device.vendor_id,
                                         productID: device.product_id == 0 ? nil : device.product_id,
                                         builtIn: device.built_in_known ? device.built_in : nil,
                                         started: device.started, startError: device.start_error))
        }
        guard status == FGTouchStatusRunning, !devices.isEmpty else { store.finish(.touchStartFailed); return }
        guard devices.allSatisfy(\.started) else { store.finish(.partialTouchStart); return }
        var nextDevicePoll: UInt64 = 0
        while !store.isStopped {
            store.checkDeadline()
            if store.isStopped { break }
            guard CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else { store.finish(.tapDisabled); break }
            guard CGPreflightListenEventAccess() else { store.finish(.missingListenPermission); break }
            guard validateSession() else { break }
            let elapsed = store.elapsed(at: DispatchTime.now().uptimeNanoseconds)
            if elapsed >= nextDevicePoll {
                guard !FGTouchMonitorDevicesChanged(monitor) else { store.finish(.devicesChanged); break }
                nextDevicePoll = elapsed + 250_000_000
            }
            CFRunLoopRunInMode(.defaultMode, 0.025, false)
        }
    }

    private func readSessionState() -> CaptureSessionSnapshot {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // Apple XNU f6217f891ac0bb64f3d375211650a4c1ff8ca1ea:
        // iokit/IOKit/IOKitKeysPrivate.h identifies this console-session key
        // as OSBoolean. Its absence is NOT accepted as evidence of unlock.
        let snapshot = CaptureSessionSnapshot(onConsole: session?[kCGSessionOnConsoleKey as String],
                                              loginComplete: session?[kCGSessionLoginDoneKey as String],
                                              screenLocked: session?["CGSSessionScreenIsLocked"])
        runtime.consoleSessionActive = snapshot.onConsole == true && snapshot.loginComplete == true
        runtime.sessionScreenLocked = snapshot.screenLocked
        runtime.sessionLockStateSource = "CGSession_dictionary_explicit_CFBoolean_CGSSessionScreenIsLocked_missing_is_unknown"
        return snapshot
    }

    private func validateSession() -> Bool {
        guard let failure = CaptureSessionGate.failure(read: { readSessionState() }, interrupted: { store.isStopped }) else { return true }
        store.finish(failure)
        return false
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, CaptureStore.StopReason)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.screensDidSleepNotification, .sleep),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionLost), (NSWorkspace.willPowerOffNotification, .shutdown)
        ]
        for (name, reason) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [store] _ in
                store.finish(reason)
            })
        }
        // Additional best-effort early lock notice; active-console polling and
        // workspace session/sleep events remain independent fail-closed checks.
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                                           object: nil, queue: nil) { [store] _ in
            store.finish(.sessionLost)
        }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { [store] in store.finish(.interrupted) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func stopAndDrain() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tapSource = nil; tap = nil
        if let monitor {
            FGTouchMonitorStop(monitor) // Drains framework callbacks before releasing context.
            let diagnostics = FGTouchMonitorGetDiagnostics(monitor)
            runtime.bridgeReceivedFrames = diagnostics.received_frames
            runtime.bridgeRejectedFrames = diagnostics.rejected_frames
            FGTouchMonitorDestroy(monitor)
        }
        monitor = nil
        context = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        // Keep default SIGINT/SIGTERM behavior suppressed only until final output
        // is written and this standalone process exits. No live class is used by tests.
    }
}

private enum CaptureHostMetadata {
    static func read(reportedRevision: String?) -> CaptureEnvironment {
        var length = 0
        var osBuild: String?
        if sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0, length <= 256 {
            var bytes = [CChar](repeating: 0, count: length)
            if sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0 {
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                osBuild = String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        var hash: String?
        var hashStatus = "unavailable_executable_read_failed_or_exceeded_256MiB_bound"
        if let executable = Bundle.main.executableURL, let handle = try? FileHandle(forReadingFrom: executable) {
            defer { try? handle.close() }
            do {
                var hasher = SHA256()
                var count = 0
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    count += data.count
                    guard count <= 256 * 1_048_576 else { throw CaptureError("executable_too_large") }
                    hasher.update(data: data)
                }
                hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                hashStatus = "sha256_of_running_executable_file_bytes_not_source_revision_attestation"
            } catch { /* Unknown is explicit, never replaced by the working directory's git SHA. */ }
        }
        return CaptureEnvironment(osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                  exactOSBuild: osBuild, architecture: architecture, executableSHA256: hash,
                                  executableHashStatus: hashStatus, operatorReportedSourceRevision: reportedRevision,
                                  sourceRevisionVerification: reportedRevision == nil ? "unknown" : "operator_reported_unverified")
    }
}
#endif
