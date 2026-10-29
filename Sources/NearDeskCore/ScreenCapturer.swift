// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureError: Error {
    case permission
    case missingDisplay
    case stream(String)
}

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CMSampleBuffer, UInt64) -> Void)?
    var onStopped: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "neardesk.capture", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID) async throws -> (width: Int, height: Int) {
        if !PermissionProbe.screenRecording {
            throw CaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.missingDisplay
        }
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let excluded = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let size = codedSize(
            widthPx: UInt32(CGDisplayPixelsWide(displayID)),
            heightPx: UInt32(CGDisplayPixelsHigh(displayID))
        )
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 3
        configuration.preservesAspectRatio = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return size
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        let captured = MonoClock.nanoseconds()
        onFrame?(sampleBuffer, captured)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }
}

func dirtyEncode(from sampleBuffer: CMSampleBuffer) -> DirtyEncode {
    guard let attachment = CMGetAttachment(
        sampleBuffer,
        key: SCStreamFrameInfo.dirtyRects as CFString,
        attachmentModeOut: nil
    ) else {
        return encodeDirtyRects(nil, hadMetadata: false)
    }
    if let values = attachment as? [NSValue] {
        return encodeDirtyRects(values.map(\.rectValue), hadMetadata: true)
    }
    if let values = attachment as? [CGRect] {
        return encodeDirtyRects(values, hadMetadata: true)
    }
    return encodeDirtyRects(nil, hadMetadata: true)
}
