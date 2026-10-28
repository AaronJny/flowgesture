import AppKit
import ApplicationServices
import FlowGestureCore

/// The event callback only classifies/matches input. Actions execute after returning to the run loop.
final class EventEngine {
    static let syntheticTag: Int64 = 0x464C4F5747455354
    var onStatus: ((String) -> Void)?
    var onTouchStatus: ((String) -> Void)?
    var onTouchDevices: (([TouchDeviceInfo]) -> Void)?
    var onDiagnosticStatus: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var book = RuleBook()
    private var configurationGeneration: UInt64 = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let executor = ActionExecutor()
    private let overlay = StrokeOverlay()
    private let touch = TouchMonitor()
    private let diagnostics = GestureDiagnostics()
    private var blockedTouchDevices: Set<UInt64> = []
    private var touchRecognizers: [UInt64: TouchGestureRecognizer] = [:]
    private var pending: [CGEvent] = []
    private var points: [GesturePoint] = []
    private var pendingButton: MouseButton?
    private var discardedButton: MouseButton?
    private var clickResolver = ClickSequenceResolver()
    private var clickTimer: Timer?
    private var clickEvents: [CGEvent] = []
    private var clickButton: MouseButton?
    private var clickModifiers: ModifierKeys = []
    private var clickApp: String?
    private var pendingModifiers: ModifierKeys = []
    private var pendingApp: String?
    private var corner: ScreenCorner?
    private var scrollTimer: Timer?
    private var smoother = ScrollSmoother()
    private var scrollFlags: CGEventFlags = []
    private var scrollSource: UInt64?
    private var scrollLocation = CGPoint.zero
    private var workspaceObservers: [NSObjectProtocol] = []
    var isRunning: Bool { tap != nil }

