// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import NearDeskCore

final class ProtocolTests: XCTestCase {
    func testPrefaceRoundTrip() throws {
        let encoded = Preface(kind: .video).encode()
        XCTAssertEqual([UInt8](encoded), [0x4E, 0x44, 0x53, 0x30, 0x02, 0x01, 0x00, 0x00])
        XCTAssertEqual(try Preface.decode(encoded).kind, .video)
    }

    func testBadPreface() {
        XCTAssertThrowsError(try Preface.decode(Data([0, 1, 2, 3, 1, 1, 0, 0]))) { error in
            XCTAssertEqual(error as? ProtocolError, .badPreface)
        }
    }

    func testControlAndInputRoundTrip() throws {
        let messages: [NearMessage] = [
            .hello(Hello(name: "Studio Mac")),
            .authPassword(AuthPassword(password: Data("secret".utf8))),
            .authResult(AuthResult(ok: false, reason: AuthResult.badPassword)),
            .displayList(DisplayList(displays: [
                RemoteDisplay(displayID: 1, originX: -100, originY: 20, widthPx: 3024, heightPx: 1964, scaleNum: 2, scaleDen: 1)
            ])),
            .selectDisplay(SelectDisplay(displayID: 7)),
            .mouseMove(MouseMove(prefix: prefix(1), xPx: 10.5, yPx: 20)),
            .mouseButton(MouseButton(prefix: prefix(2), xPx: 3, yPx: 4, button: 1, action: 1)),
            .wheel(Wheel(prefix: prefix(3), xPx: 1, yPx: 2, deltaX: -1.5, deltaY: 2, unit: 1)),
            .key(KeyEvent(prefix: prefix(4), keycode: 0, action: 3, modifiers: 0b001000, utf32: 65)),
        ]
        for message in messages {
            let decoded = try roundTrip(message, kind: message.allowed(on: .control) ? .control : .input)
            XCTAssertEqual(decoded, message)
        }
    }

    func testVideoRoundTripAndLittleEndian() throws {
        let config = VideoConfig(
            encoderConfigID: 1,
            channelID: ChannelID.hevcMain,
            codec: CodecID.hevc,
            displayID: 0x0100_0002,
            codedWidth: 1920,
            codedHeight: 1080,
            paramSets: Data([0, 0, 0, 1, 0x40, 0x01])
        )
        let frame = VideoFrame(
            frameID: 0x0102_0304_0506_0708,
            encoderConfigID: 1,
            channelID: 1,
            frameFlags: FrameFlag.keyframe | FrameFlag.dirtyCoalesced,
            captureMono: 99,
            rects: [NdRect(x: -2, y: 3, width: 8, height: 9)],
            accessUnit: Data([0, 0, 0, 1, 0x26, 0x01, 0xFF])
        )
        XCTAssertEqual(try roundTrip(.videoConfig(config), kind: .video), .videoConfig(config))
        let encoded = try Wire.encode(.videoFrame(frame))
        let bodyLength = UInt32(encoded.count - 4)
        XCTAssertEqual(encoded[encoded.startIndex], UInt8(bodyLength & 0xFF))
        let decoder = FrameDecoder()
        try decoder.append(Preface(kind: .video).encode())
        try decoder.append(encoded)
        guard case .videoFrame(let decoded) = decoder.pop() else {
            return XCTFail("expected frame")
        }
        XCTAssertEqual(decoded, frame)
        XCTAssertNil(decoder.pop())
    }

