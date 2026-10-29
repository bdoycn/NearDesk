// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ProtocolError: Error, Equatable {
    case badPreface
    case bodyLength
    case unknownType(UInt16)
    case wrongStream(UInt16)
    case malformed
}

public enum StreamKind: UInt8, Equatable {
    case control = 1
    case video = 2
    case input = 3
}

public enum MessageType: UInt16 {
    case hello = 0x0001
    case authPassword = 0x0002
    case authResult = 0x0003
    case displayList = 0x0004
    case selectDisplay = 0x0005
    case videoConfig = 0x0101
    case videoFrame = 0x0102
    case mouseMove = 0x0201
    case mouseButton = 0x0202
    case wheel = 0x0203
    case key = 0x0204

    public var kindName: String {
        switch self {
        case .mouseMove: return "mouse_move"
        case .mouseButton: return "mouse_button"
        case .wheel: return "wheel"
        case .key: return "key"
        default: return String(format: "0x%04x", rawValue)
        }
    }
}

public enum ChannelID {
    public static let hevcMain: UInt8 = 1
    public static let h264Fallback: UInt8 = 2
    public static let losslessTile: UInt8 = 3
}

public enum CodecID {
    public static let hevc: UInt8 = 1
    public static let h264: UInt8 = 2
}

public enum FrameFlag {
    public static let keyframe: UInt8 = 1 << 0
    public static let dirtyCoalesced: UInt8 = 1 << 1
    public static let dirtyNone: UInt8 = 1 << 2
}

public enum NearDeskWire {
    public static let alpn = "neardesk-spike/1"
    public static let serviceType = "_neardesk._udp"
    public static let magic = Data([0x4E, 0x44, 0x53, 0x30])
    public static let version: UInt8 = 1
    public static let maxBodyLength: UInt32 = 8 * 1024 * 1024
}

public struct Preface: Equatable {
    public var kind: StreamKind
    public var version: UInt8

    public init(kind: StreamKind, version: UInt8 = NearDeskWire.version) {
        self.kind = kind
        self.version = version
    }

    public func encode() -> Data {
        var writer = ByteWriter()
        writer.bytes(NearDeskWire.magic)
        writer.u8(kind.rawValue)
        writer.u8(version)
        writer.u16(0)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> Preface {
        guard data.count == 8 else { throw ProtocolError.badPreface }
        guard data.prefix(4) == NearDeskWire.magic else { throw ProtocolError.badPreface }
        guard let kind = StreamKind(rawValue: data[data.startIndex + 4]) else { throw ProtocolError.badPreface }
        let version = data[data.startIndex + 5]
        guard version == NearDeskWire.version else { throw ProtocolError.badPreface }
        let reserved = UInt16(data[data.startIndex + 6]) | (UInt16(data[data.startIndex + 7]) << 8)
        guard reserved == 0 else { throw ProtocolError.badPreface }
        return Preface(kind: kind, version: version)
    }
}

public struct NdRect: Equatable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct Hello: Equatable {
    public var major: UInt16
    public var minor: UInt16
    public var role: UInt8
    public var name: String

    public init(major: UInt16 = 1, minor: UInt16 = 0, role: UInt8 = 1, name: String) {
        self.major = major
        self.minor = minor
        self.role = role
        self.name = name
    }
}

public struct AuthPassword: Equatable {
    public var password: Data
    public init(password: Data) { self.password = password }
}

public struct AuthResult: Equatable {
    public var ok: Bool
    public var reason: UInt8
    public init(ok: Bool, reason: UInt8) {
        self.ok = ok
        self.reason = reason
    }

    public static let none: UInt8 = 0
    public static let badPassword: UInt8 = 1
    public static let version: UInt8 = 2
}

public struct RemoteDisplay: Equatable, Sendable {
    public var displayID: UInt32
    public var originX: Int32
    public var originY: Int32
    public var widthPx: UInt32
    public var heightPx: UInt32
    public var scaleNum: UInt32
    public var scaleDen: UInt32

    public init(
        displayID: UInt32,
        originX: Int32,
        originY: Int32,
        widthPx: UInt32,
        heightPx: UInt32,
        scaleNum: UInt32,
        scaleDen: UInt32
    ) {
        self.displayID = displayID
        self.originX = originX
        self.originY = originY
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.scaleNum = scaleNum
        self.scaleDen = scaleDen
    }

    public var scale: Double {
        guard scaleDen != 0 else { return 1 }
        return Double(scaleNum) / Double(scaleDen)
    }

