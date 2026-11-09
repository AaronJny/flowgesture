import CoreGraphics
import Darwin
import Foundation
import FlowGestureCore
@testable import FlowGestureApp

/// Test-only live transport probe. Never construct this from app routing. Only public,
/// zero-motion scroll events are posted. No private gesture is sent to WindowServer,
/// no physical source is attested, and an admitted action only increments a counter.
final class QuartzReplayProbe {
    typealias Coordinator = NativeRawGestureCoordinator
    enum Stage: String, Codable { case head, admission, tail }

    struct FixtureFields: Codable, Equatable {
        let flagsRawValue: UInt64
        let publicMotionFields: [String: Double]
    }
    struct Observation: Codable {
        let ordinal: Int
        let stage: Stage
        let callbackType: UInt32
        let eventType: UInt32
        let sourceTag: Int64
        let sourcePID: Int64
        let uptime: Double
        let fields: FixtureFields
    }
    struct Delivery: Codable {
        let name: String
        let sourceTag: Int64
        let expectedStages: [Stage]
        var observations: [Observation] = []
        var postedFields: FixtureFields?
    }
    struct Report: Codable {
        let schemaVersion = 2
        let evidenceScope = "synthetic-public-scroll-transport-only"
        let privateGesturePacketsPosted = false
        let provesPhysicalGestureSuppression = false
        let enablesProductionInterception = false
        let tapLocation = "cgSessionEventTap"
        let postLocation = "cgSessionEventTap"
        let runID = UUID().uuidString
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osBuild: String
        let architecture: String
        let revision: String
        let inputMonitoringPreflight: Bool
        let postingPreflight: Bool
        var status = "running"
        var failures: [String] = []
        var deliveries: [Delivery] = []
        var admittedHarmlessCounters = 0
        var tapGenerations = 0
        var invalidatedTaps = 0
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Production admission logic with artificial raw frames. These frames never come
    /// from a physical device. Native claims and dispatch of real actions are absent.
    final class Admission {
        let coordinator = Coordinator()
        let ticket: Coordinator.ActionTicket
        private(set) var count = 0
        init() throws {
            let device = Coordinator.RawDevice(deviceID: 7, scope: .trackpad)
            func frame(_ time: Double, offset: Double) -> TouchFrame {
                TouchFrame(timestamp: time, touches: (1...3).map { id in
                    TouchSample(id: id, location: GesturePoint(x: Double(id) * 0.2 + offset, y: 0.5))
                })
            }
            guard let down = coordinator.acquireRawFrame(device: device, frame: frame(0, offset: 0)),
                  coordinator.deliverRawFrame(down) == nil,
                  let moved = coordinator.acquireRawFrame(device: device, frame: frame(0.1, offset: 0.15)),
                  let ticket = coordinator.deliverRawFrame(moved) else {
                throw Failure("could not prepare the synthetic raw admission fixture")
            }
            self.ticket = ticket
        }
        func take() throws -> Bool {
            guard let action = coordinator.takeAction(ticket) else { return false }
            guard action == .raw(deviceID: 7, gesture: .swipe(fingers: 3, direction: .right)) else {
                throw Failure("unexpected action admitted by the synthetic fixture")
            }
            count += 1
            return true
        }
    }
    private final class TapContext {
        unowned let owner: QuartzReplayProbe
        let stage: Stage
        init(owner: QuartzReplayProbe, stage: Stage) { self.owner = owner; self.stage = stage }
    }
    private struct Tap {
        let port: CFMachPort
        let source: CFRunLoopSource
        // Retain callback context until the port is disabled, removed and invalidated.
        let context: TapContext
    }

    private(set) var report: Report
    private let runLoop = CFRunLoopGetCurrent()
    private var taps: [Tap] = []
    private var fixtures: [Int64: Int] = [:]
    private var admissions: [Int64: Admission] = [:]
    private var ordinal = 0
    private var deadline = 0.0
    private let source: CGEventSource
    private let maximumObservations = 128

