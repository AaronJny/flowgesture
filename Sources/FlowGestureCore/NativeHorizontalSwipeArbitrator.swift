import Foundation

/// Experimental value-only model. No event tap is installed by this type.
public struct NativeHorizontalSwipeEvent: Equatable, Sendable {
    public enum Phase: Int64, Sendable { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128 }
    /// An adapter assertion, not something inferred from PID zero. Some private
    /// synthetic events can re-enter a tap with PID zero on newer macOS builds.
    public enum SourceProvenance: Equatable, Sendable {
        case unverified
        case independentlyVerifiedPhysical
    }
    public let eventClass: Int64
    public let hidType: Int64
    public let axis: Int64
    public let phaseValue: Int64
    public let senderRegistryID: UInt64?
    public let sourcePID: Int64
    public let sourceProvenance: SourceProvenance
    public let progress: Double
    public let velocityX: Double

    public init(eventClass: Int64, hidType: Int64, axis: Int64, phase: Int64,
                senderRegistryID: UInt64?, sourcePID: Int64 = 0,
                progress: Double = 0, velocityX: Double = 0,
                sourceProvenance: SourceProvenance = .unverified) {
        self.eventClass = eventClass; self.hidType = hidType; self.axis = axis
        self.phaseValue = phase; self.senderRegistryID = senderRegistryID
        self.sourcePID = sourcePID; self.progress = progress; self.velocityX = velocityX
        self.sourceProvenance = sourceProvenance
    }
    public var phase: Phase? { Phase(rawValue: phaseValue) }
    public var hasHorizontalFingerprint: Bool {
        (eventClass == 29 || eventClass == 30) && hidType == 23 && axis == 1
    }
}

public struct NativeHorizontalSwipeArbitrator: Sendable {
    /// This is evidence supplied by a future adapter, not automatic capability detection.
    /// A profile must validate consumption of the entire terminal/companion protocol.
    public struct TestGate: Sendable {
        public var explicitlyEnabled: Bool
        public var runningOSBuild: String
        public var validatedOSBuild: String?
        public var completeStreamValidated: Bool
        public init(explicitlyEnabled: Bool = false, runningOSBuild: String = "",
                    validatedOSBuild: String? = nil, completeStreamValidated: Bool = false) {
            self.explicitlyEnabled = explicitlyEnabled; self.runningOSBuild = runningOSBuild
            self.validatedOSBuild = validatedOSBuild; self.completeStreamValidated = completeStreamValidated
        }
        fileprivate var permitsClaim: Bool {
            explicitlyEnabled && !runningOSBuild.isEmpty && validatedOSBuild == runningOSBuild && completeStreamValidated
        }
    }
    /// Immutable for an owned sequence. The adapter must establish trackpad identity,
    /// app/modifier eligibility and equivalent actions across BOTH 3/4-finger rules.
    public struct Eligibility: Equatable, Sendable {
        public let senderRegistryID: UInt64
        public let leftActionID: String
        public let rightActionID: String
        public let wholeFamilyEligible: Bool
        public init(senderRegistryID: UInt64, leftActionID: String, rightActionID: String,
                    wholeFamilyEligible: Bool) {
            self.senderRegistryID = senderRegistryID; self.leftActionID = leftActionID
            self.rightActionID = rightActionID; self.wholeFamilyEligible = wholeFamilyEligible
        }
        fileprivate var valid: Bool {
            senderRegistryID != 0 && wholeFamilyEligible && !leftActionID.isEmpty && !rightActionID.isEmpty
        }
    }
    public struct Ownership: Equatable, Sendable {
        public let generation: UInt64
        public let senderRegistryID: UInt64
    }
    public struct Outcome: Equatable, Sendable {
        public let consume: Bool
        public let ownership: Ownership?
        public let actionID: String?
        public let terminal: Bool
        public let requiresIdleReset: Bool
    }
    private enum State: Sendable {
        case idle
        case passing(UInt64)
        case owned(Ownership, Eligibility, fired: Bool, sawBegin: Bool)
        case quarantined
    }
    private var state: State = .idle
    private var generation: UInt64 = 0
    private var currentOwnership: Ownership?
    private var claimedBuild: String?
    public init() {}

