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
