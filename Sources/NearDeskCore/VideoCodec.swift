// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncodedAccessUnit {
    var annexB: Data
    var isKeyframe: Bool
    var parameterSets: Data
}

enum EncoderError: Error {
    case create
    case encode(OSStatus)
}

final class VideoEncoder {
    private var session: VTCompressionSession?
    private(set) var hevc = true
    private var width = 0
    private var height = 0
    private var frameIndex: Int64 = 0
    private var cachedParameterSets = Data()

    var channelID: UInt8 { hevc ? ChannelID.hevcMain : ChannelID.h264Fallback }
    var codecID: UInt8 { hevc ? CodecID.hevc : CodecID.h264 }

    func start(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        if makeSession(codec: kCMVideoCodecType_HEVC) {
            hevc = true
            return
        }
        guard makeSession(codec: kCMVideoCodecType_H264) else { throw EncoderError.create }
        hevc = false
    }

    func stop() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKey: Bool, completion: @escaping (Result<EncodedAccessUnit, Error>) -> Void) {
        guard let session else {
            completion(.failure(EncoderError.create))
            return
        }
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 60)
        let properties: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let once = CompletionOnce<Result<EncodedAccessUnit, Error>>(completion)
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: properties,
            infoFlagsOut: &flags,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard let self else {
                    once.resume(.failure(EncoderError.create))
                    return
                }
                guard status == noErr, let sampleBuffer else {
                    once.resume(.failure(EncoderError.encode(status)))
                    return
                }
                do {
                    once.resume(.success(try self.pack(sampleBuffer)))
                } catch {
                    once.resume(.failure(error))
                }
            }
        )
        if status != noErr {
            once.resume(.failure(EncoderError.encode(status)))
        }
    }

    private func makeSession(codec: CMVideoCodecType) -> Bool {
        if let session { VTCompressionSessionInvalidate(session) }
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: codec,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
        }
        guard status == noErr, let created else { return false }
        let realTime = kCFBooleanTrue
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: realTime)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 25_000_000))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 120))
        let profile: CFString = codec == kCMVideoCodecType_HEVC
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        cachedParameterSets = Data()
        return true
    }

    private func pack(_ sampleBuffer: CMSampleBuffer) throws -> EncodedAccessUnit {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw EncoderError.encode(noErr)
        }
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &total,
            dataPointerOut: &pointer
        )
        guard pointerStatus == kCMBlockBufferNoErr, let pointer, total > 0 else {
            throw EncoderError.encode(pointerStatus)
        }
        var nalLength: Int32 = 4
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalLength
            )
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalLength
            )
        }
        let lengthPrefixed = Data(bytes: pointer, count: total)
        var annex = AnnexB.fromLengthPrefixed(lengthPrefixed, lengthSize: Int(nalLength))
        let sets = parameterSets(format: format)
        if sets != cachedParameterSets {
            cachedParameterSets = sets
        }
        let keyframe = isKeyframe(sampleBuffer)
        if keyframe, !sets.isEmpty {
            annex.insert(contentsOf: sets, at: 0)
        }
        return EncodedAccessUnit(annexB: annex, isKeyframe: keyframe, parameterSets: sets)
    }

    private func parameterSets(format: CMFormatDescription) -> Data {
        var count = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        }
        var output = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            }
            if status == noErr, let pointer, size > 0 {
                output.append(AnnexB.startCode)
                output.append(pointer, count: size)
            }
        }
        return output
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else {
            return true
        }
        let array = attachments as NSArray
        guard let dict = array.firstObject as? NSDictionary else { return true }
        return (dict[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}

final class CompletionOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((T) -> Void)?
    init(_ handler: @escaping (T) -> Void) { self.handler = handler }
    func resume(_ value: T) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(value)
    }
}

enum DecoderError: Error {
    case parameters
    case sample(OSStatus)
}

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var hevc = true
    private var configuredID: UInt16 = 0

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        configuredID = 0
    }

    func apply(_ config: VideoConfig) throws {
        guard config.channelID != ChannelID.losslessTile else { return }
        hevc = config.codec == CodecID.hevc || config.channelID == ChannelID.hevcMain
        let nals = AnnexB.split(config.paramSets).filter { AnnexB.isParameterSet(nal: $0, hevc: hevc) }
        guard !nals.isEmpty else { throw DecoderError.parameters }
        let format = try makeFormat(nals)
        if let session { VTDecompressionSessionInvalidate(session) }
        self.format = format
        self.session = try makeSession(format)
        configuredID = config.encoderConfigID
    }

    func decode(_ frame: VideoFrame) async -> CVPixelBuffer? {
        guard frame.channelID != ChannelID.losslessTile else { return nil }
        guard frame.encoderConfigID == configuredID, let session, let format else { return nil }
        let payload = AnnexB.toLengthPrefixed(frame.accessUnit) { nal in
            AnnexB.isParameterSet(nal: nal, hevc: hevc)
        }
        guard !payload.isEmpty else { return nil }
        guard let sample = makeSampleBuffer(payload, format: format) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = CompletionOnce<CVPixelBuffer?> { continuation.resume(returning: $0) }
            var flags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &flags,
                outputHandler: { status, _, imageBuffer, _, _ in
                    if status == noErr, let imageBuffer {
                        once.resume(imageBuffer)
                    } else {
                        once.resume(nil)
                    }
                }
            )
            if status != noErr { once.resume(nil) }
        }
    }

    private func makeFormat(_ nals: [Data]) throws -> CMFormatDescription {
        let objects = nals.map { $0 as NSData }
        var pointers: [UnsafePointer<UInt8>] = objects.map {
            $0.bytes.assumingMemoryBound(to: UInt8.self)
        }
        var sizes = objects.map(\.length)
        var format: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else { throw DecoderError.parameters }
        return format
    }

    private func makeSession(_ format: CMFormatDescription) throws -> VTDecompressionSession {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw DecoderError.sample(status) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }

    private func makeSampleBuffer(_ payload: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = payload.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: 1, timescale: 60), decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }
}
