// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import NearDeskCore

final class TileRoutingTests: XCTestCase {
    private let codedWidth = 1728
    private let codedHeight = 1080

    func testDocExamples() {
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 3, height: 28)), .tile)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 640, height: 32)), .tile)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 1024, height: 32)), .tile)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 1024, height: 33)), .lossy)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 1728, height: 75)), .lossy)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 800, height: 600)), .lossy)
        XCTAssertEqual(route(NdRect(x: -1, y: 0, width: 10, height: 10)), .lossy)
        XCTAssertEqual(route(NdRect(x: 1720, y: 0, width: 20, height: 10)), .lossy)
        XCTAssertEqual(route(NdRect(x: 0, y: 0, width: 2049, height: 1), codedWidth: 4096, codedHeight: 64), .lossy)
    }

    func testSmallestTilesAreAdmittedFirst() {
        let large = NdRect(x: 0, y: 0, width: 100, height: 100)
        let small = NdRect(x: 5, y: 9, width: 4, height: 4)
        let plan = steady(DirtyEncode(rects: [large, small], flags: 0))
        XCTAssertEqual(plan?.tileRects, [small, large])
        XCTAssertEqual(plan?.sendsLossy, false)
    }

    func testCaptureAreaSendsTheWholeBatchLossy() {
        let pair = steady(DirtyEncode(rects: [
            NdRect(x: 0, y: 0, width: 110, height: 100),
            NdRect(x: 0, y: 100, width: 110, height: 100),
        ], flags: 0))
        XCTAssertEqual(pair?.sendsTile, false)
        XCTAssertEqual(pair?.sendsLossy, true)
        XCTAssertEqual(pair?.lossyRects.count, 2)

        var typing: [NdRect] = []
        for index in 0..<8 {
            typing.append(NdRect(x: Int32(index * 100), y: 0, width: 90, height: 90))
        }
        let measured = steady(DirtyEncode(rects: typing, flags: 0))
        XCTAssertEqual(measured?.sendsTile, false)
        XCTAssertEqual(measured?.sendsLossy, true)
        XCTAssertEqual(measured?.tileRects.count, 0)
        XCTAssertEqual(measured?.lossyRects.count, 8)
        let pixels = typing.reduce(0) { $0 + Int($1.width) * Int($1.height) }
        XCTAssertGreaterThan(pixels, Int(TileBudget.captureAreaMax))
        XCTAssertEqual(pixels * 4, 259_200)
    }

    func testCaretBesideLargeMotionStaysATile() {
        let plan = steady(DirtyEncode(rects: [
            NdRect(x: 0, y: 0, width: 3, height: 28),
            NdRect(x: 0, y: 40, width: 800, height: 600),
        ], flags: 0))
        XCTAssertEqual(plan?.tileRects, [NdRect(x: 0, y: 0, width: 3, height: 28)])
        XCTAssertEqual(plan?.lossyRects.count, 1)
        XCTAssertEqual(plan?.sendsTile, true)
        XCTAssertEqual(plan?.sendsLossy, true)
    }

    func testModestClusterStaysTiles() {
        var rects: [NdRect] = []
        for index in 0..<4 {
            rects.append(NdRect(x: Int32(index * 40), y: 0, width: 40, height: 40))
        }
        let plan = steady(DirtyEncode(rects: rects, flags: 0))
        XCTAssertEqual(plan?.tileRects.count, 4)
        XCTAssertEqual(plan?.sendsLossy, false)
        let pixels = rects.reduce(0) { $0 + Int($1.width) * Int($1.height) }
        XCTAssertLessThanOrEqual(pixels, Int(TileBudget.captureAreaMax))
    }

    func testCountOverflowsTheRest() {
        var rects: [NdRect] = []
        for index in 0..<9 {
            rects.append(NdRect(x: Int32(index), y: 0, width: 2, height: 2))
        }
        let plan = steady(DirtyEncode(rects: rects, flags: 0))
        XCTAssertEqual(plan?.tileRects.count, TileBudget.maxCount)
        XCTAssertEqual(plan?.lossyRects.count, 1)
    }

    func testCoalescedBoxStaysWhole() {
        let small = DirtyEncode(rects: [NdRect(x: 10, y: 10, width: 40, height: 20)], flags: FrameFlag.dirtyCoalesced)
        let tiled = steady(small)
        XCTAssertEqual(tiled?.tileFlags, FrameFlag.dirtyCoalesced)
        XCTAssertEqual(tiled?.sendsLossy, false)

        let large = DirtyEncode(rects: [NdRect(x: 0, y: 0, width: 800, height: 600)], flags: FrameFlag.dirtyCoalesced)
        let lossy = steady(large)
        XCTAssertEqual(lossy?.tileRects.count, 0)
        XCTAssertEqual(lossy?.lossyFlags, FrameFlag.dirtyCoalesced)
    }

    func testManyRectsCoalesceBeforeTheAreaChoice() {
        var many: [CGRect] = []
        for index in 0..<70 {
            many.append(CGRect(x: index * 30, y: 0, width: 20, height: 40))
        }
        let packed = encodeDirtyRects(many, hadMetadata: true)
        let plan = steady(packed)
        XCTAssertEqual(plan?.tileRects.count, 0)
        XCTAssertEqual(plan?.lossyRects.count, 1)
        XCTAssertEqual(plan?.lossyFlags, FrameFlag.dirtyCoalesced)
    }

    func testEmptyMetadataSkipsAfterTheKeyframe() {
        let packed = encodeDirtyRects([], hadMetadata: true)
        XCTAssertNil(steady(packed))
        let first = planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: false,
            lossyFramesSent: 0,
            geometryChanged: true
        )
        XCTAssertEqual(first?.sendsTile, false)
        XCTAssertEqual(first?.sendsLossy, true)
        XCTAssertEqual(first?.lossyFlags, FrameFlag.keyframe)
        XCTAssertEqual(first?.lossyRects.isEmpty, true)
    }

    func testDirtyNoneStaysLossy() {
        let plan = steady(DirtyEncode(rects: [], flags: FrameFlag.dirtyNone))
        XCTAssertEqual(plan?.sendsTile, false)
        XCTAssertEqual(plan?.sendsLossy, true)
        XCTAssertEqual(plan?.lossyFlags, FrameFlag.dirtyNone)
    }

    func testFirstSmallCaptureStillSendsALossyKeyframe() {
        let packed = DirtyEncode(rects: [NdRect(x: 0, y: 0, width: 3, height: 28)], flags: 0)
        let plan = planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: false,
            lossyFramesSent: 0,
            geometryChanged: true
        )
        XCTAssertEqual(plan?.sendsTile, true)
        XCTAssertEqual(plan?.sendsLossy, true)
        XCTAssertEqual(plan?.lossyFlags, FrameFlag.keyframe)
        XCTAssertEqual(plan?.lossyRects.isEmpty, true)
        XCTAssertEqual(plan?.tileRects.count, 1)
    }

    func testKeyframeIntervalCountsSentLossyFrames() {
        let packed = DirtyEncode(rects: [NdRect(x: 0, y: 0, width: 800, height: 600)], flags: 0)
        let routine = planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: true,
            lossyFramesSent: 119,
            geometryChanged: false
        )
        XCTAssertEqual((routine?.lossyFlags ?? 0) & FrameFlag.keyframe, 0)
        let boundary = planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: true,
            lossyFramesSent: 120,
            geometryChanged: false
        )
        XCTAssertEqual((boundary?.lossyFlags ?? 0) & FrameFlag.keyframe, FrameFlag.keyframe)
        let moved = planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: true,
            lossyFramesSent: 4,
            geometryChanged: true
        )
        XCTAssertEqual((moved?.lossyFlags ?? 0) & FrameFlag.keyframe, FrameFlag.keyframe)
    }

    private func steady(_ packed: DirtyEncode) -> CapturePlan? {
        planCapture(
            packed,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: true,
            lossyFramesSent: 3,
            geometryChanged: false
        )
    }

    private func route(_ rect: NdRect, codedWidth: Int? = nil, codedHeight: Int? = nil) -> Route {
        let width = codedWidth ?? self.codedWidth
        let height = codedHeight ?? self.codedHeight
        let plan = planCapture(
            DirtyEncode(rects: [rect], flags: 0),
            codedWidth: width,
            codedHeight: height,
            hasLossyKeyframe: true,
            lossyFramesSent: 3,
            geometryChanged: false
        )
        guard let plan else { return .none }
        if plan.sendsTile && !plan.sendsLossy { return .tile }
        if plan.sendsLossy && !plan.sendsTile { return .lossy }
        return .both
    }

    private enum Route {
        case tile
        case lossy
        case both
        case none
    }
}


