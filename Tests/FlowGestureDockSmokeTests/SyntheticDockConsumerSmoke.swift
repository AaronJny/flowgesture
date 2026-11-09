import AppKit
import CoreGraphics
import Darwin
import Foundation

// Legacy packet field recipe adapted from InstantSpaceSwitcher, pinned to:
// https://github.com/jurplel/InstantSpaceSwitcher/blob/2b883a995d1c81fbc6d75704372a6a0b546bb1ff/Sources/ISS/ISS.c#L572-L605
// Progress: lines 484-488; default velocity: line 77. No macOS 27 format is used.
//
// MIT License
// Copyright (c) 2026 jurplel
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

enum DockSmokeFixture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    enum Mode: String, Codable { case forward, consume }
    enum Direction: Int, Codable { case left = -1, right = 1 }
    struct Fields: Codable, Equatable {
        let eventType: UInt32
        let tag: Int64
        let pid: Int64
        let flags: UInt64
        let selector: Int64
        let hidType: Int64
        let axis: Int64
        let phase: Int64
        let progress: Double
        let velocityX: Double
        let velocityY: Double
        init(_ event: CGEvent) {
            eventType = event.type.rawValue
            tag = event.getIntegerValueField(.eventSourceUserData)
            pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            flags = event.flags.rawValue
            selector = event.getIntegerValueField(CGEventField(rawValue: 55)!)
            hidType = event.getIntegerValueField(CGEventField(rawValue: 110)!)
            axis = event.getIntegerValueField(CGEventField(rawValue: 123)!)
            phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
            progress = event.getDoubleValueField(CGEventField(rawValue: 124)!)
            velocityX = event.getDoubleValueField(CGEventField(rawValue: 129)!)
            velocityY = event.getDoubleValueField(CGEventField(rawValue: 130)!)
        }
        func matchesPayload(_ posted: Fields) -> Bool {
            // Flags are separately calibrated using the first forward-only round.
            eventType == posted.eventType && tag == posted.tag && pid == posted.pid &&
                selector == posted.selector && hidType == posted.hidType && axis == posted.axis &&
                phase == posted.phase && progress == posted.progress &&
                velocityX == posted.velocityX && velocityY == posted.velocityY
        }
    }
    struct Packet {
        let event: CGEvent
        let posted: Fields
    }
    struct Batch {
        let name: String
        let direction: Direction
        let mode: Mode
        let packets: [Packet]
        /// Deliberately nonthrowing with no stop predicate. Once the first packet
        /// is posted, callback errors must NEVER omit this batch's ended packet.
        /// This guarantees our posts, not atomic delivery through downstream taps.
        func postAll(_ post: (CGEvent) -> Void) {
            for packet in packets { post(packet.event) }
        }
    }

    static func admissionReason(environment: [String: String], majorVersion: Int) -> String? {
        guard environment["FLOWGESTURE_RUN_DOCK_SMOKE"] == "1" else { return "explicit opt-in is required" }
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            return "only a dedicated disposable GitHub-hosted runner is allowed"
        }
        guard majorVersion == 15 || majorVersion == 26 else { return "legacy packet recipe is restricted to macOS 15 and 26" }
        return nil
    }

    static func prepare(name: String, direction: Direction, mode: Mode, tags: [Int64]) throws -> Batch {
        guard tags.count == 3, Set(tags).count == 3, tags.allSatisfy({ $0 > 0 }) else {
            throw Failure("three unique positive source tags are required before posting")
        }
        let sign = Double(direction.rawValue)
        let packets = try [Int64(1), 2, 4].enumerated().map { index, phase -> Packet in
            guard let event = CGEvent(source: nil) else { throw Failure("cannot construct complete legacy sequence") }
            event.flags = []
            for (field, value) in [(UInt32(55), Int64(30)), (110, 23), (123, 1), (132, phase)] {
                event.setIntegerValueField(CGEventField(rawValue: field)!, value: value)
            }
            event.setDoubleValueField(CGEventField(rawValue: 124)!, value: sign * 0.000016)
            event.setDoubleValueField(CGEventField(rawValue: 129)!, value: sign * 2000)
            event.setDoubleValueField(CGEventField(rawValue: 130)!, value: sign * 2000)
            event.setIntegerValueField(.eventSourceUserData, value: tags[index])
            let fields = Fields(event)
            guard fields.eventType == 30, fields.selector == 30, fields.hidType == 23,
                  fields.axis == 1, fields.phase == phase, fields.flags == 0,
                  fields.pid == Int64(getpid()), fields.tag == tags[index],
                  fields.progress == sign * 0.000016, fields.velocityX == sign * 2000,
                  fields.velocityY == sign * 2000 else { throw Failure("legacy packet construction did not preserve every required field") }
            return Packet(event: event, posted: fields)
        }
        return Batch(name: name, direction: direction, mode: mode, packets: packets)
    }
}

