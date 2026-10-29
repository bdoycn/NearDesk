// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import VideoToolbox

func makePixelBufferPool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
    guard width > 0, height > 0 else { return nil }
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: NSNumber(value: format),
        kCVPixelBufferWidthKey: NSNumber(value: width),
        kCVPixelBufferHeightKey: NSNumber(value: height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    guard status == kCVReturnSuccess else { return nil }
    return pool
}

func checkoutPixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    guard status == kCVReturnSuccess else { return nil }
    return buffer
}

/// Owns a BGRA copy so ScreenCaptureKit can recycle its IOSurface.
final class BGRACloner {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    func reset() {
        pool = nil
        width = 0
        height = 0
    }

    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        if pool == nil || sourceWidth != width || sourceHeight != height {
            pool = makePixelBufferPool(width: sourceWidth, height: sourceHeight, format: kCVPixelFormatType_32BGRA)
            width = sourceWidth
            height = sourceHeight
        }
        guard let pool, let dest = checkoutPixelBuffer(from: pool) else { return nil }
        guard copyBGRA(from: source, to: dest) else { return nil }
        return dest
    }
}

final class PixelTransfer {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    func reset() {
        if let session {
            VTPixelTransferSessionInvalidate(session)
        }
        session = nil
        pool = nil
        width = 0
        height = 0
    }

    func toFullRange420(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 1, height > 1 else { return nil }
        if session == nil || width != self.width || height != self.height {
            reset()
            var created: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created) == noErr,
                  let created else { return nil }
            VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            guard let createdPool = makePixelBufferPool(
                width: width,
                height: height,
                format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ) else {
                VTPixelTransferSessionInvalidate(created)
                return nil
            }
            session = created
            pool = createdPool
            self.width = width
            self.height = height
        }
        guard let session, let pool, let dest = checkoutPixelBuffer(from: pool) else { return nil }
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: dest)
        guard status == noErr else { return nil }
        return dest
    }
}

func copyCompactBGRA(from buffer: CVPixelBuffer, rects: [NdRect]) -> Data? {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bufferWidth = CVPixelBufferGetWidth(buffer)
    let bufferHeight = CVPixelBufferGetHeight(buffer)
    guard stride >= bufferWidth * 4 else { return nil }
    guard let total = tilePayloadBytes(rects), total > 0 else { return nil }
    for rect in rects {
        let right = Int(rect.x) + Int(rect.width)
        let bottom = Int(rect.y) + Int(rect.height)
        guard rect.x >= 0, rect.y >= 0, right <= bufferWidth, bottom <= bufferHeight else { return nil }
    }
    var output = Data(count: total)
    output.withUnsafeMutableBytes { raw in
        guard var dest = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let source = base.assumingMemoryBound(to: UInt8.self)
        for rect in rects {
            let rowBytes = Int(rect.width) * 4
            for row in 0..<Int(rect.height) {
                let sourceRow = source.advanced(by: (Int(rect.y) + row) * stride + Int(rect.x) * 4)
                dest.update(from: sourceRow, count: rowBytes)
                var channel = 3
                while channel < rowBytes {
                    dest[channel] = 0xFF
                    channel += 4
                }
                dest = dest.advanced(by: rowBytes)
            }
        }
    }
    return output
}

@discardableResult
func copyBGRA(from source: CVPixelBuffer, to dest: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
          CVPixelBufferGetPixelFormatType(dest) == kCVPixelFormatType_32BGRA else { return false }
    let width = CVPixelBufferGetWidth(dest)
    let height = CVPixelBufferGetHeight(dest)
    guard CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height else { return false }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(dest, []) }
    guard let sourceBase = CVPixelBufferGetBaseAddress(source),
          let destBase = CVPixelBufferGetBaseAddress(dest) else { return false }
    let sourceStride = CVPixelBufferGetBytesPerRow(source)
    let destStride = CVPixelBufferGetBytesPerRow(dest)
    let rowBytes = width * 4
    guard sourceStride >= rowBytes, destStride >= rowBytes else { return false }
    let sourcePtr = sourceBase.assumingMemoryBound(to: UInt8.self)
    let destPtr = destBase.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
        destPtr.advanced(by: row * destStride).update(from: sourcePtr.advanced(by: row * sourceStride), count: rowBytes)
    }
    return true
}

func fillOpaqueBlack(_ buffer: CVPixelBuffer) {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard stride >= width * 4 else { return }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
        let line = pixels.advanced(by: row * stride)
        for column in 0..<width {
            let offset = column * 4
            line[offset] = 0
            line[offset + 1] = 0
            line[offset + 2] = 0
            line[offset + 3] = 0xFF
        }
    }
}