    public func globalPoint(xPx: Double, yPx: Double) -> (x: Double, y: Double) {
        let scale = self.scale == 0 ? 1 : self.scale
        return (Double(originX) + xPx / scale, Double(originY) + yPx / scale)
    }
}

public struct DisplayList: Equatable {
    public var displays: [RemoteDisplay]
    public init(displays: [RemoteDisplay]) { self.displays = displays }
}

public struct SelectDisplay: Equatable {
    public var displayID: UInt32
    public init(displayID: UInt32) { self.displayID = displayID }
}

public struct VideoConfig: Equatable {
    public var encoderConfigID: UInt16
    public var channelID: UInt8
    public var codec: UInt8
    public var displayID: UInt32
    public var codedWidth: UInt16
    public var codedHeight: UInt16
    public var fpsNum: UInt16
    public var fpsDen: UInt16
    public var chroma: UInt8
    public var paramSets: Data

    public init(
        encoderConfigID: UInt16,
        channelID: UInt8,
        codec: UInt8,
        displayID: UInt32,
        codedWidth: UInt16,
        codedHeight: UInt16,
        fpsNum: UInt16 = 60,
        fpsDen: UInt16 = 1,
        chroma: UInt8 = 1,
        paramSets: Data
    ) {
        self.encoderConfigID = encoderConfigID
        self.channelID = channelID
        self.codec = codec
        self.displayID = displayID
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.fpsNum = fpsNum
        self.fpsDen = fpsDen
        self.chroma = chroma
        self.paramSets = paramSets
    }
}

public struct VideoFrame: Equatable {
    public var frameID: UInt64
    public var encoderConfigID: UInt16
    public var channelID: UInt8
    public var frameFlags: UInt8
    public var captureMono: UInt64
    public var rects: [NdRect]
    public var accessUnit: Data

    public init(
        frameID: UInt64,
        encoderConfigID: UInt16,
        channelID: UInt8,
        frameFlags: UInt8,
        captureMono: UInt64,
        rects: [NdRect],
        accessUnit: Data
    ) {
        self.frameID = frameID
        self.encoderConfigID = encoderConfigID
        self.channelID = channelID
        self.frameFlags = frameFlags
        self.captureMono = captureMono
        self.rects = rects
        self.accessUnit = accessUnit
    }

    public var qualifiesForInputMatch: Bool {
        frameFlags & FrameFlag.dirtyNone != 0 || !rects.isEmpty
    }
}

public struct InputPrefix: Equatable {
    public var eventID: UInt64
    public var eventMono: UInt64
    public var displayID: UInt32

    public init(eventID: UInt64, eventMono: UInt64, displayID: UInt32) {
        self.eventID = eventID
        self.eventMono = eventMono
        self.displayID = displayID
    }
}

public struct MouseMove: Equatable {
    public var prefix: InputPrefix
    public var xPx: Float
    public var yPx: Float
    public init(prefix: InputPrefix, xPx: Float, yPx: Float) {
        self.prefix = prefix
        self.xPx = xPx
        self.yPx = yPx
    }
}

public struct MouseButton: Equatable {
    public var prefix: InputPrefix
    public var xPx: Float
    public var yPx: Float
    public var button: UInt8
    public var action: UInt8
    public init(prefix: InputPrefix, xPx: Float, yPx: Float, button: UInt8, action: UInt8) {
        self.prefix = prefix
        self.xPx = xPx
        self.yPx = yPx
        self.button = button
        self.action = action
    }
}

public struct Wheel: Equatable {
    public var prefix: InputPrefix
    public var xPx: Float
    public var yPx: Float
    public var deltaX: Float
    public var deltaY: Float
    public var unit: UInt8
    public init(prefix: InputPrefix, xPx: Float, yPx: Float, deltaX: Float, deltaY: Float, unit: UInt8) {
        self.prefix = prefix
        self.xPx = xPx
        self.yPx = yPx
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.unit = unit
    }
}

public struct KeyEvent: Equatable {
    public var prefix: InputPrefix
    public var keycode: UInt16
    public var action: UInt8
    public var modifiers: UInt8
    public var utf32: UInt32
    public init(prefix: InputPrefix, keycode: UInt16, action: UInt8, modifiers: UInt8, utf32: UInt32) {
        self.prefix = prefix
        self.keycode = keycode
        self.action = action
        self.modifiers = modifiers
        self.utf32 = utf32
    }
}

public enum NearMessage: Equatable {
    case hello(Hello)
    case authPassword(AuthPassword)
    case authResult(AuthResult)
    case displayList(DisplayList)
    case selectDisplay(SelectDisplay)
    case videoConfig(VideoConfig)
    case videoFrame(VideoFrame)
    case mouseMove(MouseMove)
    case mouseButton(MouseButton)
    case wheel(Wheel)
    case key(KeyEvent)

