import Foundation

/// Experimental coordination only. Nothing in production constructs this type, installs
/// a tap, or supplies a validated physical profile. The native gate denies by default.
///
/// All acquisition, reservation, recognition and action admission share one lock. A future
/// adapter must acquire tickets at callback time, deliver those same tickets in order,
/// and use `takeAction` immediately before dispatch, alongside its ordinary action gate.
/// The lock is never held while executing an action or calling back into an adapter.
public final class NativeRawGestureCoordinator: @unchecked Sendable {
    public struct RawDevice: Equatable, Sendable {
        /// Opaque capture-session identity, NOT an IORegistry sender ID.
        public let deviceID: UInt64
        /// Independently verified raw-device/IORegistry association for this capture
        /// session. Leave nil unless verified; do not substitute a multitouch device ID.
        public let registryID: UInt64?
        public let scope: TouchDeviceScope
        public init(deviceID: UInt64, registryID: UInt64? = nil, scope: TouchDeviceScope = .any) {
            self.deviceID = deviceID; self.registryID = registryID; self.scope = scope
        }
    }
    public struct RawSession: Equatable, Hashable, Sendable {
        public let deviceID: UInt64
        fileprivate let coordinator: UUID
        fileprivate let context: UInt64
        fileprivate let sequence: UInt64
    }
    public struct RawFrameTicket: Sendable {
        public let session: RawSession
        fileprivate let ordinal: UInt64
        fileprivate let frame: TouchFrame
    }
    public enum Action: Equatable, Sendable {
        case raw(deviceID: UInt64, gesture: TouchGesture)
        case native(deviceID: UInt64, actionID: String)
    }
    /// Opaque, single-use admission ticket. Recognizing an action is not dispatching it.
    public struct ActionTicket: Equatable, Sendable {
        public let session: RawSession
        fileprivate let sequence: UInt64
        fileprivate let action: Action
    }
    public struct NativeDecision: Equatable, Sendable {
        public let consume: Bool
        public let action: ActionTicket?
        public let terminal: Bool
        public let requiresIdleReset: Bool
    }

    private struct DeviceState {
        var identity: RawDevice
        var lastTimestamp: Double?
        var hasContacts = false
        var blockedUntilAllUp = false
        var activeSession: RawSession?
        var native = NativeHorizontalSwipeArbitrator()
        var nativeSession: RawSession?
        var nativeAwaitingTerminal = false
    }
    private struct SessionState {
        var recognizer: TouchGestureRecognizer
        var acquiredFrames: UInt64 = 0
        var deliveredFrames: UInt64 = 0
        var acquiredAllUp = false
        // This reservation survives native terminal/cancellation until RAW all-up.
        var nativeOwner: NativeHorizontalSwipeArbitrator.Ownership?
        var pendingAction: ActionTicket?
        var actionDispatched = false
    }

    private let lock = NSLock()
    private let identity = UUID()
    private let configuration: TouchGestureConfiguration
    private var context: UInt64 = 0
    private var sequence: UInt64 = 0
    private var devices: [UInt64: DeviceState] = [:]
    private var sessions: [RawSession: SessionState] = [:]
    private var pendingFrames = 0
    private var unassociatedSenders: Set<UInt64> = []
    private var associationOverflow = false
    private var missingSenderQuarantine = false
    // Bounds devices, undelivered frames, and sessions with unclaimed action tickets.
    private let capacity = 256

    public init(configuration: TouchGestureConfiguration = TouchGestureConfiguration()) {
        self.configuration = configuration
    }