/// Independent TEST-ONLY tap path. It imports neither production routing nor the
/// native coordinator/decoder and never labels any packet physically sourced.
final class DockSmokeTapChain {
    enum Stage: String, Codable, Hashable { case head, filter, tail }
    struct TagOrder {
        private var pending: [Stage: [Int64]] = [:]
        var isDrained: Bool { pending.values.allSatisfy(\.isEmpty) }
        mutating func append(tags: [Int64], mode: DockSmokeFixture.Mode) throws {
            guard isDrained else { throw DockSmokeFixture.Failure("another sequence is still in flight") }
            pending[.head] = tags
            pending[.filter] = tags
            pending[.tail] = mode == .forward ? tags : []
        }
        mutating func takeNext(stage: Stage, tag: Int64) -> Bool {
            guard pending[stage]?.first == tag else { return false }
            pending[stage]?.removeFirst()
            return true
        }
    }
    struct Receipt: Codable {
        let ordinal: Int
        let stage: Stage
        let callbackType: UInt32
        let uptime: Double
        let fields: DockSmokeFixture.Fields
        let matchesPostedPayload: Bool
        let consumed: Bool
    }
    private final class Context {
        unowned let owner: DockSmokeTapChain
        let stage: Stage
        init(_ owner: DockSmokeTapChain, _ stage: Stage) { self.owner = owner; self.stage = stage }
    }
    private struct Tap {
        let port: CFMachPort
        let source: CFRunLoopSource
        let context: Context
    }
    private var taps: [Tap] = []
    private var expected: [Int64: (DockSmokeFixture.Fields, DockSmokeFixture.Mode)] = [:]
    private var tagOrder = TagOrder()
    private(set) var receipts: [Receipt] = []
    private(set) var failures: [String] = []
    private(set) var invalidatedTaps = 0
    private(set) var calibratedFlags: UInt64?