    public var type: MessageType {
        switch self {
        case .hello: return .hello
        case .authPassword: return .authPassword
        case .authResult: return .authResult
        case .displayList: return .displayList
        case .selectDisplay: return .selectDisplay
        case .videoConfig: return .videoConfig
        case .videoFrame: return .videoFrame
        case .mouseMove: return .mouseMove
        case .mouseButton: return .mouseButton
        case .wheel: return .wheel
        case .key: return .key
        }
    }

    public func allowed(on kind: StreamKind) -> Bool {
        switch kind {
        case .control:
            switch self {
            case .hello, .authPassword, .authResult, .displayList, .selectDisplay: return true
            default: return false
            }
        case .video:
            switch self {
            case .videoConfig, .videoFrame: return true
            default: return false
            }
        case .input:
            switch self {
            case .mouseMove, .mouseButton, .wheel, .key: return true
            default: return false
            }
        }
    }
}

enum WireEncoding {
    static func encodeBody(_ message: NearMessage) throws -> Data {
        var writer = ByteWriter()
        switch message {
        case .hello(let hello):
            let name = UTF8Bytes.clipped(hello.name, maxBytes: 64)
            guard name.count <= 64 else { throw ProtocolError.malformed }
            writer.u16(hello.major)
            writer.u16(hello.minor)
            writer.u8(hello.role)
            writer.u8(UInt8(name.count))
            writer.bytes(name)
        case .authPassword(let auth):
            guard (1...128).contains(auth.password.count) else { throw ProtocolError.malformed }
            writer.u16(UInt16(auth.password.count))
            writer.bytes(auth.password)
        case .authResult(let result):
            writer.u8(result.ok ? 1 : 0)
            writer.u8(result.reason)
            writer.u16(0)
        case .displayList(let list):
            guard list.displays.count <= Int(UInt16.max) else { throw ProtocolError.malformed }
            writer.u16(UInt16(list.displays.count))
            writer.u16(0)
            for display in list.displays {
                guard display.scaleDen != 0 else { throw ProtocolError.malformed }
                writer.u32(display.displayID)
                writer.i32(display.originX)
                writer.i32(display.originY)
                writer.u32(display.widthPx)
                writer.u32(display.heightPx)
                writer.u32(display.scaleNum)
                writer.u32(display.scaleDen)
            }
        case .selectDisplay(let select):
            writer.u32(select.displayID)
        case .videoConfig(let config):
            guard config.encoderConfigID != 0 else { throw ProtocolError.malformed }
            guard config.chroma == 1 else { throw ProtocolError.malformed }
            guard config.paramSets.count <= Int(UInt16.max) else { throw ProtocolError.malformed }
            writer.u16(config.encoderConfigID)
            writer.u8(config.channelID)
            writer.u8(config.codec)
            writer.u32(config.displayID)
            writer.u16(config.codedWidth)
            writer.u16(config.codedHeight)
            writer.u16(config.fpsNum)
            writer.u16(config.fpsDen)
            writer.u8(config.chroma)
            writer.u8(0)
            writer.u16(UInt16(config.paramSets.count))
            writer.bytes(config.paramSets)
        case .videoFrame(let frame):
            guard frame.encoderConfigID != 0 else { throw ProtocolError.malformed }
            if frame.frameFlags & FrameFlag.dirtyNone != 0, !frame.rects.isEmpty {
                throw ProtocolError.malformed
            }
            guard frame.rects.count <= 64 else { throw ProtocolError.malformed }
            guard frame.accessUnit.count <= Int(UInt32.max) else { throw ProtocolError.malformed }
            for rect in frame.rects where rect.width <= 0 || rect.height <= 0 {
                throw ProtocolError.malformed
            }
            writer.u64(frame.frameID)
            writer.u16(frame.encoderConfigID)
            writer.u8(frame.channelID)
            writer.u8(frame.frameFlags)
            writer.u16(UInt16(frame.rects.count))
            writer.u16(0)
            writer.u64(frame.captureMono)
            writer.u32(UInt32(frame.accessUnit.count))
            for rect in frame.rects {
                writer.i32(rect.x)
                writer.i32(rect.y)
                writer.i32(rect.width)
                writer.i32(rect.height)
            }
            writer.bytes(frame.accessUnit)
        case .mouseMove(let move):
            writePrefix(move.prefix, into: &writer)
            writer.f32(move.xPx)
            writer.f32(move.yPx)
        case .mouseButton(let button):
            writePrefix(button.prefix, into: &writer)
            writer.f32(button.xPx)
            writer.f32(button.yPx)
            writer.u8(button.button)
            writer.u8(button.action)
            writer.u16(0)
        case .wheel(let wheel):
            writePrefix(wheel.prefix, into: &writer)
            writer.f32(wheel.xPx)
            writer.f32(wheel.yPx)
            writer.f32(wheel.deltaX)
            writer.f32(wheel.deltaY)
            writer.u8(wheel.unit)
            writer.u8(0)
            writer.u8(0)
            writer.u8(0)
        case .key(let key):
            writePrefix(key.prefix, into: &writer)
            writer.u16(key.keycode)
            writer.u8(key.action)
            writer.u8(key.modifiers)
            writer.u32(key.utf32)
        }
        return writer.data
    }