struct ComposedFrame {
    var pixelBuffer: CVPixelBuffer
    var recordLatency: Bool
}

/// HEVC/H.264 base plus lossless tiles. One latency claim per frame id.
final class TileCompositor {
    private var lossyConfig: VideoConfig?
    private var tileConfig: VideoConfig?
    private var active: PictureSize?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var base: CVPixelBuffer?
    private var overlays: [TileOverlay] = []
    private var overlaySequence = 0
    private var sawFrame = false
    private var lastFrameID: UInt64 = 0
    private var sawTile = false
    private var tileFrameID: UInt64 = 0
    private var sawLossy = false
    private var lossyFrameID: UInt64 = 0
    private var latencySet = false
    private var latencyID: UInt64 = 0

    func reset() {
        lossyConfig = nil
        tileConfig = nil
        active = nil
        pool = nil
        poolWidth = 0
        poolHeight = 0
        base = nil
        overlays.removeAll()
        overlaySequence = 0
        sawFrame = false
        lastFrameID = 0
        sawTile = false
        tileFrameID = 0
        sawLossy = false
        lossyFrameID = 0
        latencySet = false
        latencyID = 0
    }

    func apply(_ config: VideoConfig) throws {
        guard WireCheck.config(config) else { throw ProtocolError.malformed }
        let next = PictureSize(displayID: config.displayID, width: Int(config.codedWidth), height: Int(config.codedHeight))
        guard next.width > 0, next.height > 0 else { throw ProtocolError.malformed }
        if config.channelID == ChannelID.losslessTile,
           tileConfig == nil,
           let lossyConfig,
           PictureSize(lossyConfig) != next {
            throw ProtocolError.malformed
        }
        if config.channelID != ChannelID.losslessTile,
           lossyConfig == nil,
           let tileConfig,
           PictureSize(tileConfig) != next {
            throw ProtocolError.malformed
        }
        let geometryChanged = active != nil && active != next
        if geometryChanged {
            base = nil
            overlays.removeAll()
            if config.channelID == ChannelID.losslessTile {
                lossyConfig = nil
            } else {
                tileConfig = nil
            }
        }
        if config.channelID == ChannelID.losslessTile {
            if let lossyConfig, PictureSize(lossyConfig) != next { throw ProtocolError.malformed }
            tileConfig = config
        } else {
            if let tileConfig, PictureSize(tileConfig) != next { throw ProtocolError.malformed }
            lossyConfig = config
        }
        active = next
        if pool == nil || poolWidth != next.width || poolHeight != next.height {
            pool = makePixelBufferPool(width: next.width, height: next.height, format: kCVPixelFormatType_32BGRA)
            poolWidth = next.width
            poolHeight = next.height
            base = nil
        }
    }

    func validate(_ frame: VideoFrame) throws {
        guard WireCheck.frame(frame) else { throw ProtocolError.malformed }
        if sawFrame, frame.frameID < lastFrameID { throw ProtocolError.malformed }
        if frame.channelID == ChannelID.losslessTile {
            guard let tileConfig, tileConfig.encoderConfigID == frame.encoderConfigID else {
                throw ProtocolError.malformed
            }
            if sawTile, tileFrameID == frame.frameID { throw ProtocolError.malformed }
            if sawLossy, lossyFrameID == frame.frameID { throw ProtocolError.malformed }
            guard let active else { throw ProtocolError.malformed }
            for rect in frame.rects where !rectFits(rect, width: active.width, height: active.height) {
                throw ProtocolError.malformed
            }
            sawTile = true
            tileFrameID = frame.frameID
        } else {
            guard let lossyConfig,
                  lossyConfig.encoderConfigID == frame.encoderConfigID,
                  lossyConfig.channelID == frame.channelID else {
                throw ProtocolError.malformed
            }
            if sawLossy, lossyFrameID == frame.frameID { throw ProtocolError.malformed }
            sawLossy = true
            lossyFrameID = frame.frameID
        }
        sawFrame = true
        lastFrameID = frame.frameID
    }

    func compositeTile(_ frame: VideoFrame) throws -> ComposedFrame? {
        guard let total = tilePayloadBytes(frame.rects), total == frame.accessUnit.count else {
            throw ProtocolError.malformed
        }
        var offset = 0
        let start = frame.accessUnit.startIndex
        for rect in frame.rects {
            let count = Int(rect.width) * Int(rect.height) * 4
            let end = start + offset + count
            guard end <= frame.accessUnit.endIndex else { throw ProtocolError.malformed }
            overlaySequence += 1
            overlays.append(TileOverlay(
                frameID: frame.frameID,
                sequence: overlaySequence,
                rect: rect,
                pixels: frame.accessUnit.subdata(in: (start + offset)..<end)
            ))
            offset += count
        }
        guard offset == total, let buffer = render() else { return nil }
        return ComposedFrame(pixelBuffer: buffer, recordLatency: claim(frame.frameID))
    }

