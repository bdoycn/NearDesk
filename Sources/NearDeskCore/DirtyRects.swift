// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

public struct DirtyEncode: Equatable {
    public var rects: [NdRect]
    public var flags: UInt8

    public init(rects: [NdRect], flags: UInt8) {
        self.rects = rects
        self.flags = flags
    }
}

/// ScreenCaptureKit rects are in capture-buffer pixels. More than 64 become one box.
public func encodeDirtyRects(_ input: [CGRect]?, hadMetadata: Bool) -> DirtyEncode {
    guard hadMetadata else {
        return DirtyEncode(rects: [], flags: FrameFlag.dirtyNone)
    }
    var rects: [NdRect] = []
    for raw in input ?? [] {
        let width = Int32(raw.width.rounded())
        let height = Int32(raw.height.rounded())
        if width <= 0 || height <= 0 { continue }
        rects.append(NdRect(
            x: Int32(raw.origin.x.rounded()),
            y: Int32(raw.origin.y.rounded()),
            width: width,
            height: height
        ))
    }
    if rects.count > 64 {
        return DirtyEncode(rects: [boundingBox(rects)], flags: FrameFlag.dirtyCoalesced)
    }
    return DirtyEncode(rects: rects, flags: 0)
}

public struct CapturePlan: Equatable {
    public var tileRects: [NdRect]
    public var tileFlags: UInt8
    public var lossyRects: [NdRect]
    public var lossyFlags: UInt8
    public var sendsTile: Bool
    public var sendsLossy: Bool

    public init(
        tileRects: [NdRect],
        tileFlags: UInt8,
        lossyRects: [NdRect],
        lossyFlags: UInt8,
        sendsTile: Bool,
        sendsLossy: Bool
    ) {
        self.tileRects = tileRects
        self.tileFlags = tileFlags
        self.lossyRects = lossyRects
        self.lossyFlags = lossyFlags
        self.sendsTile = sendsTile
        self.sendsLossy = sendsLossy
    }
}

/// Split one packed dirty list. `nil` means this capture sends nothing.
public func planCapture(
    _ packed: DirtyEncode,
    codedWidth: Int,
    codedHeight: Int,
    hasLossyKeyframe: Bool,
    lossyFramesSent: UInt64,
    geometryChanged: Bool
) -> CapturePlan? {
    let split = splitTiles(packed, codedWidth: codedWidth, codedHeight: codedHeight)
    let sendsTile = !split.tileRects.isEmpty
    let forcedLossy = !hasLossyKeyframe || geometryChanged
    let sendsLossy = split.lossyKind != .omit || forcedLossy
    guard sendsTile || sendsLossy else { return nil }
    var lossyFlags = sendsLossy ? split.lossyFlags : 0
    if sendsLossy && (forcedLossy || lossyFramesSent % TileBudget.lossyKeyframeInterval == 0) {
        lossyFlags |= FrameFlag.keyframe
    }
    return CapturePlan(
        tileRects: split.tileRects,
        tileFlags: split.tileFlags,
        lossyRects: sendsLossy ? split.lossyRects : [],
        lossyFlags: lossyFlags,
        sendsTile: sendsTile,
        sendsLossy: sendsLossy
    )
}

private enum LossyKind {
    case dirtyNone
    case omit
    case listed
}

private struct TileSplit {
    var tileRects: [NdRect]
    var tileFlags: UInt8
    var lossyRects: [NdRect]
    var lossyFlags: UInt8
    var lossyKind: LossyKind
}