    static func decode(type: UInt16, flags: UInt16, body: Data) throws -> NearMessage {
        guard flags == 0 else { throw ProtocolError.malformed }
        guard let messageType = MessageType(rawValue: type) else { throw ProtocolError.unknownType(type) }
        var cursor = ByteCursor(body)
        let message: NearMessage
        switch messageType {
        case .hello:
            let major = try cursor.u16()
            let minor = try cursor.u16()
            let role = try cursor.u8()
            let nameLen = Int(try cursor.u8())
            guard (0...64).contains(nameLen) else { throw ProtocolError.malformed }
            let nameData = try cursor.bytes(nameLen)
            guard let name = String(data: nameData, encoding: .utf8) else { throw ProtocolError.malformed }
            message = .hello(Hello(major: major, minor: minor, role: role, name: name))
        case .authPassword:
            let length = Int(try cursor.u16())
            guard (1...128).contains(length) else { throw ProtocolError.malformed }
            message = .authPassword(AuthPassword(password: try cursor.bytes(length)))
        case .authResult:
            let ok = try cursor.u8()
            let reason = try cursor.u8()
            guard try cursor.u16() == 0 else { throw ProtocolError.malformed }
            guard ok == 0 || ok == 1 else { throw ProtocolError.malformed }
            message = .authResult(AuthResult(ok: ok == 1, reason: reason))
        case .displayList:
            let count = Int(try cursor.u16())
            guard try cursor.u16() == 0 else { throw ProtocolError.malformed }
            var displays: [RemoteDisplay] = []
            displays.reserveCapacity(count)
            for _ in 0..<count {
                let display = RemoteDisplay(
                    displayID: try cursor.u32(),
                    originX: try cursor.i32(),
                    originY: try cursor.i32(),
                    widthPx: try cursor.u32(),
                    heightPx: try cursor.u32(),
                    scaleNum: try cursor.u32(),
                    scaleDen: try cursor.u32()
                )
                guard display.scaleDen != 0 else { throw ProtocolError.malformed }
                displays.append(display)
            }
            message = .displayList(DisplayList(displays: displays))
        case .selectDisplay:
            message = .selectDisplay(SelectDisplay(displayID: try cursor.u32()))
        case .videoConfig:
            let config = VideoConfig(
                encoderConfigID: try cursor.u16(),
                channelID: try cursor.u8(),
                codec: try cursor.u8(),
                displayID: try cursor.u32(),
                codedWidth: try cursor.u16(),
                codedHeight: try cursor.u16(),
                fpsNum: try cursor.u16(),
                fpsDen: try cursor.u16(),
                chroma: try cursor.u8(),
                paramSets: Data()
            )
            guard try cursor.u8() == 0 else { throw ProtocolError.malformed }
            let paramLen = Int(try cursor.u16())
            var filled = config
            filled.paramSets = try cursor.bytes(paramLen)
            guard filled.encoderConfigID != 0, filled.chroma == 1 else { throw ProtocolError.malformed }
            message = .videoConfig(filled)
        case .videoFrame:
            let frameID = try cursor.u64()
            let configID = try cursor.u16()
            let channel = try cursor.u8()
            let flagsByte = try cursor.u8()
            let rectCount = Int(try cursor.u16())
            guard try cursor.u16() == 0 else { throw ProtocolError.malformed }
            let capture = try cursor.u64()
            let auLen = Int(try cursor.u32())
            guard configID != 0, (0...64).contains(rectCount) else { throw ProtocolError.malformed }
            if flagsByte & FrameFlag.dirtyNone != 0, rectCount != 0 { throw ProtocolError.malformed }
            var rects: [NdRect] = []
            rects.reserveCapacity(rectCount)
            for _ in 0..<rectCount {
                let rect = NdRect(x: try cursor.i32(), y: try cursor.i32(), width: try cursor.i32(), height: try cursor.i32())
                guard rect.width > 0, rect.height > 0 else { throw ProtocolError.malformed }
                rects.append(rect)
            }
            let au = try cursor.bytes(auLen)
            message = .videoFrame(VideoFrame(
                frameID: frameID,
                encoderConfigID: configID,
                channelID: channel,
                frameFlags: flagsByte,
                captureMono: capture,
                rects: rects,
                accessUnit: au
            ))
        case .mouseMove:
            let prefix = try readPrefix(&cursor)
            message = .mouseMove(MouseMove(prefix: prefix, xPx: try cursor.f32(), yPx: try cursor.f32()))
        case .mouseButton:
            let prefix = try readPrefix(&cursor)
            let x = try cursor.f32()
            let y = try cursor.f32()
            let button = try cursor.u8()
            let action = try cursor.u8()
            guard try cursor.u16() == 0 else { throw ProtocolError.malformed }
            message = .mouseButton(MouseButton(prefix: prefix, xPx: x, yPx: y, button: button, action: action))
        case .wheel:
            let prefix = try readPrefix(&cursor)
            let x = try cursor.f32()
            let y = try cursor.f32()
            let dx = try cursor.f32()
            let dy = try cursor.f32()
            let unit = try cursor.u8()
            guard try cursor.u8() == 0, try cursor.u8() == 0, try cursor.u8() == 0 else { throw ProtocolError.malformed }
            message = .wheel(Wheel(prefix: prefix, xPx: x, yPx: y, deltaX: dx, deltaY: dy, unit: unit))
        case .key:
            let prefix = try readPrefix(&cursor)
            message = .key(KeyEvent(
                prefix: prefix,
                keycode: try cursor.u16(),
                action: try cursor.u8(),
                modifiers: try cursor.u8(),
                utf32: try cursor.u32()
            ))
        }
        try cursor.expectExhausted()
        return message
    }

