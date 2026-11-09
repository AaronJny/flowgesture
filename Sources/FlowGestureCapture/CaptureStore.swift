import Foundation

/// This lock protects bounded storage only. Both callbacks take their timestamp
/// BEFORE this lock and before any dispatch. Append ordinal is not event ordering.
final class CaptureStore {
    enum StopReason: String {
        case durationElapsed = "duration_elapsed"
        case selfTestComplete = "synthetic_self_test_complete"
        case missingListenPermission = "missing_preexisting_listen_permission"
        case inactiveSession = "inactive_or_unavailable_console_session"
        case sessionStateUnknown = "console_session_state_unknown"
        case screenLocked = "console_session_screen_locked"
        case tapCreationFailed = "listen_only_tap_creation_failed"
        case tapSourceFailed = "tap_run_loop_source_failed"
        case tapDisabled = "tap_disabled_or_invalidated"
        case touchCreateFailed = "touch_monitor_allocation_failed"
        case touchStartFailed = "touch_monitor_start_failed"
        case partialTouchStart = "partial_touch_device_start"
        case devicesChanged = "touch_devices_changed"
        case sleep = "sleep_or_display_sleep"
        case sessionLost = "console_session_lost"
        case shutdown = "system_shutdown"
        case interrupted = "signal_interruption"
        case recordLimit = "record_limit_exceeded"
        case deviceLimit = "raw_device_limit_exceeded"
        case invalidRecord = "invalid_raw_record"
        case cancelledRawFrame = "bridge_rejected_raw_frame"
        case sourceTimestampRegression = "raw_source_timestamp_regression"
        case clockRegression = "acquisition_clock_precedes_start"
        case unsupportedPlatform = "live_capture_requires_macos"
        var isFailure: Bool { self != .durationElapsed && self != .selfTestComplete }
    }