final class DirtyRectsAttachmentTests: XCTestCase {
    func testMissingAttachmentIsDirtyNone() {
        let parsed = parseDirtyRectsAttachment(nil)
        XCTAssertFalse(parsed.hadMetadata)
        XCTAssertNil(parsed.rects)
        let packed = encodeDirtyRectsAttachment(nil)
        XCTAssertEqual(packed.flags, FrameFlag.dirtyNone)
        XCTAssertTrue(packed.rects.isEmpty)
    }

    func testNSValueArray() {
        let values = [
            NSValue(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
            NSValue(rect: CGRect(x: 10, y: 20, width: 5, height: 6)),
        ]
        let parsed = parseDirtyRectsAttachment(values)
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertEqual(parsed.rects?.count, 2)
        XCTAssertEqual(parsed.rects?[0], CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(parsed.rects?[1], CGRect(x: 10, y: 20, width: 5, height: 6))
    }

    func testCGRectArray() {
        let rects = [CGRect(x: 0, y: 0, width: 8, height: 9)]
        let parsed = parseDirtyRectsAttachment(rects)
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertEqual(parsed.rects, rects)
    }

    func testDictionaryShapedRectsNeoStyle() {
        let payload: [[String: NSNumber]] = [
            ["X": 12, "Y": 34, "Width": 56, "Height": 78],
            ["X": 0, "Y": 1, "Width": 2, "Height": 3],
        ]
        let parsed = parseDirtyRectsAttachment(payload)
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertEqual(parsed.rects?.count, 2)
        XCTAssertEqual(parsed.rects?[0], CGRect(x: 12, y: 34, width: 56, height: 78))
        XCTAssertEqual(parsed.rects?[1], CGRect(x: 0, y: 1, width: 2, height: 3))
        let packed = encodeDirtyRectsAttachment(payload)
        XCTAssertEqual(packed.flags, 0)
        XCTAssertEqual(packed.rects.count, 2)
        XCTAssertEqual(packed.rects[0], NdRect(x: 12, y: 34, width: 56, height: 78))
    }

    func testEmptyPresentArrayIsNotDirtyNone() {
        let parsed = parseDirtyRectsAttachment([Any]())
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertEqual(parsed.rects?.isEmpty, true)
        let packed = encodeDirtyRectsAttachment([Any]())
        XCTAssertEqual(packed.flags, 0)
        XCTAssertTrue(packed.rects.isEmpty)
    }

    func testUnrecognizedShapeKeepsMetadata() {
        let parsed = parseDirtyRectsAttachment("not-rects")
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertNil(parsed.rects)
        let packed = encodeDirtyRectsAttachment("not-rects")
        XCTAssertEqual(packed.flags, 0)
        XCTAssertTrue(packed.rects.isEmpty)
    }

    func testNSArrayOfDictionaries() {
        let array: NSArray = [
            ["X": 4, "Y": 5, "Width": 6, "Height": 7] as NSDictionary,
        ]
        let parsed = parseDirtyRectsAttachment(array)
        XCTAssertTrue(parsed.hadMetadata)
        XCTAssertEqual(parsed.rects?.first, CGRect(x: 4, y: 5, width: 6, height: 7))
    }
}

final class TileWireTests: XCTestCase {
    func testLosslessConfigAndTileRoundTrip() throws {
        let config = VideoConfig(
            encoderConfigID: 2,
            channelID: ChannelID.losslessTile,
            codec: CodecID.rawBGRA,
            displayID: 7,
            codedWidth: 32,
            codedHeight: 16,
            chroma: 0,
            paramSets: Data()
        )
        let frame = VideoFrame(
            frameID: 4,
            encoderConfigID: 2,
            channelID: ChannelID.losslessTile,
            frameFlags: FrameFlag.dirtyCoalesced,
            captureMono: 90,
            rects: [NdRect(x: 1, y: 2, width: 2, height: 1)],
            accessUnit: Data([0, 0, 255, 0xFF, 1, 2, 3, 0xFF])
        )
        XCTAssertEqual(try roundTrip(.videoConfig(config)), .videoConfig(config))
        XCTAssertEqual(try roundTrip(.videoFrame(frame)), .videoFrame(frame))
    }

    func testRejectsUnpairedConfigAndBadTiles() {
        XCTAssertThrowsError(try Wire.encode(.videoConfig(VideoConfig(
            encoderConfigID: 1,
            channelID: ChannelID.hevcMain,
            codec: CodecID.hevc,
            displayID: 1,
            codedWidth: 16,
            codedHeight: 16,
            chroma: 0,
            paramSets: Data([1])
        ))))
        XCTAssertThrowsError(try Wire.encode(.videoConfig(VideoConfig(
            encoderConfigID: 1,
            channelID: ChannelID.losslessTile,
            codec: CodecID.rawBGRA,
            displayID: 1,
            codedWidth: 16,
            codedHeight: 16,
            chroma: 1,
            paramSets: Data()
        ))))
        XCTAssertThrowsError(try Wire.encode(.videoFrame(VideoFrame(
            frameID: 1,
            encoderConfigID: 1,
            channelID: ChannelID.losslessTile,
            frameFlags: FrameFlag.keyframe,
            captureMono: 1,
            rects: [NdRect(x: 0, y: 0, width: 1, height: 1)],
            accessUnit: Data([0, 0, 0, 0xFF])
        ))))
        XCTAssertThrowsError(try Wire.encode(.videoFrame(VideoFrame(
            frameID: 1,
            encoderConfigID: 1,
            channelID: ChannelID.losslessTile,
            frameFlags: 0,
            captureMono: 1,
            rects: [NdRect(x: 0, y: 0, width: 1, height: 1)],
            accessUnit: Data([0, 0, 0])
        ))))
        XCTAssertThrowsError(try Wire.encode(.videoFrame(VideoFrame(
            frameID: 1,
            encoderConfigID: 1,
            channelID: ChannelID.losslessTile,
            frameFlags: 0,
            captureMono: 1,
            rects: [],
            accessUnit: Data()
        ))))
    }

    private func roundTrip(_ message: NearMessage) throws -> NearMessage {
        let decoder = FrameDecoder()
        try decoder.append(Preface(kind: .video).encode())
        try decoder.append(Wire.encode(message))
        guard let decoded = decoder.pop() else {
            XCTFail("missing message")
            throw ProtocolError.malformed
        }
        return decoded
    }
}

final class TileComposeTests: XCTestCase {
    func testTileCopiesForceOpaqueAlpha() throws {
        let source = try makeBGRA(width: 4, height: 2, fill: [0, 0, 0, 0])
        paint(source, x: 1, y: 0, pixel: [1, 2, 3, 0])
        let copied = try XCTUnwrap(copyCompactBGRA(from: source, rects: [NdRect(x: 1, y: 0, width: 1, height: 1)]))
        XCTAssertEqual([UInt8](copied), [1, 2, 3, 0xFF])
    }

    func testTilesStaySharpOverLaterBase() throws {
        let compositor = TileCompositor()
        try compositor.apply(lossyConfig(id: 1))
        try compositor.apply(tileConfig(id: 2))

        let tile = tileFrame(id: 1, rect: NdRect(x: 0, y: 0, width: 2, height: 2), pixel: [0, 0, 255, 0])
        try compositor.validate(tile)
        let first = try XCTUnwrap(try compositor.compositeTile(tile))
        XCTAssertTrue(first.recordLatency)
        XCTAssertEqual(pixel(first.pixelBuffer, 0, 0), [0, 0, 255, 0xFF])
        XCTAssertEqual(pixel(first.pixelBuffer, 4, 4), [0, 0, 0, 0xFF])

        let base = lossyFrame(id: 1, flags: FrameFlag.keyframe, rects: [])
        try compositor.validate(base)
        let keyed = try XCTUnwrap(try compositor.compositeLossy(base, decoded: try makeBGRA(width: 8, height: 8, fill: [0, 255, 0, 0xFF])))
        XCTAssertFalse(keyed.recordLatency)
        XCTAssertEqual(pixel(keyed.pixelBuffer, 0, 0), [0, 0, 255, 0xFF])
        XCTAssertEqual(pixel(keyed.pixelBuffer, 4, 4), [0, 255, 0, 0xFF])

        let caret = tileFrame(id: 2, rect: NdRect(x: 6, y: 6, width: 2, height: 2), pixel: [255, 0, 0, 0xFF])
        try compositor.validate(caret)
        let typed = try XCTUnwrap(try compositor.compositeTile(caret))
        XCTAssertEqual(pixel(typed.pixelBuffer, 6, 6), [255, 0, 0, 0xFF])
        XCTAssertEqual(pixel(typed.pixelBuffer, 0, 0), [0, 0, 255, 0xFF])

        let motion = lossyFrame(id: 3, flags: 0, rects: [NdRect(x: 0, y: 0, width: 2, height: 2)])
        try compositor.validate(motion)
        let moved = try XCTUnwrap(try compositor.compositeLossy(motion, decoded: try makeBGRA(width: 8, height: 8, fill: [255, 255, 255, 0xFF])))
        XCTAssertEqual(pixel(moved.pixelBuffer, 0, 0), [255, 255, 255, 0xFF])
        XCTAssertEqual(pixel(moved.pixelBuffer, 6, 6), [255, 0, 0, 0xFF])

        let cleared = lossyFrame(id: 4, flags: FrameFlag.dirtyNone, rects: [])
        try compositor.validate(cleared)
        let none = try XCTUnwrap(try compositor.compositeLossy(cleared, decoded: try makeBGRA(width: 8, height: 8, fill: [1, 2, 3, 0xFF])))
        XCTAssertEqual(pixel(none.pixelBuffer, 6, 6), [1, 2, 3, 0xFF])
        XCTAssertEqual(pixel(none.pixelBuffer, 0, 0), [1, 2, 3, 0xFF])
    }

    func testLossyBeforeSameIDTileResets() throws {
        let compositor = TileCompositor()
        try compositor.apply(lossyConfig(id: 1))
        try compositor.apply(tileConfig(id: 2))
        try compositor.validate(lossyFrame(id: 5, flags: FrameFlag.keyframe, rects: []))
        XCTAssertThrowsError(try compositor.validate(tileFrame(id: 5, rect: NdRect(x: 0, y: 0, width: 1, height: 1), pixel: [0, 0, 0, 0xFF]))) { error in
            XCTAssertEqual(error as? ProtocolError, .malformed)
        }
    }

    func testDecreasingFrameIDResets() throws {
        let compositor = TileCompositor()
        try compositor.apply(lossyConfig(id: 1))
        try compositor.validate(lossyFrame(id: 3, flags: FrameFlag.dirtyNone, rects: []))
        XCTAssertThrowsError(try compositor.validate(lossyFrame(id: 2, flags: 0, rects: [NdRect(x: 0, y: 0, width: 1, height: 1)]))) { error in
            XCTAssertEqual(error as? ProtocolError, .malformed)
        }
    }

    func testTileCannotCiteTheLossyConfig() throws {
        let compositor = TileCompositor()
        try compositor.apply(lossyConfig(id: 1))
        try compositor.apply(tileConfig(id: 2))
        var frame = tileFrame(id: 1, rect: NdRect(x: 0, y: 0, width: 1, height: 1), pixel: [0, 0, 0, 0xFF])
        frame.encoderConfigID = 1
        XCTAssertThrowsError(try compositor.validate(frame)) { error in
            XCTAssertEqual(error as? ProtocolError, .malformed)
        }
    }

    func testGeometryChangeDropsOldTiles() throws {
        let compositor = TileCompositor()
        try compositor.apply(lossyConfig(id: 1))
        try compositor.apply(tileConfig(id: 2))
        let tile = tileFrame(id: 1, rect: NdRect(x: 0, y: 0, width: 2, height: 2), pixel: [0, 0, 255, 0xFF])
        try compositor.validate(tile)
        _ = try compositor.compositeTile(tile)
        try compositor.apply(lossyConfig(id: 3, width: 10))
        try compositor.apply(tileConfig(id: 4, width: 10))
        let replacement = tileFrame(id: 2, rect: NdRect(x: 0, y: 0, width: 1, height: 1), pixel: [255, 0, 0, 0xFF], configID: 4)
        try compositor.validate(replacement)
        let picture = try XCTUnwrap(try compositor.compositeTile(replacement))
        XCTAssertEqual(pixel(picture.pixelBuffer, 0, 0), [255, 0, 0, 0xFF])
        XCTAssertEqual(pixel(picture.pixelBuffer, 3, 0), [0, 0, 0, 0xFF])
    }

    func testTransferFeedsHEVC() async throws {
        let transfer = PixelTransfer()
        defer { transfer.reset() }
        let source = try makeBGRA(width: 64, height: 48, fill: [20, 40, 60, 0xFF])
        let yuv = try XCTUnwrap(transfer.toFullRange420(source, width: 64, height: 48))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(yuv), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let encoder = VideoEncoder()
        try encoder.start(width: 64, height: 48)
        defer { encoder.stop() }
        let encoded = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EncodedAccessUnit, Error>) in
            encoder.encode(yuv, forceKey: true) { cont.resume(with: $0) }
        }
        XCTAssertTrue(encoded.isKeyframe)
        XCTAssertFalse(encoded.annexB.isEmpty)
    }