    init() throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw Failure("could not create private synthetic event source")
        }
        self.source = source
        var length = 0
        _ = sysctlbyname("kern.osversion", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, length))
        let result = sysctlbyname("kern.osversion", &bytes, &length, nil, 0)
        let osBuild = result == 0 ? String(cString: bytes) : "unavailable"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        report = Report(osBuild: osBuild, architecture: architecture,
                        revision: ProcessInfo.processInfo.environment["FLOWGESTURE_QUARTZ_REPLAY_REVISION"] ?? "unrecorded",
                        inputMonitoringPreflight: CGPreflightListenEventAccess(),
                        postingPreflight: CGPreflightPostEventAccess())
    }

    func run() throws {
        deadline = ProcessInfo.processInfo.systemUptime + 15
        do {
            // Read-only checks. Never ask for permissions or alter TCC on a CI runner.
            guard report.inputMonitoringPreflight, report.postingPreflight else {
                report.status = "blocked"
                throw Failure("existing Input Monitoring and event-posting access are required; no access was requested")
            }
            try install()
            try send("positive-forward-control")
            let first = try Admission()
            try send("one-use-admission-consumes", admission: first, consumed: true)
            try send("duplicate-ticket-forwards", admission: first)
            let cancelled = try Admission()
            cancelled.coordinator.interrupt()
            try send("interrupted-ticket-forwards", admission: cancelled)
            try send("post-consumption-forward-sentinel")
            try drainAndValidate()
            try require(first.count == 1 && cancelled.count == 0, "one-use or interruption admission failed")

            guard let active = taps.first(where: { $0.context.stage == .admission }) else {
                throw Failure("active tap was not installed")
            }
            CGEvent.tapEnable(tap: active.port, enable: false)
            try require(!CGEvent.tapIsEnabled(tap: active.port), "active tap did not disable")
            let disabled = try Admission()
            try send("disabled-tap-forwards", admission: disabled, bypass: true)
            try require(disabled.count == 0, "disabled tap admitted an action")
            CGEvent.tapEnable(tap: active.port, enable: true)
            try require(CGEvent.tapIsEnabled(tap: active.port), "active tap did not re-enable")
            try send("re-enabled-tap-consumes", admission: disabled, consumed: true)
            try send("re-enabled-forward-sentinel")
            try drainAndValidate()

            stop()
            try require(report.invalidatedTaps == 3, "first generation did not completely invalidate")
            try install()
            try send("reinstalled-forward-control")
            let replacement = try Admission()
            try send("reinstalled-admission-consumes", admission: replacement, consumed: true)
            try send("reinstalled-forward-sentinel")
            try drainAndValidate()
            try require(report.admittedHarmlessCounters == 3, "unexpected total harmless admission count")
            stop()
            try require(report.invalidatedTaps == 6 && taps.isEmpty, "final tap teardown was incomplete")
            report.status = "passed"
        } catch {
            stop()
            if report.status != "blocked" { report.status = "failed" }
            report.failures.append(String(describing: error))
            throw error
        }
    }

    func writeReport(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Preserve a rejected non-finite value as diagnostic evidence instead of
        // losing the whole failure report when JSONEncoder encounters it.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func install() throws {
        // Create tail first, then active head, then observing head. This requests a
        // head -> admission -> tail chain at the SAME Quartz location. Observations
        // below must establish that the OS actually used this order for our tags.
        try addTap(stage: .tail, place: .tailAppendEventTap, options: .listenOnly)
        try addTap(stage: .admission, place: .headInsertEventTap, options: .defaultTap)
        try addTap(stage: .head, place: .headInsertEventTap, options: .listenOnly)
        report.tapGenerations += 1
    }

    private func addTap(stage: Stage, place: CGEventTapPlacement, options: CGEventTapOptions) throws {
        let context = TapContext(owner: self, stage: stage)
        let callback: CGEventTapCallBack = { _, type, event, opaque in
            guard let opaque else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<TapContext>.fromOpaque(opaque).takeUnretainedValue()
            return context.owner.receive(stage: context.stage, type: type, event: event)
        }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: place, options: options,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
            report.status = "blocked"
            throw Failure("Quartz refused the \(stage.rawValue) tap; no permissions or settings were changed")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw Failure("could not create \(stage.rawValue) run-loop source")
        }
        taps.append(Tap(port: port, source: source, context: context))
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: port, enable: true)
        try require(CGEvent.tapIsEnabled(tap: port), "\(stage.rawValue) tap is not enabled")
    }

    private func stop() {
        // Never re-enable a tap after an OS timeout. No cancellation/repair event is posted.
        for tap in taps {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(runLoop, tap.source, .defaultMode)
            CFRunLoopSourceInvalidate(tap.source)
            CFMachPortInvalidate(tap.port)
            if !CFMachPortIsValid(tap.port) { report.invalidatedTaps += 1 }
        }
        taps.removeAll()
    }

    private func receive(stage: Stage, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            report.failures.append("\(stage.rawValue) tap disabled by OS (type \(type.rawValue)); experiment failed")
            for admission in admissions.values { admission.coordinator.interrupt() }
            return Unmanaged.passUnretained(event)
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // The sole consuming route requires membership in this run's exact tag set
        // AND all zero-motion public fields. Unrelated input is never recorded.
        guard let index = fixtures[tag] else { return Unmanaged.passUnretained(event) }
        guard ordinal < maximumObservations else {
            if report.failures.isEmpty { report.failures.append("bounded fixture observation storage overflowed") }
            return Unmanaged.passUnretained(event)
        }
        ordinal += 1
        report.deliveries[index].observations.append(Observation(
            ordinal: ordinal, stage: stage, callbackType: type.rawValue, eventType: event.type.rawValue,
            sourceTag: tag, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            uptime: ProcessInfo.processInfo.systemUptime, fields: Self.fixtureFields(event)))
        guard Self.isHarmlessFixture(type: type, event: event) else {
            let reasons = Self.fixtureRejections(type: type, event: event).joined(separator: ", ")
            report.failures.append("\(stage.rawValue) tagged fixture changed: \(reasons)")
            return Unmanaged.passUnretained(event)
        }
        // Use the ACTUAL callback class, not an expected private selector. Public
        // scrolls must never acquire a native-horizontal identity through decoding.
        guard NativeHorizontalSwipeDecoder.decode(type: type, event: event, senderRegistryID: nil) == nil else {
            report.failures.append("public callback was incorrectly decoded as a native gesture")
            return Unmanaged.passUnretained(event)
        }
        if stage == .admission, let admission = admissions[tag] {
            do {
                if try admission.take() {
                    report.admittedHarmlessCounters += 1
                    return nil
                }
            } catch {
                report.failures.append(String(describing: error))
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private static let motionFields: [(name: String, field: CGEventField)] = [
        ("deltaAxis1", .scrollWheelEventDeltaAxis1),
        ("deltaAxis2", .scrollWheelEventDeltaAxis2),
        ("deltaAxis3", .scrollWheelEventDeltaAxis3),
        ("fixedPtDeltaAxis1", .scrollWheelEventFixedPtDeltaAxis1),
        ("fixedPtDeltaAxis2", .scrollWheelEventFixedPtDeltaAxis2),
        ("fixedPtDeltaAxis3", .scrollWheelEventFixedPtDeltaAxis3),
        ("pointDeltaAxis1", .scrollWheelEventPointDeltaAxis1),
        ("pointDeltaAxis2", .scrollWheelEventPointDeltaAxis2),
        ("pointDeltaAxis3", .scrollWheelEventPointDeltaAxis3),
        ("scrollPhase", .scrollWheelEventScrollPhase),
        ("momentumPhase", .scrollWheelEventMomentumPhase)
    ]

    static func fixtureFields(_ event: CGEvent) -> FixtureFields {
        FixtureFields(flagsRawValue: event.flags.rawValue,
                      publicMotionFields: Dictionary(uniqueKeysWithValues: motionFields.map {
                          ($0.name, event.getDoubleValueField($0.field))
                      }))
    }

    /// Diagnostics deliberately use exactly the same strict checks as admission.
    /// No flag normalization or nonzero phase/delta is accepted by this revision.
    static func fixtureRejections(type: CGEventType, event: CGEvent) -> [String] {
        var reasons: [String] = []
        if type != .scrollWheel { reasons.append("callbackType=\(type.rawValue)") }
        if event.type != .scrollWheel { reasons.append("eventType=\(event.type.rawValue)") }
        if !event.flags.isEmpty { reasons.append("flags=0x\(String(event.flags.rawValue, radix: 16))") }
        for (name, field) in motionFields {
            let value = event.getDoubleValueField(field)
            if value != 0 { reasons.append("\(name)=\(value)") }
        }
        return reasons
    }

    static func isHarmlessFixture(type: CGEventType, event: CGEvent) -> Bool {
        fixtureRejections(type: type, event: event).isEmpty
    }

    private func send(_ name: String, admission: Admission? = nil, consumed: Bool = false, bypass: Bool = false) throws {
        try require(report.failures.isEmpty, "tap callback already failed: \(report.failures.joined(separator: "; "))")
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: 0, wheel3: 0) else {
            throw Failure("could not create zero-motion public scroll fixture")
        }
        event.flags = []
        var tag: Int64
        repeat { tag = Int64.random(in: 1...Int64.max) } while fixtures[tag] != nil
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        try require(Self.isHarmlessFixture(type: .scrollWheel, event: event), "fixture was not harmless before posting")
        let index = report.deliveries.count
        let stages: [Stage] = bypass ? [.head, .tail] : consumed ? [.head, .admission] : [.head, .admission, .tail]
        report.deliveries.append(Delivery(name: name, sourceTag: tag, expectedStages: stages,
                                          postedFields: Self.fixtureFields(event)))
        fixtures[tag] = index
        admissions[tag] = admission
        event.post(tap: .cgSessionEventTap)
        let receiptDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
        while report.deliveries[index].observations.count < stages.count && report.failures.isEmpty &&
                ProcessInfo.processInfo.systemUptime < receiptDeadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        try require(report.failures.isEmpty, "callback failure: \(report.failures.joined(separator: "; "))")
        try require(report.deliveries[index].observations.count >= stages.count,
                    "\(name) timed out before its positive callback control; route or source-tag retention unavailable")
    }

    private func drainAndValidate() throws {
        // Every batch ends with a positively observed downstream sentinel. A short
        // bounded drain catches late/duplicate delivery; silence alone NEVER passes.
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 0.1)
        while ProcessInfo.processInfo.systemUptime < until { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        try require(ProcessInfo.processInfo.systemUptime < deadline, "overall live replay deadline exceeded")
        try require(report.failures.isEmpty, "callback failure: \(report.failures.joined(separator: "; "))")
        let errors = Self.validationErrors(report.deliveries)
        try require(errors.isEmpty, errors.joined(separator: "; "))
    }

    static func validationErrors(_ deliveries: [Delivery]) -> [String] {
        guard !deliveries.isEmpty else { return ["no fixture observations"] }
        var errors: [String] = []
        var priorOrdinal = 0
        for delivery in deliveries {
            if delivery.observations.map(\.stage) != delivery.expectedStages {
                errors.append("\(delivery.name): observed callback chain differs from expected forwarding/consumption")
            }
            for observation in delivery.observations {
                if observation.ordinal <= priorOrdinal { errors.append("\(delivery.name): cross-fixture callback ordering changed") }
                priorOrdinal = observation.ordinal
                if observation.callbackType != CGEventType.scrollWheel.rawValue || observation.eventType != CGEventType.scrollWheel.rawValue {
                    errors.append("\(delivery.name): callback/event class mismatch")
                }
                if observation.sourceTag != delivery.sourceTag { errors.append("\(delivery.name): source tag changed") }
            }
        }
        guard let last = deliveries.last, last.expectedStages.last == .tail, last.observations.last?.stage == .tail else {
            errors.append("no downstream positive sentinel after consumption")
            return errors
        }
        return errors
    }

    private func require(_ value: Bool, _ reason: String) throws {
        if !value { throw Failure(reason) }
    }
}