    // Public CGEventType codes only: null, mouse buttons/movement/drags,
    // keyboard down/up/modifiers, and tablet pointer/proximity. This matches
    // GestureDiagnostics' public all-events-minus-known-input privacy policy.
    static let excludedQuartzClasses: Set<UInt32> = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 23, 24, 25, 26, 27]
    static let allowedQuartzClasses = Set((UInt32(0)..<64)).subtracting(excludedQuartzClasses)
    static let eventMask = allowedQuartzClasses.reduce(UInt64(0)) { $0 | (UInt64(1) << $1) }
    static let maximumDevices = 256
    static let maximumContacts = 64
    let options: CaptureOptions
    let originNanoseconds: UInt64
    private let durationNanoseconds: UInt64
    private let lock = NSLock()
    private var records: [CaptureRecord] = []
    private var counts = CaptureCounts()
    private var failures: Set<String> = []
    private var stopReason: StopReason?
    private var stoppedElapsed: UInt64 = 0
    private struct RawState {
        var lastSourceTime: Double?
        var allUpObserved = false
        var session: UInt64?
    }
    private var rawStates: [UInt64: RawState] = [:]
    private var nextSession: UInt64 = 1

    init(options: CaptureOptions, originNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        // The parser enforces the public contract; internal fixtures must too.
        precondition(options.duration.isFinite && (0.1...60).contains(options.duration))
        precondition((1...CaptureOptions.recordHardLimit).contains(options.maximumRecords))
        self.options = options
        self.originNanoseconds = originNanoseconds
        durationNanoseconds = UInt64(options.duration * 1_000_000_000)
        records.reserveCapacity(min(options.maximumRecords, 8192))
    }

    func elapsed(at instant: UInt64) -> UInt64 { instant >= originNanoseconds ? instant - originNanoseconds : 0 }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopReason != nil }

    func finish(_ reason: StopReason, at instant: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        finishLocked(reason, elapsed: elapsed(at: instant))
    }
    private func finishLocked(_ reason: StopReason, elapsed: UInt64) {
        if reason.isFailure { failures.insert(reason.rawValue) }
        if stopReason == nil { stopReason = reason; stoppedElapsed = elapsed }
    }
    func checkDeadline(at instant: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        if stopReason == nil && elapsed(at: instant) >= durationNanoseconds {
            finishLocked(.durationElapsed, elapsed: elapsed(at: instant))
        }
    }

    private func admitLocked(at instant: UInt64) -> Bool {
        if stopReason != nil { counts.droppedAfterStop += 1; return false }
        guard instant >= originNanoseconds else {
            counts.droppedInvalidRecord += 1
            finishLocked(.clockRegression, elapsed: 0)
            return false
        }
        let elapsed = elapsed(at: instant)
        guard elapsed < durationNanoseconds else {
            counts.droppedAfterDeadline += 1
            finishLocked(.durationElapsed, elapsed: elapsed)
            return false
        }
        guard records.count < options.maximumRecords else {
            counts.droppedRecordLimit += 1
            finishLocked(.recordLimit, elapsed: elapsed)
            return false
        }
        return true
    }

    func rejectUnexpectedQuartz(acquiredAt instant: UInt64) {
        lock.lock(); defer { lock.unlock() }
        counts.observedQuartz += 1
        guard admitLocked(at: instant) else { return }
        counts.droppedUnexpectedClass += 1
    }

    func observeQuartz(_ fields: CaptureQuartzFields, acquiredAt instant: UInt64) {
        lock.lock(); defer { lock.unlock() }
        counts.observedQuartz += 1
        guard admitLocked(at: instant) else { return }
        guard Self.allowedQuartzClasses.contains(fields.callbackClass) else {
            counts.droppedUnexpectedClass += 1
            return
        }
        if let value = fields.privateFields {
            if value.progress124 == nil || value.velocityX129 == nil { counts.nonfinitePrivateFields += 1 }
            if value.matchesSourceBackedHorizontalFingerprint && value.recognizedPhaseName == nil {
                counts.unknownPrivatePhase += 1
            }
        }
        records.append(CaptureRecord(ordinal: records.count + 1, channel: "quartz",
                                     acquiredElapsedNanoseconds: String(elapsed(at: instant)), quartz: fields, raw: nil))
        counts.storedQuartz += 1
    }

    func observeRaw(deviceID: UInt64, sourceTimestamp: Double, frameNumber: UInt64,
                    bridgeContactCount: Int, contacts: [CaptureContact], cancelled: Bool,
                    acquiredAt instant: UInt64) {
        lock.lock(); defer { lock.unlock() }
        counts.observedRaw += 1
        guard admitLocked(at: instant) else { return }
        let elapsed = elapsed(at: instant)
        guard deviceID != 0, bridgeContactCount >= 0, bridgeContactCount <= Self.maximumContacts,
              contacts.count <= Self.maximumContacts, contacts.count == bridgeContactCount,
              contacts.allSatisfy(\.isValid), Set(contacts.map(\.identifier)).count == contacts.count else {
            counts.droppedInvalidRecord += 1
            finishLocked(.invalidRecord, elapsed: elapsed)
            return
        }
        guard rawStates[deviceID] != nil || rawStates.count < Self.maximumDevices else {
            counts.droppedInvalidRecord += 1
            finishLocked(.deviceLimit, elapsed: elapsed)
            return
        }
        var state = rawStates[deviceID] ?? RawState()
        let validTime = sourceTimestamp.isFinite && sourceTimestamp >= 0
        let regression = validTime && state.lastSourceTime.map { sourceTimestamp < $0 } == true
        let activeCount = contacts.filter(\.isActive).count
        var boundary: String
        var recordSession = state.session
        var deferredFailure: StopReason?
        if cancelled || !validTime || regression {
            boundary = cancelled ? "invalidated_bridge_cancelled" : (regression ? "invalidated_source_time_regression" : "invalidated_source_time")
            state.session = nil; state.allUpObserved = false
            if cancelled { counts.rejectedRawFrames += 1; deferredFailure = .cancelledRawFrame }
            else if regression { counts.timestampRegressions += 1; deferredFailure = .sourceTimestampRegression }
            else { deferredFailure = .invalidRecord }
        } else if activeCount == 0 {
            boundary = state.session == nil ? "observed_all_up" : "session_ended_at_observed_all_up"
            state.session = nil
            state.allUpObserved = true
        } else if state.session == nil {
            recordSession = nextSession; nextSession += 1
            state.session = recordSession
            boundary = state.allUpObserved ? "session_began_after_observed_all_up" : "first_observed_active_boundary_unverified"
            state.allUpObserved = false
        } else {
            boundary = "session_continued"
        }
        if validTime && !cancelled && !regression { state.lastSourceTime = sourceTimestamp }
        rawStates[deviceID] = state
        let raw = CaptureRawFields(opaqueSessionDeviceID: String(deviceID), sourceFrameNumber: String(frameNumber),
                                   bridgeTimestampSeconds: sourceTimestamp.isFinite ? sourceTimestamp : nil,
                                   sourceTimestampStatus: cancelled ? "unknown_bridge_replaces_invalid_source_time_with_zero" :
                                    (validTime ? "bridge_value_clock_not_aligned" : "invalid_source_value"),
                                   sourceTimestampClock: "private_multitouch_seconds_epoch_unverified",
                                   bridgeCancelled: cancelled, bridgeContactCount: bridgeContactCount,
                                   activeContactCount: cancelled || !validTime || regression ? nil : activeCount,
                                   contacts: contacts, observedSessionID: recordSession.map(String.init), boundary: boundary)
        records.append(CaptureRecord(ordinal: records.count + 1, channel: "raw_multitouch",
                                     acquiredElapsedNanoseconds: String(elapsed), quartz: nil, raw: raw))
        counts.storedRaw += 1
        if let deferredFailure { finishLocked(deferredFailure, elapsed: elapsed) }
    }

    func report(environment: CaptureEnvironment, runtime: CaptureRuntime = CaptureRuntime(),
                devices: [CaptureDevice] = []) -> CaptureReport {
        lock.lock(); defer { lock.unlock() }
        precondition(stopReason != nil, "Stop and drain capture before taking the final report")
        precondition(devices.count <= Self.maximumDevices)
        return CaptureReport(
            schemaVersion: 1, mode: options.mode,
            evidenceScope: options.mode == .selfTest ? "synthetic_in_memory_serialization_only" : "passive_callback_observations_only",
            requestedDurationSeconds: options.duration, maximumRecords: options.maximumRecords,
            operatorSelectedScenario: options.scenario, scenarioVerified: false, environment: environment,
            acquisitionClock: "DispatchTime_uptimeNanoseconds_relative_to_single_capture_origin",
            acquisitionPoint: "callback_entry_before_lock_or_main_queue_dispatch_MT_after_existing_C_decode",
            identityNamespaces: ["opaqueSessionDeviceID": "FG_bridge_process_local_session_identity_not_sender_ID",
                                 "registryEntryID": "IORegistry_entry_ID_for_MT_service_zero_is_unknown",
                                 "multitouchFrameworkDeviceID": "private_MTDeviceGetDeviceID_distinct_namespace",
                                 "ioHIDSenderID": "IOHIDEventGetSenderID_retention_and_registry_mapping_unverified",
                                 "observedSessionID": "capture_derived_raw_boundary_only_not_native_correlation"],
            privacy: ["no_keyboard_text_or_known_key_events", "no_mouse_positions_or_known_motion_events",
                      "no_screenshots_app_names_window_names_product_names_or_serials",
                      "no_actions_configuration_loading_event_posting_or_consumption",
                      "no_network_uploads_or_permission_requests", "numeric_device_IDs_and_contact_coordinates_are_local_sensitive_evidence"],
            limitations: ["Source clocks are preserved separately; their epochs are not asserted equal to acquisition time.",
                          "MT acquisition time is Swift callback entry after C bridge validation, not hardware or framework ingress time.",
                          "Records are in lock-admission order; acquisition timestamps do not establish OS causal ordering.",
                          "Quartz zero getters cannot distinguish absent fields from zero. Private semantics are unverified on this OS build.",
                          "PID zero, a scenario label, and numeric ID equality never establish physical origin or raw/native session association.",
                          "Raw boundary labels describe observed states 3/4 only; startup, loss, and last active contacts leave boundaries unproven.",
                          "The C bridge clamps slight coordinate overshoot, omits quality here, and sanitizes rejected frames; original rejected payload is unavailable.",
                          "Dropped counts cover this collector only. Upstream loss, taps earlier in the chain, and invisible event classes remain unknown even when counts are zero.",
                          "Only one listen-only session tap is observed. Exact mask and exclusions are recorded; unknown types including 61/62 are metadata only. Complete stream visibility, companion requirements, and native suppression are not proven.",
                          "No actions, overlays, application context, synthetic events, native interception, or physical suppression validation are performed.",
                          "The reported source revision is caller supplied, not a verified mapping from source to executable. The binary hash identifies bytes when available."],
            tapLocation: "cgSessionEventTap_tailAppendEventTap", tapOptions: "listenOnly",
            eventClassesRequested: Self.allowedQuartzClasses.sorted(), eventClassesExcluded: Self.excludedQuartzClasses.sorted(),
            eventMaskHex: String(format: "0x%016llx", Self.eventMask), outcome: failures.isEmpty ? "completed_unverified_evidence" : "failed_incomplete_evidence",
            stopReason: stopReason!.rawValue, stoppedElapsedNanoseconds: String(stoppedElapsed),
            failureReasons: failures.sorted(), runtime: runtime, devices: devices, counts: counts, records: records)
    }
}