    /// Acquisition and delivery are intentionally separate. Contact state changes NOW,
    /// even when this ticket will sit in the adapter's queue until much later.
    /// Cancelled, malformed, lost or out-of-order input cannot establish an idle boundary.
    public func acquireRawFrame(device: RawDevice, frame: TouchFrame,
                                cancelled: Bool = false) -> RawFrameTicket? {
        lock.lock(); defer { lock.unlock() }
        guard device.deviceID != 0 else { return nil }
        guard devices[device.deviceID] != nil || devices.count < capacity else {
            // Capture-session IDs must be retired by resetCapture after stop/drain.
            // A runaway source must not grow the identity cache indefinitely.
            interruptLocked()
            return nil
        }
        if let old = devices[device.deviceID], old.identity != device {
            interruptDeviceLocked(device.deviceID)
            devices[device.deviceID]?.identity = device
        }
        if devices[device.deviceID] == nil {
            devices[device.deviceID] = DeviceState(identity: device)
        }
        // Association evidence changes at acquisition, before any queued native
        // action can be admitted. Revoke only the now-ambiguous registry family.
        if let registryID = device.registryID {
            let matches = matchingDevicesLocked(registryID)
            if matches.count > 1 { for id in matches { interruptNativeLocked(id) } }
        }
        guard var state = devices[device.deviceID] else { return nil }
        guard !cancelled, Self.valid(frame),
              state.lastTimestamp.map({ frame.timestamp >= $0 }) ?? true else {
            // Even an empty cancellation is not a physical release.
            state.hasContacts = true
            devices[device.deviceID] = state
            interruptDeviceLocked(device.deviceID)
            return nil
        }
        state.lastTimestamp = frame.timestamp
        state.hasContacts = !frame.touches.isEmpty
        if state.blockedUntilAllUp {
            if !state.hasContacts { state.blockedUntilAllUp = false }
            devices[device.deviceID] = state
            if !state.hasContacts, let old = state.nativeSession {
                sessions[old]?.acquiredAllUp = true
                pruneLocked(old)
            }
            return nil
        }
        if state.activeSession == nil {
            guard state.hasContacts else { devices[device.deviceID] = state; return nil }
            sequence &+= 1
            let session = RawSession(deviceID: device.deviceID, coordinator: identity,
                                     context: context, sequence: sequence)
            state.activeSession = session
            sessions[session] = SessionState(recognizer: TouchGestureRecognizer(configuration: configuration))
        }
        devices[device.deviceID] = state
        guard pendingFrames < capacity, sessions.count <= capacity,
              let session = state.activeSession, var raw = sessions[session] else {
            interruptLocked()
            return nil
        }
        let ticket = RawFrameTicket(session: session, ordinal: raw.acquiredFrames, frame: frame)
        raw.acquiredFrames += 1
        raw.acquiredAllUp = !state.hasContacts
        sessions[session] = raw
        pendingFrames += 1
        if !state.hasContacts { devices[device.deviceID]?.activeSession = nil }
        return ticket
    }

    /// Returns a candidate, never permission to execute. Native reservation can revoke
    /// even a raw candidate already queued by this method, until `takeAction` wins.
    public func deliverRawFrame(_ ticket: RawFrameTicket) -> ActionTicket? {
        lock.lock(); defer { lock.unlock() }
        guard current(ticket.session), var raw = sessions[ticket.session] else { return nil }
        guard ticket.ordinal >= raw.deliveredFrames else { return nil } // duplicate
        guard ticket.ordinal == raw.deliveredFrames else {
            interruptDeviceLocked(ticket.session.deviceID)
            return nil
        }
        raw.deliveredFrames += 1
        pendingFrames -= 1
        var action: ActionTicket?
        if raw.nativeOwner == nil, !raw.actionDispatched,
           let gesture = raw.recognizer.process(frame: ticket.frame) {
            action = makeAction(session: ticket.session,
                                action: .raw(deviceID: ticket.session.deviceID, gesture: gesture))
            raw.pendingAction = action
        }
        sessions[ticket.session] = raw
        pruneLocked(ticket.session)
        return action
    }