    private func lossyConfig(id: UInt16, width: UInt16 = 8) -> VideoConfig {
        VideoConfig(
            encoderConfigID: id,
            channelID: ChannelID.hevcMain,
            codec: CodecID.hevc,
            displayID: 7,
            codedWidth: width,
            codedHeight: 8,
            paramSets: Data([0, 0, 0, 1, 0x40])
        )
    }

    private func tileConfig(id: UInt16, width: UInt16 = 8) -> VideoConfig {
        VideoConfig(
            encoderConfigID: id,
            channelID: ChannelID.losslessTile,
            codec: CodecID.rawBGRA,
            displayID: 7,
            codedWidth: width,
            codedHeight: 8,
            chroma: 0,
            paramSets: Data()
        )
    }

    private func tileFrame(id: UInt64, rect: NdRect, pixel: [UInt8], configID: UInt16 = 2) -> VideoFrame {
        var bytes = Data()
        let count = Int(rect.width) * Int(rect.height)
        for _ in 0..<count {
            bytes.append(contentsOf: pixel)
        }
        return VideoFrame(
            frameID: id,
            encoderConfigID: configID,
            channelID: ChannelID.losslessTile,
            frameFlags: 0,
            captureMono: id,
            rects: [rect],
            accessUnit: bytes
        )
    }