    func install() throws {
        let specifications: [(Stage, CGEventTapPlacement, CGEventTapOptions)] = [
            (.tail, .tailAppendEventTap, .listenOnly),
            (.filter, .headInsertEventTap, .defaultTap),
            (.head, .headInsertEventTap, .listenOnly)
        ]
        for (stage, place, option) in specifications {
            let context = Context(self, stage)
            let callback: CGEventTapCallBack = { _, type, event, opaque in
                guard let opaque else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
                return context.owner.receive(context.stage, type, event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: place, options: option,
                eventsOfInterest: CGEventMask(1) << 30, callback: callback,
                userInfo: Unmanaged.passUnretained(context).toOpaque()) else {
                throw DockSmokeFixture.Failure("private-class test tap unavailable; no access was requested")
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                throw DockSmokeFixture.Failure("could not create test tap run-loop source")
            }
            taps.append(Tap(port: port, source: source, context: context))
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            guard CGEvent.tapIsEnabled(tap: port) else { throw DockSmokeFixture.Failure("test tap did not enable") }
        }
    }
    func arm(_ batch: DockSmokeFixture.Batch) throws {
        guard failures.isEmpty, taps.count == 3, taps.allSatisfy({ CGEvent.tapIsEnabled(tap: $0.port) }),
              batch.mode == .forward || calibratedFlags != nil,
              batch.packets.allSatisfy({ expected[$0.posted.tag] == nil }) else {
            throw DockSmokeFixture.Failure("cannot begin another sequence after a tap/source failure or without forward calibration")
        }
        try tagOrder.append(tags: batch.packets.map { $0.posted.tag }, mode: batch.mode)
        for packet in batch.packets { expected[packet.posted.tag] = (packet.posted, batch.mode) }
    }
    private func receive(_ stage: Stage, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failures.append("test tap \(stage.rawValue) disabled (type \(type.rawValue)); partial downstream sequence is possible")
            return Unmanaged.passUnretained(event) // Never re-enable from this callback.
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        guard let (posted, mode) = expected[tag] else { return Unmanaged.passUnretained(event) }
        guard receipts.count < 64 else {
            failures.append("bounded packet audit overflowed")
            return Unmanaged.passUnretained(event)
        }
        let fields = DockSmokeFixture.Fields(event)
        // 0x20000000 is only the exact opaque transport bit observed in the
        // public replay. It never establishes origin. The first forward round
        // must independently freeze the exact value for THIS private fixture.
        let flagsOK = (fields.flags == 0 || fields.flags == 0x20000000) &&
            (calibratedFlags == nil || calibratedFlags == fields.flags)
        let inOrder = tagOrder.takeNext(stage: stage, tag: tag)
        let matches = type.rawValue == 30 && fields.matchesPayload(posted) && flagsOK && inOrder
        let consume = matches && mode == .consume && stage == .filter && calibratedFlags != nil
        receipts.append(Receipt(ordinal: receipts.count + 1, stage: stage,
            callbackType: type.rawValue, uptime: ProcessInfo.processInfo.systemUptime,
            fields: fields, matchesPostedPayload: matches, consumed: consume))
        if !matches { failures.append("tagged packet payload/PID/type/flags/order changed or duplicated; partial downstream sequence is possible") }
        // The batch's disposition never changes after began. A failure blocks the
        // NEXT batch; it does not stop posting the remaining prepared phases.
        return consume ? nil : Unmanaged.passUnretained(event)
    }
    func verify(_ batch: DockSmokeFixture.Batch) throws {
        guard failures.isEmpty else { throw DockSmokeFixture.Failure(failures.joined(separator: "; ")) }
        let tags = Set(batch.packets.map { $0.posted.tag })
        let actual = receipts.filter { tags.contains($0.fields.tag) }
        let stages: [Stage] = batch.mode == .consume ? [.head, .filter] : [.head, .filter, .tail]
        let orderedTags = batch.packets.map { $0.posted.tag }
        // Separate Mach-port sources can be serviced in different relative order.
        // Preserve the actual global audit, require exact 1/2/4 order within EACH
        // tap, and never mistake callback scheduling order for WindowServer order.
        guard actual.count == orderedTags.count * stages.count,
              actual.allSatisfy({ $0.matchesPostedPayload }),
              stages.allSatisfy({ stage in actual.filter { $0.stage == stage }.map { $0.fields.tag } == orderedTags }),
              batch.mode != .consume || actual.allSatisfy({ $0.stage != .tail }) else {
            throw DockSmokeFixture.Failure("complete began/changed/ended per-tap order or source tags were not retained")
        }
        if calibratedFlags == nil {
            guard batch.mode == .forward, let flags = actual.first?.fields.flags,
                  actual.allSatisfy({ $0.fields.flags == flags }) else {
                throw DockSmokeFixture.Failure("forward control did not establish a consistent transport envelope")
            }
            calibratedFlags = flags
        }
    }
    func stop() {
        for tap in taps {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            CFRunLoopSourceInvalidate(tap.source)
            CFMachPortInvalidate(tap.port)
            if !CFMachPortIsValid(tap.port) { invalidatedTaps += 1 }
        }
        taps.removeAll()
    }
}

@MainActor
final class SyntheticDockConsumerSmoke: NSObject {
    struct WindowState: Codable {
        let stage: String
        let uptime: Double
        let fullscreenWindowOnActiveSpace: Bool
        let anchorWindowOnActiveSpace: Bool
        let fullscreenWindowVisible: Bool
        let anchorWindowVisible: Bool
        let spaceNotifications: Int
    }
    struct Round: Codable {
        let name: String
        let mode: DockSmokeFixture.Mode
        let direction: DockSmokeFixture.Direction
        let postedFields: [DockSmokeFixture.Fields]
        let before: WindowState
        var postedPhaseCount = 0
        var after: WindowState?
        var passed = false
    }
    struct Report: Codable {
        let schemaVersion = 1
        let evidenceScope = "synthetic-Dock-consumer-smoke-only"
        let provesPhysicalSuppression = false
        let provesRawNativeCorrelation = false
        let provesCompleteHardwareStream = false
        let enablesProductionInterception = false
        let recipeSource = "https://github.com/jurplel/InstantSpaceSwitcher/blob/2b883a995d1c81fbc6d75704372a6a0b546bb1ff/Sources/ISS/ISS.c"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osBuild = SyntheticDockConsumerSmoke.osBuild()
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let revision = ProcessInfo.processInfo.environment["FLOWGESTURE_DOCK_SMOKE_REVISION"] ?? "unrecorded"
        var status = "running"
        var failures: [String] = []
        var rounds: [Round] = []
        var spaceChanges: [WindowState] = []
        var fullscreenEnteredAt: Double?
        var fullscreenSettled: WindowState?
        var cleanupBefore: WindowState?
        var cleanupAfter: WindowState?
        var ownedWindowNumbers: [Int] = []
        var displayIDs: [UInt32] = []
        var receipts: [DockSmokeTapChain.Receipt] = []
        var calibratedFlags: UInt64?
        var invalidatedTaps = 0
        var ownedWindowsClosed = false
        var discardRunnerSession = true
    }
    private(set) var report = Report()
    private let chain = DockSmokeTapChain()
    private var anchor: NSWindow?
    private var fullscreen: NSWindow?
    private var fullScreenEntered = false
    private var notificationCount = 0
    private var lastSpaceChange = 0.0
    private var overallDeadline = 0.0
    private var usedTags: Set<Int64> = []
    private var didCleanup = false
    private var currentStage = "setup"