    func compositeLossy(_ frame: VideoFrame, decoded: CVPixelBuffer) throws -> ComposedFrame? {
        guard storeBase(decoded) else { return nil }
        if frame.frameFlags & FrameFlag.dirtyNone != 0 {
            overlays.removeAll { $0.frameID < frame.frameID }
        } else {
            overlays.removeAll { overlay in
                overlay.frameID < frame.frameID && frame.rects.contains { rectsIntersect(overlay.rect, $0) }
            }
        }
        guard let buffer = render() else { return nil }
        return ComposedFrame(pixelBuffer: buffer, recordLatency: claim(frame.frameID))
    }

    private func claim(_ frameID: UInt64) -> Bool {
        if latencySet, latencyID == frameID { return false }
        latencySet = true
        latencyID = frameID
        return true
    }

    private func storeBase(_ decoded: CVPixelBuffer) -> Bool {
        guard let pool, let dest = checkoutPixelBuffer(from: pool) else { return false }
        guard copyBGRA(from: decoded, to: dest) else { return false }
        base = dest
        return true
    }

    private func render() -> CVPixelBuffer? {
        guard let pool, let present = checkoutPixelBuffer(from: pool) else { return nil }
        if let base {
            guard copyBGRA(from: base, to: present) else { return nil }
        } else {
            fillOpaqueBlack(present)
        }
        let ordered = overlays.sorted { lhs, rhs in
            if lhs.frameID != rhs.frameID { return lhs.frameID < rhs.frameID }
            return lhs.sequence < rhs.sequence
        }
        for overlay in ordered {
            blit(overlay.pixels, rect: overlay.rect, to: present)
        }
        return present
    }
}

private struct PictureSize: Equatable {
    var displayID: UInt32
    var width: Int
    var height: Int

    init(displayID: UInt32, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
    }

    init(_ config: VideoConfig) {
        self.displayID = config.displayID
        self.width = Int(config.codedWidth)
        self.height = Int(config.codedHeight)
    }
}

private struct TileOverlay {
    var frameID: UInt64
    var sequence: Int
    var rect: NdRect
    var pixels: Data
}

private func rectFits(_ rect: NdRect, width: Int, height: Int) -> Bool {
    guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0 else { return false }
    let right = Int64(rect.x) + Int64(rect.width)
    let bottom = Int64(rect.y) + Int64(rect.height)
    return right <= Int64(width) && bottom <= Int64(height)
}

private func rectsIntersect(_ lhs: NdRect, _ rhs: NdRect) -> Bool {
    let leftRight = Int64(lhs.x) + Int64(lhs.width)
    let leftBottom = Int64(lhs.y) + Int64(lhs.height)
    let rightRight = Int64(rhs.x) + Int64(rhs.width)
    let rightBottom = Int64(rhs.y) + Int64(rhs.height)
    return Int64(lhs.x) < rightRight
        && Int64(rhs.x) < leftRight
        && Int64(lhs.y) < rightBottom
        && Int64(rhs.y) < leftBottom
}

private func blit(_ pixels: Data, rect: NdRect, to dest: CVPixelBuffer) {
    guard CVPixelBufferGetPixelFormatType(dest) == kCVPixelFormatType_32BGRA else { return }
    guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(dest, []) }
    guard let base = CVPixelBufferGetBaseAddress(dest) else { return }
    let destWidth = CVPixelBufferGetWidth(dest)
    let destHeight = CVPixelBufferGetHeight(dest)
    let stride = CVPixelBufferGetBytesPerRow(dest)
    guard rectFits(rect, width: destWidth, height: destHeight) else { return }
    let rowBytes = Int(rect.width) * 4
    guard pixels.count >= rowBytes * Int(rect.height) else { return }
    let destBase = base.assumingMemoryBound(to: UInt8.self)
    pixels.withUnsafeBytes { raw in
        guard var source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for row in 0..<Int(rect.height) {
            let destRow = destBase.advanced(by: (Int(rect.y) + row) * stride + Int(rect.x) * 4)
            destRow.update(from: source, count: rowBytes)
            var channel = 3
            while channel < rowBytes {
                destRow[channel] = 0xFF
                channel += 4
            }
            source = source.advanced(by: rowBytes)
        }
    }
}