    private static func writePrefix(_ prefix: InputPrefix, into writer: inout ByteWriter) {
        writer.u64(prefix.eventID)
        writer.u64(prefix.eventMono)
        writer.u32(prefix.displayID)
    }

    private static func readPrefix(_ cursor: inout ByteCursor) throws -> InputPrefix {
        InputPrefix(eventID: try cursor.u64(), eventMono: try cursor.u64(), displayID: try cursor.u32())
    }
}

public enum Wire {
    public static func encode(_ message: NearMessage) throws -> Data {
        let body = try WireEncoding.encodeBody(message)
        var writer = ByteWriter()
        writer.u32(UInt32(4 + body.count))
        writer.u16(message.type.rawValue)
        writer.u16(0)
        writer.bytes(body)
        return writer.data
    }
}

/// Incremental reader for one QUIC stream. Preface first, then messages.
public final class FrameDecoder {
    public private(set) var preface: Preface?
    private var buffer = Data()
    private var offset = 0
    private var messages: [NearMessage] = []

    public init() {}

    public func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        buffer.append(data)
        try parse()
    }

    public func pop() -> NearMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    private func parse() throws {
        if preface == nil {
            guard available >= 8 else { return }
            let bytes = consume(8)
            preface = try Preface.decode(bytes)
        }
        while available >= 4 {
            let length = peekU32()
            if length < 4 { throw ProtocolError.bodyLength }
            if length > NearDeskWire.maxBodyLength { throw ProtocolError.bodyLength }
            let total = 4 + Int(length)
            guard available >= total else { return }
            _ = consume(4)
            let rest = consume(Int(length))
            var cursor = ByteCursor(rest)
            let type = try cursor.u16()
            let flags = try cursor.u16()
            let body = rest.subdata(in: (rest.startIndex + 4)..<rest.endIndex)
            guard let kind = preface?.kind else { throw ProtocolError.badPreface }
            let message = try WireEncoding.decode(type: type, flags: flags, body: body)
            guard message.allowed(on: kind) else { throw ProtocolError.wrongStream(type) }
            messages.append(message)
        }
        compact()
    }

    private var available: Int { buffer.count - offset }

    private func peekU32() -> UInt32 {
        let start = buffer.startIndex + offset
        let b0 = UInt32(buffer[start])
        let b1 = UInt32(buffer[start + 1])
        let b2 = UInt32(buffer[start + 2])
        let b3 = UInt32(buffer[start + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func consume(_ count: Int) -> Data {
        let start = buffer.startIndex + offset
        let out = buffer.subdata(in: start..<(start + count))
        offset += count
        return out
    }

    private func compact() {
        if offset > 64 * 1024 && offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
    }
}