    nonisolated private static func osBuild() -> String {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: length)
        return sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0 ? String(cString: bytes) : "unavailable"
    }

    func run() throws {
        overallDeadline = ProcessInfo.processInfo.systemUptime + 60
        do {
            guard Thread.isMainThread else { throw DockSmokeFixture.Failure("AppKit smoke must run on the main thread") }
            if let reason = DockSmokeFixture.admissionReason(environment: ProcessInfo.processInfo.environment,
                majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
                throw DockSmokeFixture.Failure(reason)
            }
            guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
                throw DockSmokeFixture.Failure("existing input/post access is absent; no permissions were requested")
            }
            _ = NSApplication.shared
            guard NSScreen.screens.count == 1, NSApp.windows.isEmpty else {
                throw DockSmokeFixture.Failure("dedicated single-display session with no existing test-app windows is required")
            }
            report.displayIDs = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(enteredFullscreen),
                name: NSWindow.didEnterFullScreenNotification, object: nil)
            anchor = makeWindow("Dock smoke: desktop anchor", color: .systemBlue)
            anchor?.collectionBehavior = [.managed, .fullScreenNone]
            anchor?.makeKeyAndOrderFront(nil)
            fullscreen = makeWindow("Dock smoke: owned fullscreen Space", color: .systemGreen)
            fullscreen?.collectionBehavior = [.managed, .fullScreenPrimary]
            report.ownedWindowNumbers = [anchor, fullscreen].compactMap { $0?.windowNumber }
            fullscreen?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try wait(timeout: 5) { NSApp.isActive && self.fullscreen?.isKeyWindow == true }
            fullscreen?.toggleFullScreen(nil)
            try wait(timeout: 12, stable: 1) {
                self.fullScreenEntered && self.notificationCount > 0 && self.atFullscreen &&
                    ProcessInfo.processInfo.systemUptime - self.lastSpaceChange >= 1
            }
            report.fullscreenSettled = state()
            try chain.install()
            try round("forward-left-positive", direction: .left, mode: .forward, startsFullscreen: true)
            try round("forward-right-restore", direction: .right, mode: .forward, startsFullscreen: false)
            try round("consume-left-no-movement", direction: .left, mode: .consume, startsFullscreen: true)
            try round("forward-left-after-consumption", direction: .left, mode: .forward, startsFullscreen: true)
            cleanup()
            guard report.invalidatedTaps == 3, report.ownedWindowsClosed, report.failures.isEmpty else {
                throw DockSmokeFixture.Failure("owned fixture cleanup was incomplete")
            }
            report.status = "passed"
        } catch {
            report.failures.append(String(describing: error))
            report.status = "failed"
            cleanup()
            throw error
        }
    }
    private var atFullscreen: Bool {
        fullscreen?.isOnActiveSpace == true && anchor?.isOnActiveSpace == false &&
            fullscreen?.styleMask.contains(.fullScreen) == true
    }
    private var atDesktop: Bool {
        fullscreen?.isOnActiveSpace == false && anchor?.isOnActiveSpace == true
    }
    private func makeWindow(_ title: String, color: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 620, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = color
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
    @objc private func spaceChanged(_ notification: Notification) {
        notificationCount += 1
        lastSpaceChange = ProcessInfo.processInfo.systemUptime
        if report.spaceChanges.count < 32 { report.spaceChanges.append(state()) }
        else { report.failures.append("space notification evidence overflowed") }
    }
    @objc private func enteredFullscreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreen else { return }
        fullScreenEntered = true
        report.fullscreenEnteredAt = ProcessInfo.processInfo.systemUptime
    }
    private func state() -> WindowState {
        WindowState(stage: currentStage, uptime: ProcessInfo.processInfo.systemUptime,
            fullscreenWindowOnActiveSpace: fullscreen?.isOnActiveSpace ?? false,
            anchorWindowOnActiveSpace: anchor?.isOnActiveSpace ?? false,
            fullscreenWindowVisible: fullscreen?.isVisible ?? false,
            anchorWindowVisible: anchor?.isVisible ?? false,
            spaceNotifications: notificationCount)
    }
    private func newTag() -> Int64 {
        var tag: Int64
        repeat { tag = Int64.random(in: 1...Int64.max) } while usedTags.contains(tag)
        usedTags.insert(tag)
        return tag
    }
    private func round(_ name: String, direction: DockSmokeFixture.Direction, mode: DockSmokeFixture.Mode,
                       startsFullscreen: Bool) throws {
        guard report.failures.isEmpty, chain.failures.isEmpty, startsFullscreen ? atFullscreen : atDesktop else {
            throw DockSmokeFixture.Failure("round precondition/source state failed; no further gesture was posted")
        }
        currentStage = name
        let batch = try DockSmokeFixture.prepare(name: name, direction: direction, mode: mode,
                                                 tags: [newTag(), newTag(), newTag()])
        try chain.arm(batch)
        let before = state()
        let index = report.rounds.count
        report.rounds.append(Round(name: name, mode: mode, direction: direction,
                                   postedFields: batch.packets.map(\.posted), before: before))
        defer { report.rounds[index].after = state() }
        // All allocations/field validation are done. No throw, conditional break,
        // mode change or run-loop pumping can truncate this began/changed/ended.
        batch.postAll { event in
            event.post(tap: .cgSessionEventTap)
            report.rounds[index].postedPhaseCount += 1
        }
        if mode == .consume {
            let until = min(overallDeadline, ProcessInfo.processInfo.systemUptime + 2)
            while ProcessInfo.processInfo.systemUptime < until {
                pump()
                guard atFullscreen, notificationCount == before.spaceNotifications,
                      chain.failures.isEmpty, report.failures.isEmpty else {
                    throw DockSmokeFixture.Failure("consumed synthetic sequence moved Space or lost tap/source integrity; runner must be discarded")
                }
            }
        } else {
            try wait(timeout: 8, stable: 1) {
                self.notificationCount > before.spaceNotifications && (startsFullscreen ? self.atDesktop : self.atFullscreen) &&
                    ProcessInfo.processInfo.systemUptime - self.lastSpaceChange >= 1
            }
        }
        // A later round is never used to repair or diagnose an uncertain stream.
        try chain.verify(batch)
        guard chain.failures.isEmpty, report.failures.isEmpty else { throw DockSmokeFixture.Failure("stream failed before next round") }
        report.rounds[index].after = state()
        report.rounds[index].passed = true
    }
    private func wait(timeout: Double, stable: Double = 0, condition: () -> Bool) throws {
        let end = min(overallDeadline, ProcessInfo.processInfo.systemUptime + timeout)
        var matchingSince: Double?
        while ProcessInfo.processInfo.systemUptime < end {
            pump()
            guard chain.failures.isEmpty, report.failures.isEmpty else {
                throw DockSmokeFixture.Failure("callback/notification failure; next sequence forbidden")
            }
            let now = ProcessInfo.processInfo.systemUptime
            if condition() {
                if matchingSince == nil { matchingSince = now }
                if now - (matchingSince ?? now) >= stable { return }
            } else { matchingSince = nil }
        }
        throw DockSmokeFixture.Failure("window/Space positive control did not become stably true before deadline")
    }
    private func pump() {
        CFRunLoopRunInMode(.defaultMode, 0.01, false)
        // XCTest does not run NSApplication.run(). Deliver only the AppKit queue
        // needed by our own window lifecycle; never synthesize keyboard shortcuts.
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        currentStage = "cleanup"
        report.cleanupBefore = state()
        chain.stop()
        report.receipts = chain.receipts
        report.calibratedFlags = chain.calibratedFlags
        report.invalidatedTaps = chain.invalidatedTaps
        report.failures.append(contentsOf: chain.failures)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        fullscreen?.close()
        anchor?.close()
        report.ownedWindowsClosed = (fullscreen?.isVisible != true && anchor?.isVisible != true)
        report.cleanupAfter = state()
        fullscreen = nil
        anchor = nil
        // No Dock restart, guessed cancellation packet, security change, window
        // movement to an arbitrary Space, or private Space-management API.
    }
    func writeReport(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