    /// The only consuming result is produced after reserving the same acquired raw
    /// session under this lock. Missing/ambiguous associations and already-dispatched
    /// raw actions decline the WHOLE native sequence, not just its opening event.
    /// `correlatedRawSession` is an explicit caller attestation that this native opening
    /// belongs to that exact raw gesture, based on independently verified cross-channel
    /// evidence. Possessing a raw ticket, matching registry IDs, or choosing the latest
    /// active session is NOT that evidence. Nil denies opening; this type cannot prove
    /// hardware correlation. Continuing phases keep the original reservation, allow nil,
    /// and quarantine a contradictory nonnil association rather than swapping sessions.
    public func processNative(_ event: NativeHorizontalSwipeEvent,
                              gate: NativeHorizontalSwipeArbitrator.TestGate = .init(),
                              eligibility: NativeHorizontalSwipeArbitrator.Eligibility? = nil,
                              correlatedRawSession: RawSession? = nil) -> NativeDecision {
        lock.lock(); defer { lock.unlock() }
        guard event.sourcePID == 0, event.eventClass == 30,
              event.hasHorizontalFingerprint else { return Self.passing }
        guard let sender = event.senderRegistryID, sender != 0 else {
            missingSenderQuarantine = true
            // A classified horizontal event whose source is lost cannot be assigned
            // to an owned stream. Invalidate admissions; do not guess which device it was.
            invalidateUnassignableNativeLocked()
            return NativeDecision(consume: false, action: nil, terminal: false, requiresIdleReset: true)
        }
        if associationOverflow || missingSenderQuarantine {
            return NativeDecision(consume: false, action: nil, terminal: false, requiresIdleReset: true)
        }
        let terminal = event.phase == .ended || event.phase == .cancelled
        let verifiedTerminal = terminal && event.sourceProvenance == .independentlyVerifiedPhysical &&
            event.progress.isFinite && event.velocityX.isFinite
        if unassociatedSenders.contains(sender) {
            let invalidated = invalidateNativeForSenderLocked(sender)
            // An unverified/synthetic or malformed terminal cannot prove a boundary.
            if verifiedTerminal { unassociatedSenders.remove(sender) }
            return NativeDecision(consume: false, action: nil, terminal: false,
                                  requiresIdleReset: invalidated || (terminal && !verifiedTerminal))
        }
        let matches = matchingDevicesLocked(sender)
        guard matches.count == 1, let deviceID = matches.first else {
            // There is no global private sequence ID. Never silently treat a changed
            // sender as another device while leaving an old queued native action live.
            let invalidated = invalidateNativeForSenderLocked(sender)
            // If opening passed before raw acquisition, later acquisition must not
            // permit a midstream claim (including mayBegin followed by began).
            if !verifiedTerminal {
                if unassociatedSenders.count < capacity { unassociatedSenders.insert(sender) }
                else {
                    associationOverflow = true
                    for id in Array(devices.keys) { interruptNativeLocked(id) }
                }
            }
            return NativeDecision(consume: false, action: nil, terminal: false,
                                  requiresIdleReset: invalidated || !matches.isEmpty || associationOverflow)
        }
        guard var device = devices[deviceID] else { return Self.passing }
        if device.nativeAwaitingTerminal, let correlation = correlatedRawSession,
           correlation != device.nativeSession {
            interruptNativeLocked(deviceID)
            return NativeDecision(consume: false, action: nil, terminal: false, requiresIdleReset: true)
        }
        let candidateSession = device.nativeAwaitingTerminal ? device.nativeSession : correlatedRawSession
        let raw = candidateSession.flatMap { sessions[$0] }
        let canReserve = device.identity.scope == .trackpad && !device.blockedUntilAllUp &&
            candidateSession.map({ current($0) }) == true &&
            device.hasContacts && candidateSession == device.activeSession &&
            raw != nil && raw?.nativeOwner == nil && raw?.actionDispatched == false
        let outcome = device.native.process(event, gate: gate, eligibility: canReserve ? eligibility : nil)
        var action: ActionTicket?
        if outcome.consume, let owner = outcome.ownership {
            let continuing = device.nativeAwaitingTerminal && device.nativeSession == candidateSession &&
                raw?.nativeOwner == owner
            guard let session = candidateSession, var reserved = sessions[session],
                  continuing || canReserve else {
                // Defensive fail-closed path. Never return consume without a reservation.
                device.native.interrupt()
                devices[deviceID] = device
                return NativeDecision(consume: false, action: nil, terminal: false, requiresIdleReset: true)
            }
            if !continuing {
                reserved.nativeOwner = owner
                reserved.pendingAction = nil // revoke an already recognized raw action
                device.nativeSession = session
            }
            device.nativeAwaitingTerminal = !outcome.terminal
            if !device.native.isCurrent(owner) {
                reserved.pendingAction = nil // native cancellation revokes queued action
            } else if let actionID = outcome.actionID, !reserved.actionDispatched, current(session) {
                action = makeAction(session: session, action: .native(deviceID: deviceID, actionID: actionID))
                reserved.pendingAction = action
            }
            sessions[session] = reserved
        }
        devices[deviceID] = device
        if let session = candidateSession { pruneLocked(session) }
        return NativeDecision(consume: outcome.consume, action: action, terminal: outcome.terminal,
                              requiresIdleReset: outcome.requiresIdleReset)
    }

