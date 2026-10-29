// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreVideo
import NearDeskCore
import SwiftUI

struct VideoDesktop: NSViewRepresentable {
    @ObservedObject var surface: VideoSurfaceModel

    func makeNSView(context: Context) -> VideoNSView {
        let view = VideoNSView()
        view.surface = surface
        surface.view = view
        return view
    }

    func updateNSView(_ nsView: VideoNSView, context: Context) {
        nsView.surface = surface
        surface.view = nsView
    }
}

final class VideoSurfaceModel: ObservableObject {
    @Published var controlling = false
    @Published var hud = LatencySnapshot.empty
    var codedWidth = 16
    var codedHeight = 9
    var displayWidth: UInt32 = 1
    var displayHeight: UInt32 = 1
    var onInput: ((NearMessage) -> Void)?
    var onControlling: ((Bool) -> Void)?
    weak var view: VideoNSView?

    func present(_ frame: PresentedFrame) {
        codedWidth = max(frame.codedWidth, 1)
        codedHeight = max(frame.codedHeight, 1)
        displayWidth = max(frame.display.widthPx, 1)
        displayHeight = max(frame.display.heightPx, 1)
        view?.present(frame.pixelBuffer)
    }

    fileprivate func emit(_ message: NearMessage) {
        guard controlling else { return }
        onInput?(message)
    }
}

final class VideoNSView: NSView {
    var surface: VideoSurfaceModel?
    private var pixelBuffer: CVPixelBuffer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    func present(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        layer?.contents = pixelBuffer
    }

    override func mouseDown(with event: NSEvent) {
        takeControl()
        sendPointer(event, button: 0, action: 1)
    }

    override func mouseUp(with event: NSEvent) { sendPointer(event, button: 0, action: 2) }
    override func rightMouseDown(with event: NSEvent) {
        takeControl()
        sendPointer(event, button: 1, action: 1)
    }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event, button: 1, action: 2) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        takeControl()
        sendPointer(event, button: 2, action: 1)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendPointer(event, button: 2, action: 2)
    }
    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }

    override func scrollWheel(with event: NSEvent) {
        guard surface?.controlling == true, let point = displayPoint(event) else { return }
        let prefix = InputPrefix(eventID: 0, eventMono: 0, displayID: 0)
        let unit: UInt8 = event.hasPreciseScrollingDeltas ? 1 : 0
        surface?.emit(.wheel(Wheel(
            prefix: prefix,
            xPx: point.x,
            yPx: point.y,
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            unit: unit
        )))
    }

    override func keyDown(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputInjector.echoedUserData { return }
        if event.keyCode == 53 {
            releaseControl()
            return
        }
        sendKey(event, action: event.isARepeat ? 3 : 1)
    }

    override func keyUp(with event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputInjector.echoedUserData { return }
        sendKey(event, action: 2)
    }

    override func flagsChanged(with event: NSEvent) {
        let action: UInt8 = event.modifierFlags.contains(flag(for: event.keyCode)) ? 1 : 2
        sendKey(event, action: action)
    }

    private func takeControl() {
        window?.makeFirstResponder(self)
        surface?.controlling = true
        surface?.onControlling?(true)
    }

    private func releaseControl() {
        surface?.controlling = false
        surface?.onControlling?(false)
        window?.makeFirstResponder(nil)
    }

    private func sendMove(_ event: NSEvent) {
        guard let point = displayPoint(event) else { return }
        let prefix = InputPrefix(eventID: 0, eventMono: 0, displayID: 0)
        surface?.emit(.mouseMove(MouseMove(prefix: prefix, xPx: point.x, yPx: point.y)))
    }

    private func sendPointer(_ event: NSEvent, button: UInt8, action: UInt8) {
        guard let point = displayPoint(event) else { return }
        let prefix = InputPrefix(eventID: 0, eventMono: 0, displayID: 0)
        surface?.emit(.mouseButton(MouseButton(prefix: prefix, xPx: point.x, yPx: point.y, button: button, action: action)))
    }

    private func sendKey(_ event: NSEvent, action: UInt8) {
        guard surface?.controlling == true else { return }
        let prefix = InputPrefix(eventID: 0, eventMono: 0, displayID: 0)
        let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        surface?.emit(.key(KeyEvent(
            prefix: prefix,
            keycode: event.keyCode,
            action: action,
            modifiers: modifierBits(event.modifierFlags),
            utf32: scalar
        )))
    }

    private func displayPoint(_ event: NSEvent) -> (x: Float, y: Float)? {
        guard let surface else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let video = videoRect(bounds.size, pixelWidth: CGFloat(surface.codedWidth), pixelHeight: CGFloat(surface.codedHeight))
        guard video.contains(local), video.width > 0, video.height > 0 else { return nil }
        let nx = (local.x - video.minX) / video.width
        let ny = 1 - (local.y - video.minY) / video.height
        return (Float(nx * CGFloat(surface.displayWidth)), Float(ny * CGFloat(surface.displayHeight)))
    }

    private func videoRect(_ viewSize: CGSize, pixelWidth: CGFloat, pixelHeight: CGFloat) -> CGRect {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let scale = min(viewSize.width / pixelWidth, viewSize.height / pixelHeight)
        let width = pixelWidth * scale
        let height = pixelHeight * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
    }

    private func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.shift) { bits |= 1 << 0 }
        if flags.contains(.control) { bits |= 1 << 1 }
        if flags.contains(.option) { bits |= 1 << 2 }
        if flags.contains(.command) { bits |= 1 << 3 }
        if flags.contains(.capsLock) { bits |= 1 << 4 }
        if flags.contains(.function) { bits |= 1 << 5 }
        return bits
    }

    private func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 55, 54: return .command
        case 57: return .capsLock
        case 63: return .function
        default: return []
        }
    }
}