private func splitTiles(_ packed: DirtyEncode, codedWidth: Int, codedHeight: Int) -> TileSplit {
    if packed.flags & FrameFlag.dirtyNone != 0 {
        return TileSplit(tileRects: [], tileFlags: 0, lossyRects: [], lossyFlags: FrameFlag.dirtyNone, lossyKind: .dirtyNone)
    }
    if packed.rects.isEmpty {
        return TileSplit(tileRects: [], tileFlags: 0, lossyRects: [], lossyFlags: 0, lossyKind: .omit)
    }
    var candidates: [NdRect] = []
    var lossyRects: [NdRect] = []
    for rect in packed.rects {
        if isSmallTile(rect, codedWidth: codedWidth, codedHeight: codedHeight) {
            candidates.append(rect)
        } else {
            lossyRects.append(rect)
        }
    }
    let (admitted, overflow) = admitTiles(candidates)
    lossyRects.append(contentsOf: overflow)
    let coalesced = packed.flags & FrameFlag.dirtyCoalesced != 0
    let tileFlags: UInt8 = coalesced && !admitted.isEmpty && lossyRects.isEmpty ? FrameFlag.dirtyCoalesced : 0
    let lossyFlags: UInt8 = coalesced && admitted.isEmpty && !lossyRects.isEmpty ? FrameFlag.dirtyCoalesced : 0
    if lossyRects.isEmpty {
        return TileSplit(tileRects: admitted, tileFlags: tileFlags, lossyRects: [], lossyFlags: 0, lossyKind: .omit)
    }
    return TileSplit(
        tileRects: admitted,
        tileFlags: tileFlags,
        lossyRects: lossyRects,
        lossyFlags: lossyFlags,
        lossyKind: .listed
    )
}

private func isSmallTile(_ rect: NdRect, codedWidth: Int, codedHeight: Int) -> Bool {
    guard rect.width > 0, rect.height > 0 else { return false }
    guard rect.width <= TileBudget.edgeMax, rect.height <= TileBudget.edgeMax else { return false }
    guard rect.x >= 0, rect.y >= 0 else { return false }
    let right = Int64(rect.x) + Int64(rect.width)
    let bottom = Int64(rect.y) + Int64(rect.height)
    guard right <= Int64(codedWidth), bottom <= Int64(codedHeight) else { return false }
    let area = Int64(rect.width) * Int64(rect.height)
    guard area <= TileBudget.areaMax else { return false }
    guard area <= Int64.max / 4, area * 4 <= Int64(TileBudget.bytesMax) else { return false }
    return true
}

private func admitTiles(_ candidates: [NdRect]) -> (admitted: [NdRect], overflow: [NdRect]) {
    let sorted = candidates.sorted { lhs, rhs in
        let left = Int64(lhs.width) * Int64(lhs.height)
        let right = Int64(rhs.width) * Int64(rhs.height)
        if left != right { return left < right }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.width < rhs.width
    }
    var admitted: [NdRect] = []
    var used = 0
    for (index, rect) in sorted.enumerated() {
        let need = Int(Int64(rect.width) * Int64(rect.height) * 4)
        if admitted.count == TileBudget.maxCount || used > TileBudget.bytesMax - need {
            return (admitted, Array(sorted[index...]))
        }
        admitted.append(rect)
        used += need
    }
    return (admitted, [])
}

private func boundingBox(_ rects: [NdRect]) -> NdRect {
    var minX = Int32.max
    var minY = Int32.max
    var maxX = Int32.min
    var maxY = Int32.min
    for rect in rects {
        minX = min(minX, rect.x)
        minY = min(minY, rect.y)
        maxX = max(maxX, rect.x &+ rect.width)
        maxY = max(maxY, rect.y &+ rect.height)
    }
    return NdRect(x: minX, y: minY, width: maxX &- minX, height: maxY &- minY)
}

public func codedSize(widthPx: UInt32, heightPx: UInt32, maxWidth: Int = 1920, maxHeight: Int = 1080) -> (width: Int, height: Int) {
    let width = max(Int(widthPx), 2)
    let height = max(Int(heightPx), 2)
    let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1)
    var evenW = Int((Double(width) * scale).rounded(.down))
    var evenH = Int((Double(height) * scale).rounded(.down))
    evenW -= evenW % 2
    evenH -= evenH % 2
    return (max(evenW, 2), max(evenH, 2))
}