    private func lossyFrame(id: UInt64, flags: UInt8, rects: [NdRect]) -> VideoFrame {
        VideoFrame(
            frameID: id,
            encoderConfigID: 1,
            channelID: ChannelID.hevcMain,
            frameFlags: flags,
            captureMono: id,
            rects: rects,
            accessUnit: Data([0, 0, 0, 1, 0x26])
        )
    }
}

private func makeBGRA(width: Int, height: Int, fill: [UInt8]) throws -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer
    )
    XCTAssertEqual(status, kCVReturnSuccess)
    let image = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    if let base = CVPixelBufferGetBaseAddress(image) {
        let stride = CVPixelBufferGetBytesPerRow(image)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * stride + x * 4
                pixels[index] = fill[0]
                pixels[index + 1] = fill[1]
                pixels[index + 2] = fill[2]
                pixels[index + 3] = fill[3]
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
}

private func paint(_ buffer: CVPixelBuffer, x: Int, y: Int, pixel: [UInt8]) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let index = y * stride + x * 4
    pixels[index] = pixel[0]
    pixels[index + 1] = pixel[1]
    pixels[index + 2] = pixel[2]
    pixels[index + 3] = pixel[3]
}

private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let index = y * stride + x * 4
    return [base[index], base[index + 1], base[index + 2], base[index + 3]]
}