    /// Timeout, permission loss, disconnect, overflow, or an ambiguous stream invalidates
    /// queued actions. It does not synthesize or repair a native terminal event.
    public mutating func interrupt() { state = .quarantined; currentOwnership = nil }
    /// Call only after independently establishing an idle boundary, never just on a timer.
    public mutating func resetAfterVerifiedIdle() { state = .idle; currentOwnership = nil }
    public func isCurrent(_ ownership: Ownership) -> Bool {
        currentOwnership == ownership
    }
    private var passthrough: Outcome {
        Outcome(consume: false, ownership: nil, actionID: nil, terminal: false,
                requiresIdleReset: { if case .quarantined = state { return true }; return false }())
    }
    private mutating func quarantine() -> Outcome { interrupt(); return passthrough }

    public mutating func process(_ event: NativeHorizontalSwipeEvent, gate: TestGate,
                                 eligibility: Eligibility?) -> Outcome {
        // Nonzero PID is a useful exclusion, but zero is NOT proof of hardware origin.
        guard event.sourcePID == 0 else { return passthrough }
        guard event.eventClass == 29 || event.eventClass == 30 else { return passthrough }
        // Generic class-29 companions lack a proven source/sequence fingerprint. Never
        // consume them, and never use them to claim, advance, or terminate ownership.
        guard event.eventClass == 30 else { return passthrough }
        guard event.hasHorizontalFingerprint else { return passthrough }
        guard event.sourceProvenance == .independentlyVerifiedPhysical else {
            return quarantine()
        }
        guard let sender = event.senderRegistryID, sender != 0,
              let phase = event.phase, event.progress.isFinite, event.velocityX.isFinite else {
            return quarantine()
        }
        if case .quarantined = state { return passthrough }
        let terminal = phase == .ended || phase == .cancelled
        switch state {
        case .idle:
            currentOwnership = nil
            guard phase == .began || phase == .mayBegin else {
                if !terminal { state = .passing(sender) }
                return passthrough
            }
            guard gate.permitsClaim, let eligible = eligibility, eligible.valid,
                  eligible.senderRegistryID == sender else {
                state = .passing(sender)
                return passthrough
            }
            generation &+= 1
            let owner = Ownership(generation: generation, senderRegistryID: sender)
            currentOwnership = owner
            claimedBuild = gate.runningOSBuild
            state = .owned(owner, eligible, fired: false, sawBegin: phase == .began)
            return Outcome(consume: true, ownership: owner, actionID: nil, terminal: false, requiresIdleReset: false)
        case .passing(let originalSender):
            guard sender == originalSender else { return quarantine() }
            if terminal { state = .idle }
            return passthrough
        case .owned(let owner, let frozen, let fired, let sawBegin):
            guard gate.permitsClaim, gate.runningOSBuild == claimedBuild, sender == owner.senderRegistryID else { return quarantine() }
            if phase == .mayBegin || (phase == .began && sawBegin) { return quarantine() }
            if phase == .none { return quarantine() }
            var action: String?
            // Direction follows real native progress, not synthetic posting orientation.
            // Thresholds are experiment policy, not an Apple API contract.
            if !fired && (phase == .changed || phase == .ended) {
                let direction = abs(event.progress) >= 0.15 ? event.progress :
                    (phase == .ended && abs(event.velocityX) >= 200 ? event.velocityX : 0)
                if direction != 0 { action = direction > 0 ? frozen.rightActionID : frozen.leftActionID }
            }
            state = terminal ? .idle : .owned(owner, frozen, fired: fired || action != nil,
                                               sawBegin: sawBegin || phase == .began)
            if phase == .cancelled { currentOwnership = nil }
            return Outcome(consume: true, ownership: owner, actionID: action,
                           terminal: terminal, requiresIdleReset: false)
        case .quarantined:
            return passthrough
        }
    }
}