    /// Atomically consumes permission to dispatch ONCE. A raw dispatch that wins first
    /// prevents later native ownership; native reservation that wins first revokes raw.
    /// Returning an action is the irreversible dispatch boundary for this model. A later
    /// cancellation cannot undo it; the caller still applies its ordinary execution gate.
    public func takeAction(_ ticket: ActionTicket) -> Action? {
        lock.lock(); defer { lock.unlock() }
        guard current(ticket.session), var raw = sessions[ticket.session],
              raw.pendingAction == ticket, !raw.actionDispatched else { return nil }
        raw.pendingAction = nil
        let allowed: Bool
        switch ticket.action {
        case .raw:
            allowed = raw.nativeOwner == nil
        case .native:
            if let owner = raw.nativeOwner, let device = devices[ticket.session.deviceID] {
                let matches = matchingDevicesLocked(owner.senderRegistryID)
                let associationValid = matches.count == 1 && matches.first == ticket.session.deviceID &&
                    device.identity.scope == .trackpad
                if !associationValid {
                    for id in Set(matches + [ticket.session.deviceID]) { interruptNativeLocked(id) }
                }
                allowed = associationValid && device.nativeSession == ticket.session && device.native.isCurrent(owner)
            } else { allowed = false }
        }
        if allowed { raw.actionDispatched = true }
        sessions[ticket.session] = raw
        pruneLocked(ticket.session)
        return allowed ? ticket.action : nil
    }

    /// App/configuration change: revoke queued frames/actions and block contacts already
    /// down, but keep an owned native stream's decision through its terminal. Its old
    /// context can never emit another action. Acquisition-time all-up, not delayed frame
    /// delivery, determines whether the next raw gesture may start immediately.
    public func cancelForContextChange() {
        lock.lock(); defer { lock.unlock() }
        context &+= 1
        pendingFrames = 0
        for session in Array(sessions.keys) {
            if let device = devices[session.deviceID], device.nativeAwaitingTerminal,
               device.nativeSession == session, var raw = sessions[session] {
                raw.pendingAction = nil
                raw.deliveredFrames = raw.acquiredFrames // queued frames are now stale
                raw.acquiredAllUp = !device.hasContacts
                sessions[session] = raw
            } else {
                sessions.removeValue(forKey: session)
            }
        }
        for id in Array(devices.keys) {
            devices[id]?.activeSession = nil
            let hasContacts = devices[id]?.hasContacts ?? true
            devices[id]?.blockedUntilAllUp = hasContacts
        }
    }

    /// Capture loss, permission loss, disconnect or an ambiguous stream: invalidate all
    /// pending admissions and quarantine native ownership. Already dispatched work is
    /// not reversible; this is a failed experiment, not a repaired native sequence.
    public func interrupt() {
        lock.lock(); defer { lock.unlock() }
        interruptLocked()
    }

    /// A raw all-up alone does not prove the private native stream idle. The adapter must
    /// independently verify native idle too; a timeout is not such evidence.
    @discardableResult
    public func resetAfterVerifiedIdle(deviceID: UInt64, nativeStreamIsIdle: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // An unidentified stream cannot be reset using one device's idle evidence.
        guard !missingSenderQuarantine, !associationOverflow, nativeStreamIsIdle,
              var device = devices[deviceID],
              !device.hasContacts, !device.blockedUntilAllUp else { return false }
        device.native.resetAfterVerifiedIdle()
        device.nativeAwaitingTerminal = false
        let oldSession = device.nativeSession
        device.nativeSession = nil
        devices[deviceID] = device
        if let oldSession { pruneLocked(oldSession) }
        return true
    }