    init() {
        executor.onError = { [weak self] in self?.onError?($0) }
        diagnostics.onStatus = { [weak self] in self?.onDiagnosticStatus?($0) }
        touch.onFrame = { [weak self] frame in
            guard let self, self.isRunning else { return }
            self.diagnostics.recordTouchFrame(deviceID: frame.deviceID, contacts: frame.activeContacts.count, cancelled: frame.cancelled)
            guard let device = self.touch.devices.first(where: { $0.deviceID == frame.deviceID }), device.kind == .trackpad || device.kind == .mouse else { return }
            if self.blockedTouchDevices.contains(frame.deviceID) {
                if frame.activeContacts.isEmpty { self.blockedTouchDevices.remove(frame.deviceID) }
                return
            }
            var recognizer = self.touchRecognizers[frame.deviceID] ?? TouchGestureRecognizer(configuration: TouchGestureConfiguration(includesDiagonalSwipes: true))
            if frame.cancelled { self.touchRecognizers.removeValue(forKey: frame.deviceID); self.blockedTouchDevices.insert(frame.deviceID); return }
            let samples = frame.activeContacts.map {
                TouchSample(id: Int($0.id), location: GesturePoint(x: $0.x, y: $0.y))
            }
            if let gesture = recognizer.process(frame: TouchFrame(timestamp: frame.timestamp, touches: samples)) {
                switch gesture {
                case .tap(let fingers): self.diagnostics.recordRecognition("tap.\(fingers)")
                case .swipe(let fingers, let direction): self.diagnostics.recordRecognition("swipe.\(fingers).\(direction.rawValue)")
                case .pinch(let direction): self.diagnostics.recordRecognition("pinch.\(direction.rawValue)")
                }
                _ = self.fire(.touch(TouchGestureTrigger(gesture: gesture, modifiers: Self.modifiers(CGEventSource.flagsState(.combinedSessionState)), device: device.kind == .trackpad ? .trackpad : .mouse)))
            }
            self.touchRecognizers[frame.deviceID] = recognizer
        }
        touch.onReset = { [weak self] in self?.touchRecognizers.removeAll(); self?.blockedTouchDevices.removeAll() }
        touch.onStatus = { [weak self] status in self?.onTouchStatus?("\(status.message) · \(status.startedDevices)/\(status.enumeratedDevices) devices · \(status.receivedFrames) frames · \(status.rejectedFrames) rejected") }
        touch.onDevicesChanged = { [weak self] in self?.onTouchDevices?($0) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.blockedTouchDevices.formUnion(self.touchRecognizers.keys)
            self.touchRecognizers.removeAll()
            self.smoother.reset()
            self.cancelPending(); self.completeClicks(count: nil, replay: false)
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.stop(); self.start()
        })
    }
    deinit { stop(); workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func configure(_ configuration: RuleBook) {
        configurationGeneration &+= 1; executor.cancelPending()
        flushPending(); completeClicks(count: nil, replay: true); blockedTouchDevices.formUnion(touchRecognizers.keys); touchRecognizers.removeAll()
        book = configuration; smoother.reset()
    }
    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { onStatus?("Accessibility permission required / 需要辅助功能权限"); return }
        let types: [CGEventType] = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel,.keyDown,.keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onStatus?("Cannot start input monitor / 无法启动输入监听"); return
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        touch.start()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tickScroll() }
        RunLoop.main.add(scrollTimer!, forMode: .common)
        onStatus?("Running / 运行中")
    }
    func stop() {
        diagnostics.stop()
        configurationGeneration &+= 1; executor.cancelPending()
        flushPending(); completeClicks(count: nil, replay: true)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        touch.stop(); touchRecognizers.removeAll()
        scrollTimer?.invalidate(); scrollTimer = nil; smoother.reset()
        swallowedKeys.removeAll(); discardedButton = nil; corner = nil; scrollSource = nil
        onStatus?("Paused / 已暂停")
    }
    func startGestureDiagnostics() {
        guard isRunning else { onError?("Enable monitoring and grant permissions before starting diagnostics / 请先授予权限并启用监听"); return }
        diagnostics.start(maxDuration: 60)
    }
    func stopGestureDiagnostics() { diagnostics.stop() }
    func gestureDiagnosticData() throws -> Data { try diagnostics.snapshotData() }
    func refreshDiagnostics() { touch.refreshDiagnostics() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private var swallowedKeys: Set<UInt16> = []
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flushPending(); completeClicks(count: nil, replay: true); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return Unmanaged.passUnretained(event) }
        if type == .keyUp, swallowedKeys.remove(UInt16(event.getIntegerValueField(.keyboardEventKeycode))) != nil { return nil }
        let foreground = NSWorkspace.shared.frontmostApplication
        let app = foreground?.bundleIdentifier
        if foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            smoother.reset(); cancelPending(); completeClicks(count: nil, replay: false)
            return Unmanaged.passUnretained(event)
        }
        if let discardedButton, Int(event.getIntegerValueField(.mouseEventButtonNumber)) == discardedButton.rawValue,
           [.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type) {
            if [.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type) { self.discardedButton = nil }
            return nil
        }
        if book.excludedBundleIdentifiers.contains(app ?? "") || (app == nil && !book.excludedBundleIdentifiers.isEmpty) { flushPending(); return Unmanaged.passUnretained(event) }
        let mods = Self.modifiers(event.flags)
        if type == .keyUp {
            if swallowedKeys.remove(UInt16(event.getIntegerValueField(.keyboardEventKeycode))) != nil { return nil }
        }
        if type == .keyDown {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if swallowedKeys.contains(code) { return nil }
            if fire(.keyboard(KeyboardShortcut(keyCode: code, modifiers: mods))) { swallowedKeys.insert(code); return nil }
        }
        if type == .scrollWheel { return processScroll(event) }
        if type == .mouseMoved {
            if hypot(event.location.x - scrollLocation.x, event.location.y - scrollLocation.y) > 2 { smoother.reset() }
            checkCorner(event.location, modifiers: mods)
        }
        let down = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type)
        let up = [.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type)
        let dragged = [.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type)
        guard let button = MouseButton(rawValue: Int(event.getIntegerValueField(.mouseEventButtonNumber))) else { return Unmanaged.passUnretained(event) }
        if down {
            if let expired = clickResolver.advance(now: ProcessInfo.processInfo.systemUptime) { completeClicks(count: expired, replay: true) }
            if clickButton != nil && (clickButton != button || clickModifiers != mods || clickApp != app) { completeClicks(count: nil, replay: true) }
            if let prior = clickResolver.pendingCount {
                let incoming = Int(event.getIntegerValueField(.mouseEventClickState))
                if incoming <= prior { completeClicks(count: prior, replay: true) }
                else { clickTimer?.invalidate(); clickTimer = nil }
            }
            flushPending()
            let relevant = book.rules.contains { rule in
                guard rule.isEnabled && rule.scope.includes(app) else { return false }
                switch rule.trigger {
                case .draw(let t): return t.button == button && t.modifiers == mods
                case .shape(let t): return t.button == button && t.modifiers == mods
                case .mouseButton(let t): return t.button == button && t.modifiers == mods
                default: return false
                }
            }
            if relevant, let copy = event.copy() {
                pendingButton = button; pendingModifiers = mods; pendingApp = app
                pending = [copy]; points = [GesturePoint(x: event.location.x, y: -event.location.y)]
                return nil
            }
        }
        if pendingButton == button && (dragged || up) {
            guard pendingApp == app else { cancelPending(); if up { discardedButton = nil }; return nil }
            if let copy = event.copy() { pending.append(copy) }
            points.append(GesturePoint(x: event.location.x, y: -event.location.y))
            if dragged { overlay.show(points.map { CGPoint(x: $0.x, y: -$0.y) }) }
            if pending.count > 2048 { flushPending(); return nil }
            if up {
                overlay.hide()
                let directions = DrawGestureRecognizer().directions(for: points)
                if (ShapeGestureRecognizer.strokeExtent(points) ?? 0) < 16 {
                    let maximum = book.rules.compactMap { rule -> Int? in
                        guard rule.isEnabled, rule.scope.includes(app), case .mouseButton(let trigger) = rule.trigger,
                              trigger.button == button, trigger.modifiers == pendingModifiers else { return nil }
                        return trigger.clickCount
                    }.max() ?? 1
                    clickButton = button; clickModifiers = pendingModifiers; clickApp = app
                    clickEvents.append(contentsOf: pending)
                    pending.removeAll(); points.removeAll(); pendingButton = nil
                    let decision = clickResolver.evaluate(count: Int(event.getIntegerValueField(.mouseEventClickState)), maxRegisteredClickCount: maximum,
                                                          now: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval)
                    clickTimer?.invalidate(); clickTimer = nil
                    switch decision {
                    case .deliver(let count): completeClicks(count: count, replay: true)
                    case .ignored: completeClicks(count: nil, replay: true)
                    case .deferred(let deadline):
                        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                            guard let self else { return }
                            let count = self.clickResolver.advance(now: ProcessInfo.processInfo.systemUptime)
                            self.completeClicks(count: count, replay: true)
                        }
                        clickTimer = timer; RunLoop.main.add(timer, forMode: .common)
                    }
                } else {
                    completeClicks(count: nil, replay: true)
                    let triggers: [InputTrigger] = [.draw(DrawGestureTrigger(button: button, directions: directions, modifiers: pendingModifiers)),
                                                    .shape(ShapeGestureTrigger(button: button, points: ShapeGestureRecognizer.normalizedPath(points), modifiers: pendingModifiers))]
                    if fire(triggers) { pending.removeAll(); points.removeAll(); pendingButton = nil }
                    else { flushPending() }
                }
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
    private func completeClicks(count: Int?, replay: Bool) {
        clickTimer?.invalidate(); clickTimer = nil
        let events = clickEvents, button = clickButton, modifiers = clickModifiers, app = clickApp
        clickEvents.removeAll(); clickButton = nil; clickApp = nil; clickResolver.cancel()
        guard app == NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        if let count, let button, fire(.mouseButton(MouseButtonTrigger(button: button, clickCount: count, modifiers: modifiers))) { return }
        if replay { for event in events { event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag); event.post(tap: .cgSessionEventTap) } }
    }
    private func cancelPending() {
        if let pendingButton { discardedButton = pendingButton }
        pending.removeAll(); points.removeAll(); pendingButton = nil; overlay.hide()
    }
    private func flushPending() {
        overlay.hide()
        let events = pending; pending.removeAll(); points.removeAll(); pendingButton = nil
        for event in events { event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag); event.post(tap: .cgSessionEventTap) }
    }
    @discardableResult private func fire(_ trigger: InputTrigger) -> Bool { fire([trigger]) }
    @discardableResult private func fire(_ triggers: [InputTrigger]) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ids = Set(triggers.flatMap { RuleMatcher.matchingRules(for: $0, in: app, rules: book.rules, excludedBundleIdentifiers: book.excludedBundleIdentifiers).map(\.id) })
        let matches = book.rules.enumerated().filter { ids.contains($0.element.id) }.sorted { left, right in
            if left.element.scope.isGlobal != right.element.scope.isGlobal { return !left.element.scope.isGlobal }
            if left.element.priority != right.element.priority { return left.element.priority > right.element.priority }
            return left.offset < right.offset
        }
        guard let rule = matches.first?.element, !rule.actions.isEmpty else { return false }
        let generation = configurationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.configurationGeneration == generation else { return }
            self.onEvent?(rule.name); self.executor.execute(rule.actions)
        }
        return true
    }
    private func processScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard book.scroll.isEnabled else { return Unmanaged.passUnretained(event) }
        // Device identity is preferred. Unknown continuous sources remain untouched.
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let identity = EventDeviceIdentity.info(for: event)
        if identity.senderID != scrollSource || hypot(event.location.x - scrollLocation.x, event.location.y - scrollLocation.y) > 2 { smoother.reset() }
        scrollSource = identity.senderID
        scrollLocation = event.location
        if identity.kind != .mouse && !book.scroll.affectsContinuousScrolling { smoother.reset(); return Unmanaged.passUnretained(event) }
        let rawV = continuous ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
        let rawH = continuous ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
        let value = book.scroll.transform(vertical: rawV, horizontal: rawH, isContinuous: false)
        if book.scroll.smooth && !continuous {
            smoother.add(vertical: value.vertical, horizontal: value.horizontal); scrollFlags = event.flags; return nil
        }
        if continuous {
            let verticalScale = book.scroll.verticalMultiplier * (book.scroll.reverseVertical ? -1 : 1)
            let horizontalScale = book.scroll.horizontalMultiplier * (book.scroll.reverseHorizontal ? -1 : 1)
            for field in [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1] as [CGEventField] {
                let value = Double(event.getIntegerValueField(field)) * verticalScale
                event.setIntegerValueField(field, value: Int64(max(-1_000_000_000, min(1_000_000_000, value.rounded()))))
            }
            for field in [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2] as [CGEventField] {
                let value = Double(event.getIntegerValueField(field)) * horizontalScale
                event.setIntegerValueField(field, value: Int64(max(-1_000_000_000, min(1_000_000_000, value.rounded()))))
            }
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * verticalScale)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * horizontalScale)
            return Unmanaged.passUnretained(event)
        }
        guard let output = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(max(-1_000_000, min(1_000_000, value.vertical.rounded()))), wheel2: Int32(max(-1_000_000, min(1_000_000, value.horizontal.rounded()))), wheel3: 0) else { return Unmanaged.passUnretained(event) }
        output.location = event.location; output.flags = event.flags; output.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        output.post(tap: .cgSessionEventTap); return nil
    }
    private func tickScroll() {
        let step = smoother.step(deltaTime: 1.0 / 120, duration: book.scroll.effectiveSmoothingDuration)
        let v = step.vertical, h = step.horizontal
        guard v != 0 || h != 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) else { return }
        event.location = scrollLocation; event.flags = scrollFlags; event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag); event.post(tap: .cgSessionEventTap)
    }
    private func checkCorner(_ point: CGPoint, modifiers: ModifierKeys) {
        guard let primary = NSScreen.screens.first else { return }
        let frames = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: primary.frame.height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        guard let frame = frames.first(where: { $0.contains(point) }) else { corner = nil; return }
        let margin: CGFloat = 3
        let next: ScreenCorner?
        if point.x <= frame.minX + margin && point.y <= frame.minY + margin { next = .topLeft }
        else if point.x >= frame.maxX - margin && point.y <= frame.minY + margin { next = .topRight }
        else if point.x <= frame.minX + margin && point.y >= frame.maxY - margin { next = .bottomLeft }
        else if point.x >= frame.maxX - margin && point.y >= frame.maxY - margin { next = .bottomRight }
        else { next = nil }
        if let next, next != corner { _ = fire(.screenCorner(ScreenCornerTrigger(corner: next, modifiers: modifiers))) }
        corner = next
    }
    static func modifiers(_ flags: CGEventFlags) -> ModifierKeys {
        var result: ModifierKeys = []
        if flags.contains(.maskCommand) { result.insert(.command) }; if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }; if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }; return result
    }
}