    func testShortBodyLengthCloses() throws {
        var bytes = Preface(kind: .control).encode()
        bytes.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
        let decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .bodyLength)
        }
    }

    func testUnknownTypeResetsStream() throws {
        var writer = ByteWriter()
        writer.u32(4)
        writer.u16(0x00EE)
        writer.u16(0)
        var bytes = Preface(kind: .control).encode()
        bytes.append(writer.data)
        let decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownType(0x00EE))
        }
    }

    func testWrongStream() throws {
        let bytes = Preface(kind: .input).encode() + (try Wire.encode(.hello(Hello(name: "x"))))
        let decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .wrongStream(MessageType.hello.rawValue))
        }
    }

    func testDirtyNoneRequiresEmptyRects() {
        XCTAssertThrowsError(try Wire.encode(.videoFrame(VideoFrame(
            frameID: 1,
            encoderConfigID: 1,
            channelID: 1,
            frameFlags: FrameFlag.dirtyNone,
            captureMono: 1,
            rects: [NdRect(x: 0, y: 0, width: 1, height: 1)],
            accessUnit: Data([1])
        ))))
    }

    func testPasswordNotRequiredInHelloNameClip() throws {
        let hello = Hello(name: String(repeating: "界", count: 40))
        let decoded = try roundTrip(.hello(hello), kind: .control)
        guard case .hello(let value) = decoded else { return XCTFail() }
        XCTAssertLessThanOrEqual(value.name.utf8.count, 64)
        XCTAssertFalse(value.name.utf8.contains(0))
    }

    func testGlobalPointScale() {
        let display = RemoteDisplay(
            displayID: 1, originX: 100, originY: -40, widthPx: 2000, heightPx: 1000, scaleNum: 2, scaleDen: 1
        )
        let point = display.globalPoint(xPx: 10, yPx: 20)
        XCTAssertEqual(point.x, 105, accuracy: 0.001)
        XCTAssertEqual(point.y, -30, accuracy: 0.001)
    }

    private func prefix(_ id: UInt64) -> InputPrefix {
        InputPrefix(eventID: id, eventMono: 1000 + id, displayID: 42)
    }

    private func roundTrip(_ message: NearMessage, kind: StreamKind) throws -> NearMessage {
        let decoder = FrameDecoder()
        try decoder.append(Preface(kind: kind).encode())
        try decoder.append(Wire.encode(message))
        guard let decoded = decoder.pop() else {
            XCTFail("missing message")
            throw ProtocolError.malformed
        }
        return decoded
    }
}

final class AnnexAndDirtyTests: XCTestCase {
    func testAnnexBRoundTrip() {
        let nals = [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x01, 0x01, 0x02]), Data([0x26, 0x01])]
        let annex = AnnexB.join(nals)
        XCTAssertEqual(AnnexB.split(annex), nals)
        let lengthPrefixed = AnnexB.toLengthPrefixed(annex)
        XCTAssertEqual(AnnexB.split(AnnexB.fromLengthPrefixed(lengthPrefixed)), nals)
    }

    func testThreeByteStartCode() {
        var data = Data([0x00, 0x00, 0x01, 0x67, 0x42])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE])
        XCTAssertEqual(AnnexB.split(data), [Data([0x67, 0x42]), Data([0x68, 0xCE])])
    }

    func testDirtyCoalesceAndNone() {
        let missing = encodeDirtyRects(nil, hadMetadata: false)
        XCTAssertEqual(missing.flags, FrameFlag.dirtyNone)
        XCTAssertTrue(missing.rects.isEmpty)

        var many: [CGRect] = []
        for index in 0..<65 {
            many.append(CGRect(x: index, y: 2, width: 3, height: 4))
        }
        let coalesced = encodeDirtyRects(many, hadMetadata: true)
        XCTAssertEqual(coalesced.flags, FrameFlag.dirtyCoalesced)
        XCTAssertEqual(coalesced.rects.count, 1)
        XCTAssertEqual(coalesced.rects[0].x, 0)
        XCTAssertEqual(coalesced.rects[0].width, 65 + 2)
    }

    func testCodedSizePreservesAspect() {
        let size = codedSize(widthPx: 3024, heightPx: 1964)
        XCTAssertLessThanOrEqual(size.width, 1920)
        XCTAssertLessThanOrEqual(size.height, 1080)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
        let ratio = Double(size.width) / Double(size.height)
        XCTAssertEqual(ratio, 3024.0 / 1964.0, accuracy: 0.02)
    }
}

final class IdentityTests: XCTestCase {
    func testSelfSignedIdentityRoundTrip() throws {
        let created = try SpikeIdentity.generate()
        XCTAssertEqual(created.identity.fingerprintHex.count, 64)
        XCTAssertEqual(created.identity.certificateDER.first, 0x30)
        let loaded = try SpikeIdentity.loadOrCreate()
        XCTAssertFalse(loaded.fingerprintHex.isEmpty)
        let again = try SpikeIdentity.loadOrCreate()
        XCTAssertEqual(loaded.fingerprintHex, again.fingerprintHex)
        _ = loaded.networkIdentity
    }
}