    /// Recovery for unidentified-source quarantine. Every acquired raw device must
    /// be idle, AND the adapter must independently verify all native streams idle.
    /// A single device's terminal or idle attestation cannot satisfy this contract.
    @discardableResult
    public func resetAfterVerifiedGlobalIdle(nativeStreamsAreIdle: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard nativeStreamsAreIdle,
              devices.values.allSatisfy({ !$0.hasContacts && !$0.blockedUntilAllUp }) else { return false }
        missingSenderQuarantine = false
        associationOverflow = false
        unassociatedSenders.removeAll()
        for id in Array(devices.keys) {
            let oldSession = devices[id]?.nativeSession
            devices[id]?.native.resetAfterVerifiedIdle()
            devices[id]?.nativeAwaitingTerminal = false
            devices[id]?.nativeSession = nil
            if let oldSession { pruneLocked(oldSession) }
        }
        return true
    }

    /// Only for a new capture generation, with the old capture stopped and drained.
    public func resetCapture() {
        lock.lock(); defer { lock.unlock() }
        context &+= 1
        devices.removeAll()
        sessions.removeAll()
        pendingFrames = 0
        unassociatedSenders.removeAll()
        associationOverflow = false
        missingSenderQuarantine = false
    }

    private static let passing = NativeDecision(consume: false, action: nil, terminal: false, requiresIdleReset: false)
    private func current(_ session: RawSession) -> Bool {
        session.coordinator == identity && session.context == context
    }
    private func makeAction(session: RawSession, action: Action) -> ActionTicket {
        sequence &+= 1
        return ActionTicket(session: session, sequence: sequence, action: action)
    }
    private static func valid(_ frame: TouchFrame) -> Bool {
        frame.timestamp.isFinite && frame.touches.count <= 5 &&
            Set(frame.touches.map(\.id)).count == frame.touches.count &&
            frame.touches.allSatisfy { $0.location.isFinite && (0...1).contains($0.location.x) && (0...1).contains($0.location.y) }
    }
    private func matchingDevicesLocked(_ registryID: UInt64) -> [UInt64] {
        devices.keys.filter { devices[$0]?.identity.registryID == registryID }
    }
    private func invalidateNativeForSenderLocked(_ sender: UInt64) -> Bool {
        let matches = matchingDevicesLocked(sender)
        guard !matches.isEmpty else { return invalidateUnassignableNativeLocked() }
        // A safely passing latched stream may acquire a raw-device association
        // later. Do not quarantine that fresh idle arbitrator at its valid terminal.
        let affected = matches.filter { devices[$0]?.nativeSession != nil }
        for id in affected { interruptNativeLocked(id) }
        return !affected.isEmpty
    }
    @discardableResult
    private func invalidateUnassignableNativeLocked() -> Bool {
        let affected = devices.keys.filter { devices[$0]?.nativeSession != nil }
        for id in affected { interruptNativeLocked(id) }
        return !affected.isEmpty
    }
    private func interruptNativeLocked(_ deviceID: UInt64) {
        devices[deviceID]?.native.interrupt()
        if let session = devices[deviceID]?.nativeSession {
            sessions[session]?.pendingAction = nil
            pruneLocked(session)
        }
    }
    private func interruptDeviceLocked(_ deviceID: UInt64) {
        guard var device = devices[deviceID] else { return }
        device.native.interrupt()
        device.nativeAwaitingTerminal = false
        device.nativeSession = nil
        device.activeSession = nil
        device.blockedUntilAllUp = device.hasContacts
        devices[deviceID] = device
        for session in Array(sessions.keys) where session.deviceID == deviceID {
            if let raw = sessions.removeValue(forKey: session) {
                pendingFrames -= Int(raw.acquiredFrames - raw.deliveredFrames)
            }
        }
    }
    private func interruptLocked() {
        context &+= 1
        sessions.removeAll()
        pendingFrames = 0
        for id in Array(devices.keys) {
            devices[id]?.native.interrupt()
            devices[id]?.nativeAwaitingTerminal = false
            devices[id]?.nativeSession = nil
            devices[id]?.activeSession = nil
            let hasContacts = devices[id]?.hasContacts ?? true
            devices[id]?.blockedUntilAllUp = hasContacts
        }
    }
    private func pruneLocked(_ session: RawSession) {
        guard let raw = sessions[session], raw.acquiredAllUp,
              raw.acquiredFrames == raw.deliveredFrames, raw.pendingAction == nil,
              !(devices[session.deviceID]?.nativeSession == session &&
                devices[session.deviceID]?.nativeAwaitingTerminal == true) else { return }
        sessions.removeValue(forKey: session)
    }
}
