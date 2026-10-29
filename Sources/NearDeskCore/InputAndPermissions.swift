// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionProbe {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    public static var accessibility: Bool { AXIsProcessTrusted() }

    public static func promptScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    public static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

public enum DisplayCatalog {
    public static var mainID: UInt32 { CGMainDisplayID() }

    public static func current() -> [RemoteDisplay] {
        // Prefer active displays; UTM/VMs often report online-but-inactive (active=0).
        if let ids = displayIDs(using: CGGetActiveDisplayList), !ids.isEmpty {
            return ids.map(describe)
        }
        if let ids = displayIDs(using: CGGetOnlineDisplayList), !ids.isEmpty {
            return ids.map(describe)
        }
        let main = CGMainDisplayID()
        return main == 0 ? [] : [describe(main)]
    }

    private static func displayIDs(
        using getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
    ) -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard getter(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getter(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    public static func describe(_ id: CGDirectDisplayID) -> RemoteDisplay {
        let bounds = CGDisplayBounds(id)
        let pxW = UInt32(CGDisplayPixelsWide(id))
        let pxH = UInt32(CGDisplayPixelsHigh(id))
        let scale = bounds.width > 0 ? Double(pxW) / Double(bounds.width) : 1
        let (num, den) = rational(scale)
        return RemoteDisplay(
            displayID: UInt32(id),
            originX: Int32(bounds.origin.x.rounded()),
            originY: Int32(bounds.origin.y.rounded()),
            widthPx: pxW,
            heightPx: pxH,
            scaleNum: num,
            scaleDen: den
        )
    }

    private static func rational(_ scale: Double) -> (UInt32, UInt32) {
        let nearest = scale.rounded()
        if abs(scale - nearest) < 0.01, nearest >= 1 {
            return (UInt32(nearest), 1)
        }
        return (UInt32(max((scale * 1000).rounded(), 1)), 1000)
    }
}

public enum ModifierMap {
    public static func eventFlags(_ bits: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if bits & (1 << 0) != 0 { flags.insert(.maskShift) }
        if bits & (1 << 1) != 0 { flags.insert(.maskControl) }
        if bits & (1 << 2) != 0 { flags.insert(.maskAlternate) }
        if bits & (1 << 3) != 0 { flags.insert(.maskCommand) }
        if bits & (1 << 4) != 0 { flags.insert(.maskAlphaShift) }
        if bits & (1 << 5) != 0 { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

public enum InjectError: Error {
    case accessibility
    case create
    case wrongDisplay
}

public enum InputInjector {
    public static let echoedUserData: Int64 = 0x4E445330

    public static func inject(_ message: NearMessage, display: RemoteDisplay) throws -> (eventID: UInt64, tInject: UInt64, kind: String) {
        guard AXIsProcessTrusted() else { throw InjectError.accessibility }
        switch message {
        case .mouseMove(let move):
            guard move.prefix.displayID == display.displayID else { throw InjectError.wrongDisplay }
            let point = point(x: move.xPx, y: move.yPx, display: display)
            let t = try postMouse(.mouseMoved, button: .left, point: point, flags: [])
            return (move.prefix.eventID, t, MessageType.mouseMove.kindName)
        case .mouseButton(let button):
            guard button.prefix.displayID == display.displayID else { throw InjectError.wrongDisplay }
            let point = point(x: button.xPx, y: button.yPx, display: display)
            let t = try postMouse(mouseType(button.button, action: button.action), button: mouseButton(button.button), point: point, flags: [], buttonNumber: button.button)
            return (button.prefix.eventID, t, MessageType.mouseButton.kindName)
        case .wheel(let wheel):
            guard wheel.prefix.displayID == display.displayID else { throw InjectError.wrongDisplay }
            let point = point(x: wheel.xPx, y: wheel.yPx, display: display)
            let t = try postWheel(point: point, deltaX: wheel.deltaX, deltaY: wheel.deltaY, unit: wheel.unit)
            return (wheel.prefix.eventID, t, MessageType.wheel.kindName)
        case .key(let key):
            guard key.prefix.displayID == display.displayID else { throw InjectError.wrongDisplay }
            let t = try postKey(key)
            return (key.prefix.eventID, t, MessageType.key.kindName)
        default:
            throw InjectError.create
        }
    }

    private static func point(x: Float, y: Float, display: RemoteDisplay) -> CGPoint {
        let global = display.globalPoint(xPx: Double(x), yPx: Double(y))
        return CGPoint(x: global.x, y: global.y)
    }

    private static func postMouse(
        _ type: CGEventType,
        button: CGMouseButton,
        point: CGPoint,
        flags: CGEventFlags,
        buttonNumber: UInt8 = 0
    ) throws -> UInt64 {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw InjectError.create
        }
        event.flags = flags
        if buttonNumber == 2 {
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        event.setIntegerValueField(.eventSourceUserData, value: echoedUserData)
        event.post(tap: .cghidEventTap)
        return MonoClock.nanoseconds()
    }

    private static func postWheel(point: CGPoint, deltaX: Float, deltaY: Float, unit: UInt8) throws -> UInt64 {
        let units: CGScrollEventUnit = unit == 1 ? .pixel : .line
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 2,
            wheel1: ticks(deltaY),
            wheel2: ticks(deltaX),
            wheel3: 0
        ) else { throw InjectError.create }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: echoedUserData)
        event.post(tap: .cghidEventTap)
        return MonoClock.nanoseconds()
    }

    private static func postKey(_ key: KeyEvent) throws -> UInt64 {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key.keycode), keyDown: key.action != 2) else {
            throw InjectError.create
        }
        event.flags = ModifierMap.eventFlags(key.modifiers)
        if key.action == 3 {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.setIntegerValueField(.eventSourceUserData, value: echoedUserData)
        event.post(tap: .cghidEventTap)
        return MonoClock.nanoseconds()
    }

    private static func ticks(_ value: Float) -> Int32 {
        if value == 0 { return 0 }
        let rounded = value.rounded()
        if rounded == 0 { return value > 0 ? 1 : -1 }
        return Int32(rounded)
    }

    private static func mouseButton(_ button: UInt8) -> CGMouseButton {
        switch button {
        case 1: return .right
        case 2: return .center
        default: return .left
        }
    }

    private static func mouseType(_ button: UInt8, action: UInt8) -> CGEventType {
        let down = action == 1
        switch button {
        case 1: return down ? .rightMouseDown : .rightMouseUp
        case 2: return down ? .otherMouseDown : .otherMouseUp
        default: return down ? .leftMouseDown : .leftMouseUp
        }
    }
}
