#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation

    @MainActor
    final class DirectInputController: ObservableObject {
        @Published private(set) var isCapturing = false
        @Published private(set) var isEdgeMonitoring = false
        @Published private(set) var lastError: String?
        @Published private(set) var needsAccessibility = false
        @Published private(set) var hasAccessibility = AccessibilityPermission.isTrusted

        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var edgeTap: CFMachPort?
        private var edgeRunLoopSource: CFRunLoopSource?
        private var statusItem: NSStatusItem?
        private var pressedKeys: Set<Keycode> = []
        private var pressedMouseButtons: MouseButtons = []
        private var modifiers: KeyboardModifiers = []
        private var cursorHidden = false

        private var edgeCrossingEnabled = false
        private var edgeTopPushAccum: Double = 0
        private var lastEdgePushTime: TimeInterval = 0
        private var entryTime: TimeInterval = 0
        private var entryDisplayBounds: CGRect = CGDisplayBounds(CGMainDisplayID())
        private var virtualX: Double = 0
        private var virtualY: Double = AppSettings.defaultIPadVirtualHeight
        private var virtualHeight: Double = AppSettings.defaultIPadVirtualHeight
        private var pointerSensitivity: Double = AppSettings.defaultMacPointerSensitivity
        private var residualX: Double = 0
        private var residualY: Double = 0
        private var bottomPushAccum: Double = 0
        private var lastBottomPushTime: TimeInterval = 0
        private var entryMacLocation: CGPoint?
        private var edgeHID: HIDInput?
        private var accessibilityTimer: Timer?

        private var sendKeyboard: ((KeyboardReport) -> Void)?
        private var sendMouse: ((MouseReport) -> Void)?
        private var onRelease: (() -> Void)?

        init() {
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAccessibilityAndArm()
                }
            }
        }

        func syncEdgeMonitor(
            enabled: Bool,
            hid: HIDInput,
            virtualHeight: Double = AppSettings.defaultIPadVirtualHeight,
            pointerSensitivity: Double = AppSettings.defaultMacPointerSensitivity
        ) {
            edgeCrossingEnabled = enabled
            edgeHID = hid
            self.virtualHeight = virtualHeight
            self.pointerSensitivity = pointerSensitivity

            if enabled, hid.isConnected {
                if !isCapturing {
                    startEdgeMonitor(
                        hid: hid,
                        virtualHeight: virtualHeight,
                        pointerSensitivity: pointerSensitivity
                    )
                }
            } else {
                stopEdgeMonitor()
                stopAccessibilityPolling()
            }
        }

        func start(_ hid: HIDInput) {
            edgeHID = hid
            start(sendKeyboard: hid.sendKeyboard, sendMouse: hid.sendMouse, onRelease: {})
        }

        func startEdgeMonitor(
            hid: HIDInput,
            virtualHeight: Double = AppSettings.defaultIPadVirtualHeight,
            pointerSensitivity: Double = AppSettings.defaultMacPointerSensitivity
        ) {
            self.virtualHeight = virtualHeight
            self.pointerSensitivity = pointerSensitivity
            edgeHID = hid
            edgeCrossingEnabled = true

            let trusted = AccessibilityPermission.isTrusted
            hasAccessibility = trusted
            guard trusted else {
                needsAccessibility = true
                startAccessibilityPolling()
                return
            }
            stopAccessibilityPolling()

            guard edgeTap == nil, !isCapturing, hid.isConnected else { return }

            let mask = CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)
            let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: DirectInputController.edgeTapCallback,
                userInfo: refcon
            ) else {
                return
            }

            edgeTap = tap
            edgeRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let edgeRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), edgeRunLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            isEdgeMonitoring = true
        }

        func stopEdgeMonitor() {
            if let edgeTap {
                CGEvent.tapEnable(tap: edgeTap, enable: false)
            }
            if let edgeRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), edgeRunLoopSource, .commonModes)
            }
            edgeTap = nil
            edgeRunLoopSource = nil
            edgeTopPushAccum = 0
            isEdgeMonitoring = false
        }

        private func refreshAccessibilityAndArm() {
            let trusted = AccessibilityPermission.isTrusted
            if hasAccessibility != trusted {
                hasAccessibility = trusted
            }
            if trusted {
                needsAccessibility = false
                stopAccessibilityPolling()
                if edgeCrossingEnabled, !isCapturing, let hid = edgeHID, hid.isConnected {
                    startEdgeMonitor(
                        hid: hid,
                        virtualHeight: virtualHeight,
                        pointerSensitivity: pointerSensitivity
                    )
                }
            }
        }

        private func startAccessibilityPolling() {
            guard accessibilityTimer == nil else { return }
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshAccessibilityAndArm()
                    if self.hasAccessibility || !self.edgeCrossingEnabled {
                        self.stopAccessibilityPolling()
                    }
                }
            }
        }

        private func stopAccessibilityPolling() {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        }

        func updateVirtualHeight(_ height: Double) {
            virtualHeight = height
        }

        func updatePointerSensitivity(_ sensitivity: Double) {
            pointerSensitivity = sensitivity
        }

        func start(
            sendKeyboard: @escaping (KeyboardReport) -> Void,
            sendMouse: @escaping (MouseReport) -> Void,
            entryLocation: CGPoint? = nil,
            onRelease: @escaping () -> Void
        ) {
            stop()
            stopEdgeMonitor()

            self.sendKeyboard = sendKeyboard
            self.sendMouse = sendMouse
            self.entryMacLocation = entryLocation
            self.onRelease = onRelease
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            let bounds = entryLocation.map { displayBounds(containing: $0) } ?? CGDisplayBounds(CGMainDisplayID())
            entryDisplayBounds = bounds
            virtualX = Double(entryLocation?.x ?? bounds.midX)
            virtualY = max(0, virtualHeight - 60)
            entryTime = ProcessInfo.processInfo.systemUptime
            residualX = 0
            residualY = 0
            bottomPushAccum = 0
            lastBottomPushTime = 0
            lastError = nil

            let trusted = AccessibilityPermission.isTrusted
            hasAccessibility = trusted
            guard trusted else {
                needsAccessibility = true
                startAccessibilityPolling()
                clearHandlers()
                onRelease()
                return
            }

            let mask = [
                CGEventType.keyDown,
                .keyUp,
                .flagsChanged,
                .mouseMoved,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
                .rightMouseDown,
                .rightMouseUp,
                .rightMouseDragged,
                .otherMouseDown,
                .otherMouseUp,
                .otherMouseDragged,
                .scrollWheel
            ].reduce(CGEventMask(0)) { result, type in
                result | (CGEventMask(1) << CGEventMask(type.rawValue))
            }

            let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: DirectInputController.eventTapCallback,
                userInfo: refcon
            ) else {
                lastError = L10n.DirectInput.captureFailedString
                clearHandlers()
                onRelease()
                return
            }

            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            NSCursor.hide()
            cursorHidden = true
            isCapturing = true
            showStatusItem()
        }

        func stop() {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil

            if cursorHidden {
                NSCursor.unhide()
                cursorHidden = false
            }
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            if let entry = entryMacLocation {
                CGWarpMouseCursorPosition(CGPoint(x: virtualX, y: entry.y + 12))
                entryMacLocation = nil
            }

            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            sendKeyboard?(.zero)
            sendMouse?(.zero)
            clearHandlers()
            hideStatusItem()
            isCapturing = false

            if edgeCrossingEnabled, let hid = edgeHID, hid.isConnected {
                startEdgeMonitor(
                    hid: hid,
                    virtualHeight: virtualHeight,
                    pointerSensitivity: pointerSensitivity
                )
            }
        }

        func clearAccessibilityRequest() {
            needsAccessibility = false
        }

        private func clearHandlers() {
            sendKeyboard = nil
            sendMouse = nil
            onRelease = nil
        }

        /// shown while capturing since cursor is hidden
        private func showStatusItem() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
                icon?.isTemplate = false
                button.image = icon
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(
                    string: "  " + L10n.DirectInput.releaseHintString,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            statusItem = item
        }

        private func hideStatusItem() {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }

        private func handle(_ event: DirectInputEvent) {
            if event.releaseShortcutPressed {
                let release = onRelease
                stop()
                release?()
                return
            }

            modifiers = event.modifiers

            switch event.kind {
            case let .keyDown(key):
                pressedKeys.insert(key)
                sendKeyboardReport()
            case let .keyUp(key):
                pressedKeys.remove(key)
                sendKeyboardReport()
            case .flagsChanged:
                sendKeyboardReport()
            case let .mouseMove(rawDX, rawDY):
                let (dx, dy) = scaleDelta(rawDX: rawDX, rawDY: rawDY)
                virtualX = max(entryDisplayBounds.minX, min(entryDisplayBounds.maxX - 1, virtualX + Double(dx)))
                if shouldReturnFromBottom(dy: Double(dy)) {
                    let release = onRelease
                    stop()
                    release?()
                    return
                }
                if dx != 0 || dy != 0 {
                    sendMouse?(MouseReport(buttons: pressedMouseButtons, dX: dx, dY: dy))
                }
            case let .mouseButton(button, isDown):
                if isDown {
                    pressedMouseButtons.insert(button)
                } else {
                    pressedMouseButtons.remove(button)
                }
                sendMouse?(MouseReport(buttons: pressedMouseButtons))
            case let .scroll(wheel):
                sendMouse?(MouseReport(buttons: pressedMouseButtons, wheel: wheel))
                sendMouse?(MouseReport(buttons: pressedMouseButtons))
            }
        }

        private func scaleDelta(rawDX: Double, rawDY: Double) -> (Int8, Int8) {
            residualX += rawDX * pointerSensitivity
            residualY += rawDY * pointerSensitivity
            let ix = Int(residualX.rounded(.towardZero))
            let iy = Int(residualY.rounded(.towardZero))
            residualX -= Double(ix)
            residualY -= Double(iy)
            return (
                Int8(max(-127, min(127, ix))),
                Int8(max(-127, min(127, iy)))
            )
        }

        private func shouldReturnFromBottom(dy: Double) -> Bool {
            guard edgeCrossingEnabled else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now - entryTime < 0.35 {
                return false
            }

            let nextY = virtualY + dy
            if nextY >= virtualHeight, dy > 0 {
                virtualY = virtualHeight
                if now - lastBottomPushTime > 0.5 {
                    bottomPushAccum = 0
                }
                lastBottomPushTime = now
                bottomPushAccum += dy
                if bottomPushAccum >= 20 {
                    bottomPushAccum = 0
                    if entryMacLocation == nil {
                        let mainBounds = CGDisplayBounds(CGMainDisplayID())
                        entryMacLocation = CGPoint(x: virtualX, y: mainBounds.minY)
                    }
                    return true
                }
                return false
            }

            virtualY = max(0, min(virtualHeight, nextY))
            if dy < -1.0 {
                bottomPushAccum = 0
            }
            return false
        }

        private func handleEdgeMove(location: CGPoint, dy: Double) {
            guard !isCapturing, edgeCrossingEnabled, let hid = edgeHID, hid.isConnected else { return }

            let displayBounds = displayBounds(containing: location)
            let isAtTopEdge = location.y <= displayBounds.minY + 2.0
            guard isAtTopEdge else {
                edgeTopPushAccum = 0
                return
            }

            // Do not cross if another macOS display sits directly above this point.
            guard !hasDisplayAbove(point: location, currentTopY: displayBounds.minY) else {
                edgeTopPushAccum = 0
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            if dy > 0.5 {
                edgeTopPushAccum = 0
                return
            }
            if now - lastEdgePushTime > 0.45 {
                edgeTopPushAccum = 0
            }
            guard dy < 0 else { return }

            lastEdgePushTime = now
            edgeTopPushAccum += abs(dy)

            if edgeTopPushAccum >= 4.0 {
                edgeTopPushAccum = 0
                let entry = CGPoint(x: location.x, y: displayBounds.minY)
                start(
                    sendKeyboard: hid.sendKeyboard,
                    sendMouse: hid.sendMouse,
                    entryLocation: entry,
                    onRelease: {}
                )
            }
        }

        private func displayBounds(containing point: CGPoint) -> CGRect {
            var displayID = CGMainDisplayID()
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 {
                return CGDisplayBounds(displayID)
            }
            return CGDisplayBounds(CGMainDisplayID())
        }

        private func hasDisplayAbove(point: CGPoint, currentTopY: CGFloat) -> Bool {
            var displayCount: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 1 else {
                return false
            }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
                return false
            }
            for id in displays.prefix(Int(displayCount)) {
                let bounds = CGDisplayBounds(id)
                if bounds.maxY <= currentTopY + 1.0,
                   point.x >= bounds.minX,
                   point.x <= bounds.maxX
                {
                    return true
                }
            }
            return false
        }

        private func sendKeyboardReport() {
            sendKeyboard?(KeyboardReport(modifiers: modifiers, keys: Array(pressedKeys).prefix(6).map(\.self)))
        }

        private nonisolated static let edgeTapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let controller = Unmanaged<DirectInputController>.fromOpaque(userInfo).takeUnretainedValue()

            guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
                MainActor.assumeIsolated {
                    controller.edgeTap.map { CGEvent.tapEnable(tap: $0, enable: true) }
                }
                return Unmanaged.passUnretained(cgEvent)
            }

            let location = cgEvent.location
            let (_, dy) = DirectInputEvent.mouseDeltas(from: cgEvent)
            MainActor.assumeIsolated {
                controller.handleEdgeMove(location: location, dy: dy)
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        private nonisolated static let eventTapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return nil }
            let controller = Unmanaged<DirectInputController>.fromOpaque(userInfo).takeUnretainedValue()

            guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
                MainActor.assumeIsolated {
                    controller.eventTap.map { CGEvent.tapEnable(tap: $0, enable: true) }
                }
                return nil
            }

            guard let event = DirectInputEvent(type: type, event: cgEvent) else {
                return nil
            }

            MainActor.assumeIsolated {
                controller.handle(event)
            }
            return nil
        }
    }

    private struct DirectInputEvent: Sendable {
        enum Kind: Sendable {
            case keyDown(Keycode)
            case keyUp(Keycode)
            case flagsChanged
            case mouseMove(Double, Double)
            case mouseButton(MouseButtons, Bool)
            case scroll(Int8)
        }

        let kind: Kind
        let modifiers: KeyboardModifiers
        let releaseShortcutPressed: Bool

        init?(type: CGEventType, event: CGEvent) {
            let flags = event.flags
            modifiers = KeyboardModifiers(eventFlags: flags)
            releaseShortcutPressed = flags.contains(.maskControl) && flags.contains(.maskAlternate)

            switch type {
            case .keyDown:
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                guard let key = Keycode(macVirtualKey: UInt16(event.getIntegerValueField(.keyboardEventKeycode))) else { return nil }
                kind = .keyDown(key)
            case .keyUp:
                guard let key = Keycode(macVirtualKey: UInt16(event.getIntegerValueField(.keyboardEventKeycode))) else { return nil }
                kind = .keyUp(key)
            case .flagsChanged:
                kind = .flagsChanged
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                let (dx, dy) = Self.mouseDeltas(from: event)
                guard dx != 0 || dy != 0 else { return nil }
                kind = .mouseMove(dx, dy)
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                guard let button = Self.mouseButton(for: type) else { return nil }
                kind = .mouseButton(button.0, button.1)
            case .scrollWheel:
                let wheel = Self.clampInt8(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                guard wheel != 0 else { return nil }
                kind = .scroll(wheel)
            default:
                return nil
            }
        }

        static func mouseDeltas(from event: CGEvent) -> (Double, Double) {
            if let nsEvent = NSEvent(cgEvent: event) {
                let dx = Double(nsEvent.deltaX)
                let dy = Double(nsEvent.deltaY)
                if dx != 0 || dy != 0 {
                    return (dx, dy)
                }
            }
            return (
                Double(event.getIntegerValueField(.mouseEventDeltaX)),
                Double(event.getIntegerValueField(.mouseEventDeltaY))
            )
        }

        private static func clampInt8(_ value: Int64) -> Int8 {
            Int8(max(-127, min(127, Int(value))))
        }

        private static func mouseButton(for type: CGEventType) -> (MouseButtons, Bool)? {
            switch type {
            case .leftMouseDown: (.left, true)
            case .leftMouseUp: (.left, false)
            case .rightMouseDown: (.right, true)
            case .rightMouseUp: (.right, false)
            case .otherMouseDown: (.middle, true)
            case .otherMouseUp: (.middle, false)
            default: nil
            }
        }
    }

    private extension KeyboardModifiers {
        init(eventFlags flags: CGEventFlags) {
            self.init()
            if flags.contains(.maskControl) { insert(.leftCtrl) }
            if flags.contains(.maskShift) { insert(.leftShift) }
            if flags.contains(.maskAlternate) { insert(.leftAlt) }
            if flags.contains(.maskCommand) { insert(.leftGUI) }
        }
    }

    private extension Keycode {
        init?(macVirtualKey key: UInt16) {
            guard let code = Self.macVirtualKeys[key] else { return nil }
            self = code
        }

        static let macVirtualKeys: [UInt16: Keycode] = [
            0x00: .a, 0x0B: .b, 0x08: .c, 0x02: .d, 0x0E: .e, 0x03: .f, 0x05: .g, 0x04: .h,
            0x22: .i, 0x26: .j, 0x28: .k, 0x25: .l, 0x2E: .m, 0x2D: .n, 0x1F: .o, 0x23: .p,
            0x0C: .q, 0x0F: .r, 0x01: .s, 0x11: .t, 0x20: .u, 0x09: .v, 0x0D: .w, 0x07: .x,
            0x10: .y, 0x06: .z,
            0x12: .digit1, 0x13: .digit2, 0x14: .digit3, 0x15: .digit4, 0x17: .digit5,
            0x16: .digit6, 0x1A: .digit7, 0x1C: .digit8, 0x19: .digit9, 0x1D: .digit0,
            0x24: .return, 0x4C: .return,
            0x35: .escape, 0x33: .backspace, 0x30: .tab, 0x31: .space,
            0x1B: .minus, 0x18: .equal, 0x21: .leftBracket, 0x1E: .rightBracket,
            0x2A: .backslash, 0x29: .semicolon, 0x27: .quote, 0x32: .grave,
            0x2B: .comma, 0x2F: .period, 0x2C: .slash, 0x39: .capsLock,
            0x7A: .f1, 0x78: .f2, 0x63: .f3, 0x76: .f4, 0x60: .f5, 0x61: .f6,
            0x62: .f7, 0x64: .f8, 0x65: .f9, 0x6D: .f10, 0x67: .f11, 0x6F: .f12,
            0x7C: .rightArrow, 0x7B: .leftArrow, 0x7D: .downArrow, 0x7E: .upArrow
        ]
    }

#elseif os(iOS)
    import CoreGraphics
    import Foundation
    import GameController
    import SwiftUI
    import UIKit

    @MainActor
    final class DirectInputController: ObservableObject {
        @Published private(set) var isCapturing = false
        @Published private(set) var lastError: String?
        @Published private(set) var hasInputDevice = false

        private var sendKeyboard: ((KeyboardReport) -> Void)?
        private var sendMouse: ((MouseReport) -> Void)?
        private var pressedKeys: Set<Keycode> = []
        private var pressedMouseButtons: MouseButtons = []
        private var modifiers: KeyboardModifiers = []
        private var observers: [NSObjectProtocol] = []

        // GCMouse deltas are in points
        private static let sensitivity: CGFloat = 1
        private static let scrollSensitivity: CGFloat = 1

        init() {
            refreshDevicePresence()
            observeDevices()
        }

        func start(_ hid: HIDInput) {
            start(sendKeyboard: hid.sendKeyboard, sendMouse: hid.sendMouse)
        }

        func start(
            sendKeyboard: @escaping (KeyboardReport) -> Void,
            sendMouse: @escaping (MouseReport) -> Void
        ) {
            stop()
            guard hasInputDevice else { return }

            self.sendKeyboard = sendKeyboard
            self.sendMouse = sendMouse
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            lastError = nil

            attachHandlers()
            isCapturing = true
        }

        func stop() {
            detachHandlers()
            if isCapturing {
                sendKeyboard?(.zero)
                sendMouse?(.zero)
            }
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            sendKeyboard = nil
            sendMouse = nil
            isCapturing = false
        }

        private func attachHandlers() {
            if let keyboard = GCKeyboard.coalesced {
                keyboard.handlerQueue = .main
                keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                    let raw = keyCode.rawValue
                    Task { @MainActor in self?.handleKey(raw: raw, pressed: pressed) }
                }
            }
            if let mouse = GCMouse.current {
                mouse.handlerQueue = .main
                let input = mouse.mouseInput
                input?.mouseMovedHandler = { [weak self] _, dx, dy in
                    Task { @MainActor in self?.handleMove(dx: dx, dy: dy) }
                }
                input?.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.left, pressed) }
                }
                input?.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.right, pressed) }
                }
                input?.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.middle, pressed) }
                }
                input?.scroll.valueChangedHandler = { [weak self] _, _, y in
                    Task { @MainActor in self?.handleScroll(y) }
                }
            }
        }

        private func detachHandlers() {
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
            if let input = GCMouse.current?.mouseInput {
                input.mouseMovedHandler = nil
                input.leftButton.pressedChangedHandler = nil
                input.rightButton?.pressedChangedHandler = nil
                input.middleButton?.pressedChangedHandler = nil
                input.scroll.valueChangedHandler = nil
            }
        }

        /// GCKeyCode raw values are HID usages
        private func handleKey(raw: Int, pressed: Bool) {
            if (0xE0 ... 0xE7).contains(raw) {
                let mod = KeyboardModifiers(rawValue: UInt8(1) << UInt8(raw - 0xE0))
                if pressed { modifiers.insert(mod) } else { modifiers.remove(mod) }
            } else if let key = Keycode(rawValue: UInt8(truncatingIfNeeded: raw)) {
                if pressed { pressedKeys.insert(key) } else { pressedKeys.remove(key) }
            } else {
                return
            }
            if releaseComboHeld {
                stop()
                return
            }
            sendKeyboard?(KeyboardReport(modifiers: modifiers, keys: Array(pressedKeys.prefix(6))))
        }

        private var releaseComboHeld: Bool {
            !modifiers.isDisjoint(with: [.leftCtrl, .rightCtrl]) &&
                !modifiers.isDisjoint(with: [.leftAlt, .rightAlt])
        }

        private func handleMove(dx: Float, dy: Float) {
            let mx = HIDInput.clamp(CGFloat(dx) * Self.sensitivity)
            let my = HIDInput.clamp(CGFloat(-dy) * Self.sensitivity) // GC y is up-positive but HID down-positive
            guard mx != 0 || my != 0 else { return }
            sendMouse?(MouseReport(buttons: pressedMouseButtons, dX: mx, dY: my))
        }

        private func handleButton(_ button: MouseButtons, _ pressed: Bool) {
            if pressed { pressedMouseButtons.insert(button) } else { pressedMouseButtons.remove(button) }
            sendMouse?(MouseReport(buttons: pressedMouseButtons))
        }

        private func handleScroll(_ y: Float) {
            let wheel = HIDInput.clamp(CGFloat(y) * Self.scrollSensitivity)
            guard wheel != 0 else { return }
            sendMouse?(MouseReport(buttons: pressedMouseButtons, wheel: wheel))
            sendMouse?(MouseReport(buttons: pressedMouseButtons))
        }

        private func refreshDevicePresence() {
            hasInputDevice = GCKeyboard.coalesced != nil || GCMouse.current != nil
        }

        private func observeDevices() {
            let names: [Notification.Name] = [
                .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.refreshDevicePresence()
                        if self.isCapturing { self.attachHandlers() }
                        if !self.hasInputDevice { self.stop() }
                    }
                }
                observers.append(token)
            }
        }
    }

    /// pointer lock gives GameController raw deltas
    struct PointerLockHost: UIViewControllerRepresentable {
        var locked: Bool

        func makeUIViewController(context: Context) -> PointerLockController {
            PointerLockController()
        }

        func updateUIViewController(_ controller: PointerLockController, context: Context) {
            controller.locked = locked
        }
    }

    final class PointerLockController: UIViewController {
        var locked = false {
            didSet {
                guard locked != oldValue else { return }
                setNeedsUpdateOfPrefersPointerLocked()
            }
        }

        override var prefersPointerLocked: Bool {
            locked
        }
    }
#endif
