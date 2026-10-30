// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import Network

public final class HostSession {
    public var onStatus: ((String) -> Void)?
    public var onStartFailure: ((Error) -> Void)?
    public var onPort: ((UInt16) -> Void)?
    public var onStreaming: ((Bool) -> Void)?

    private let listener = QuicListener()
    private var activeGroup: QuicGroup?
    private var tasks: [Task<Void, Never>] = []
    private var password = Data()
    private var selected: RemoteDisplay?
    private let capturer = ScreenCapturer()
    private let encoder = VideoEncoder()
    private let transfer = PixelTransfer()
    private let cloner = BGRACloner()
    private let pumpQueue = DispatchQueue(label: "neardesk.pump")
    private var videoPipe: MessagePipe?
    private var busy = false
    private var pending: PendingCapture?
    private var frameID: UInt64 = 0
    private var lossyFramesSent: UInt64 = 0
    private var configSerial: UInt16 = 0
    private var lossyConfigID: UInt16 = 0
    private var losslessConfigID: UInt16 = 0
    private var lossyChannel: UInt8 = 0
    private var lastParameterSets: Data?
    private var hasLossyKeyframe = false
    private var publishedGeometry: StreamGeometry?
    private var losslessFormat: OSType = 0
    private var codedWidth = 0
    private var codedHeight = 0
    private var sendTail: Task<Void, Never>?
    private var stopped = false
    private var streaming = false
    private var videoGeneration = 0

    public init() {}

    public func start(name: String, password: String) throws {
        stop()
        stopped = false
        self.password = Data(password.utf8)
        LatencyHub.shared.beginHost()
        do {
            let identity = try SpikeIdentity.loadOrCreate()
            let clipped = String(data: UTF8Bytes.clipped(name, maxBytes: 63), encoding: .utf8) ?? "NearDesk"
            listener.onFailure = { [weak self] error in
                self?.stop()
                self?.onStartFailure?(error)
            }
            listener.onReady = { [weak self] port in
                self?.onPort?(port)
            }
            listener.onState = { [weak self] text in
                self?.onStatus?(text)
            }
            listener.onGroup = { [weak self] group in
                self?.accept(group)
            }
            try listener.start(
                identity: identity.networkIdentity,
                serviceName: clipped,
                txt: ["ver": "1", "name": clipped]
            )
            onStatus?("Certificate \(SpikeIdentity.grouped(identity.fingerprintHex))")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        stopped = true
        streaming = false
        listener.stop()
        let group = activeGroup
        activeGroup = nil
        group?.onLost = nil
        group?.cancel()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        capturer.stop()
        encoder.stop()
        videoPipe?.cancel()
        videoPipe = nil
        sendTail?.cancel()
        sendTail = nil
        pumpQueue.sync {
            self.videoGeneration += 1
            self.busy = false
            self.pending = nil
        }
        onStreaming?(false)
    }

    private func accept(_ group: QuicGroup) {
        if activeGroup != nil {
            group.cancel()
            return
        }
        activeGroup = group
        group.onLost = { [weak self] in
            self?.clientLost(group)
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.serve(group)
        }
        tasks.append(task)
    }

    private func clientLost(_ group: QuicGroup) {
        guard activeGroup === group else { return }
        activeGroup = nil
        streaming = false
        capturer.stop()
        encoder.stop()
        videoPipe?.cancel()
        videoPipe = nil
        sendTail?.cancel()
        sendTail = nil
        pumpQueue.sync {
            self.videoGeneration += 1
            self.busy = false
            self.pending = nil
        }
        onStreaming?(false)
        if !stopped { onStatus?("Viewer disconnected. Another Mac can connect.") }
    }

    private func serve(_ group: QuicGroup) async {
        do {
            try await group.start()
            onStatus?("Mac connected. Waiting for login.")
            let inbound: Task<Void, Never> = Task { [weak self] in
                await withTaskGroup(of: Void.self) { streams in
                    for await pipe in group.inbound {
                        guard let self else { return }
                        // Control stays open while input arrives on its own stream.
                        streams.addTask { await self.acceptStream(pipe) }
                    }
                }
            }
            tasks.append(inbound)
        } catch {
            onStatus?("Connection failed before login.")
            group.cancel()
            if activeGroup === group { activeGroup = nil }
        }
    }

    private func acceptStream(_ pipe: MessagePipe) async {
        do {
            let preface = try await pipe.readPreface()
            switch preface.kind {
            case .control:
                try await runControl(pipe)
            case .input:
                try await runInput(pipe)
            case .video:
                pipe.cancel()
            }
        } catch let error as ProtocolError {
            if case .bodyLength = error {
                activeGroup?.cancel()
            } else {
                pipe.cancel()
            }
            onStatus?("Protocol error. Stream reset.")
        } catch {
            pipe.cancel()
        }
    }

    private func runControl(_ pipe: MessagePipe) async throws {
        let hello = try await pipe.next()
        guard case .hello(let hello) = hello, hello.role == 1 else {
            try await pipe.send(.authResult(AuthResult(ok: false, reason: AuthResult.version)))
            activeGroup?.cancel()
            return
        }
        if hello.major != 1 {
            try await pipe.send(.authResult(AuthResult(ok: false, reason: AuthResult.version)))
            activeGroup?.cancel()
            return
        }
        let auth = try await pipe.next()
        guard case .authPassword(let provided) = auth, constantTimeEqual(provided.password, password) else {
            try await pipe.send(.authResult(AuthResult(ok: false, reason: AuthResult.badPassword)))
            onStatus?("Password was rejected.")
            activeGroup?.cancel()
            return
        }
        try await pipe.send(.authResult(AuthResult(ok: true, reason: AuthResult.none)))
        let displays = DisplayCatalog.current()
        try await pipe.send(.displayList(DisplayList(displays: displays)))
        onStatus?("Logged in. Waiting for a display choice.")
        while !stopped {
            let message = try await pipe.next()
            guard case .selectDisplay(let select) = message else { continue }
            guard let display = displays.first(where: { $0.displayID == select.displayID }) ?? DisplayCatalog.current().first(where: { $0.displayID == select.displayID }) else {
                onStatus?("That display is not available.")
                continue
            }
            await beginVideo(display: display)
        }
    }

    private func beginVideo(display: RemoteDisplay) async {
        streaming = false
        onStreaming?(false)
        capturer.stop()
        encoder.stop()
        videoPipe?.cancel()
        videoPipe = nil
        sendTail?.cancel()
        sendTail = nil
        selected = display
        let size = codedSize(widthPx: display.widthPx, heightPx: display.heightPx)
        pumpQueue.sync {
            self.videoGeneration += 1
            self.busy = false
            self.pending = nil
            self.frameID = 0
            self.lossyFramesSent = 0
            self.configSerial = 0
            self.lossyConfigID = 0
            self.losslessConfigID = 0
            self.lossyChannel = 0
            self.lastParameterSets = nil
            self.hasLossyKeyframe = false
            self.publishedGeometry = nil
            self.losslessFormat = 0
            self.codedWidth = size.width
            self.codedHeight = size.height
            self.transfer.reset()
        }
        if !PermissionProbe.screenRecording {
            onStatus?("Screen Recording is off. NearDesk is not sharing a desktop.")
            onStreaming?(false)
            return
        }
        do {
            guard let group = activeGroup else { return }
            let pipe = try group.openStream(.unidirectional)
            try await pipe.writePreface(.video)
            videoPipe = pipe
            try encoder.start(width: size.width, height: size.height)
            capturer.onFrame = { [weak self] sample, captured in
                self?.enqueue(sample, captured: captured)
            }
            capturer.onStopped = { [weak self] message in
                self?.onStatus?("Capture stopped. \(message)")
                self?.onStreaming?(false)
            }
            _ = try await capturer.start(displayID: display.displayID)
            streaming = true
            onStreaming?(true)
            onStatus?("Sharing \(size.width)×\(size.height) \(encoder.hevc ? "HEVC" : "H.264").")
        } catch {
            streaming = false
            capturer.stop()
            encoder.stop()
            videoPipe?.cancel()
            videoPipe = nil
            onStreaming?(false)
            onStatus?("Could not start video: \(error.localizedDescription). Check Screen Recording, fully quit and relaunch NearDesk.app if needed, then re-select a display.")
        }
    }

    private func enqueue(_ sample: CMSampleBuffer, captured: UInt64) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let dirty = dirtyEncode(from: sample)
        guard let owned = cloner.copy(image) else { return }
        pumpQueue.async { [weak self] in
            guard let self, self.streaming else { return }
            self.pending = PendingCapture(buffer: owned, captured: captured, dirty: dirty)
            self.kick()
        }
    }

    private func kick() {
        guard !busy, let next = pending else { return }
        pending = nil
        let bufferWidth = CVPixelBufferGetWidth(next.buffer)
        let bufferHeight = CVPixelBufferGetHeight(next.buffer)
        guard bufferWidth == codedWidth, bufferHeight == codedHeight, let display = selected else { return }
        let geometry = StreamGeometry(displayID: display.displayID, width: codedWidth, height: codedHeight)
        let geometryChanged = publishedGeometry != geometry
        guard let plan = planCapture(
            next.dirty,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            hasLossyKeyframe: hasLossyKeyframe,
            lossyFramesSent: lossyFramesSent,
            geometryChanged: geometryChanged
        ) else { return }

        busy = true
        var tileBytes: Data?
        var tileCopiedAt: UInt64?
        var lossyRects = plan.lossyRects
        if plan.sendsTile {
            if let copied = copyCompactBGRA(from: next.buffer, rects: plan.tileRects) {
                tileBytes = copied
                tileCopiedAt = MonoClock.nanoseconds()
            } else if plan.sendsLossy {
                lossyRects.append(contentsOf: plan.tileRects)
            } else {
                busy = false
                kick()
                return
            }
        }
        let job = InflightCapture(
            generation: videoGeneration,
            captureMono: next.captured,
            geometry: geometry,
            geometryChanged: geometryChanged,
            tileRects: tileBytes == nil ? [] : plan.tileRects,
            tileFlags: plan.tileFlags,
            tileBytes: tileBytes,
            tileCopiedAt: tileCopiedAt,
            lossyRects: lossyRects,
            lossyFlags: plan.lossyFlags,
            sendsLossy: plan.sendsLossy
        )
        let holdForLossyConfig = job.sendsLossy && tileBytes != nil && (lossyConfigID == 0 || geometryChanged)
        if !holdForLossyConfig {
            queueTile(job)
        }
        guard job.sendsLossy else {
            releaseAfterSend(job.generation)
            return
        }
        guard let yuv = transfer.toFullRange420(next.buffer, width: codedWidth, height: codedHeight) else {
            if !job.tileQueued {
                queueTile(job)
            }
            if !job.tileQueued {
                onStatus?("Encoder failed. Video paused.")
            }
            releaseAfterSend(job.generation)
            return
        }
        let forceKey = job.lossyFlags & FrameFlag.keyframe != 0
        encoder.encode(yuv, forceKey: forceKey) { [weak self] result in
            self?.pumpQueue.async {
                guard let self, job.generation == self.videoGeneration else { return }
                self.finishEncode(result, job: job)
            }
        }
    }

    private func finishEncode(_ result: Result<EncodedAccessUnit, Error>, job: InflightCapture) {
        guard job.generation == videoGeneration else { return }
        guard streaming, videoPipe != nil else {
            busy = false
            return
        }
        switch result {
        case .failure:
            if !job.tileQueued {
                queueTile(job)
            }
            if !job.tileQueued {
                onStatus?("Encoder failed. Video paused.")
            }
            releaseAfterSend(job.generation)
        case .success(let encoded):
            let offer = makeLossyConfig(encoded, job: job)
            if case .blocked = offer {
                if !job.tileQueued {
                    queueTile(job)
                }
                releaseAfterSend(job.generation)
                return
            }
            let id = takeFrameID(job)
            guard lossyConfigID != 0 else {
                releaseAfterSend(job.generation)
                return
            }
            var messages: [NearMessage] = []
            if case .ready(let config) = offer {
                messages.append(config)
            }
            var account = AccountedFrame(channelID: encoder.channelID, t1: MonoClock.nanoseconds())
            if !job.tileQueued, let bytes = job.tileBytes {
                if let config = issueLosslessConfig(job, sendingTile: true) {
                    messages.append(config)
                }
                if losslessConfigID != 0 {
                    messages.append(tileFrame(job, id: id, bytes: bytes))
                    account = AccountedFrame(channelID: ChannelID.losslessTile, t1: job.tileCopiedAt ?? account.t1)
                    job.tileQueued = true
                }
            } else if !job.tileQueued, let config = issueLosslessConfig(job, sendingTile: false) {
                messages.append(config)
            }
            var lossyFlags = job.lossyFlags
            if encoded.isKeyframe { lossyFlags |= FrameFlag.keyframe }
            messages.append(.videoFrame(VideoFrame(
                frameID: id,
                encoderConfigID: lossyConfigID,
                channelID: encoder.channelID,
                frameFlags: lossyFlags,
                captureMono: job.captureMono,
                rects: job.lossyRects,
                accessUnit: encoded.annexB
            )))
            let tileAlreadyNoted = job.tileQueued && account.channelID != ChannelID.losslessTile
            sendMessages(messages, generation: job.generation, account: tileAlreadyNoted ? nil : account)
            lossyFramesSent += 1
            if job.lossyFlags & FrameFlag.keyframe != 0 {
                hasLossyKeyframe = true
            }
            publishedGeometry = job.geometry
            releaseAfterSend(job.generation)
        }
    }

    /// `busy` stays set until this capture's bytes are accepted. A later capture
    /// replaces `pending`, so a stalled send cannot queue minutes of frames.
    private func releaseAfterSend(_ generation: Int) {
        let previous = sendTail
        let hop = PumpHop(self)
        sendTail = Task {
            _ = await previous?.value
            hop.session?.pumpQueue.async {
                hop.session?.completeRelease(generation)
            }
        }
    }

    private func completeRelease(_ generation: Int) {
        guard generation == videoGeneration else { return }
        busy = false
        if streaming { kick() }
    }

    private func queueTile(_ job: InflightCapture) {
        guard !job.tileQueued, let bytes = job.tileBytes, videoPipe != nil else { return }
        var messages: [NearMessage] = []
        if let config = issueLosslessConfig(job, sendingTile: true) {
            messages.append(config)
        }
        guard losslessConfigID != 0 else { return }
        let id = takeFrameID(job)
        messages.append(tileFrame(job, id: id, bytes: bytes))
        job.tileQueued = true
        let t1 = job.tileCopiedAt ?? MonoClock.nanoseconds()
        sendMessages(
            messages,
            generation: job.generation,
            account: AccountedFrame(channelID: ChannelID.losslessTile, t1: t1)
        )
    }

    private func tileFrame(_ job: InflightCapture, id: UInt64, bytes: Data) -> NearMessage {
        .videoFrame(VideoFrame(
            frameID: id,
            encoderConfigID: losslessConfigID,
            channelID: ChannelID.losslessTile,
            frameFlags: job.tileFlags,
            captureMono: job.captureMono,
            rects: job.tileRects,
            accessUnit: bytes
        ))
    }

    private func issueLosslessConfig(_ job: InflightCapture, sendingTile: Bool) -> NearMessage? {
        if job.losslessDecided { return nil }
        job.losslessDecided = true
        let format = kCVPixelFormatType_32BGRA
        let formatChanged = losslessConfigID != 0 && losslessFormat != format
        let refreshLiving = losslessConfigID != 0 && (job.geometryChanged || formatChanged)
        let firstOrStaleTile = sendingTile && (losslessConfigID == 0 || job.geometryChanged || losslessFormat != format)
        guard refreshLiving || firstOrStaleTile else { return nil }
        losslessConfigID = bumpConfigID()
        losslessFormat = format
        return .videoConfig(VideoConfig(
            encoderConfigID: losslessConfigID,
            channelID: ChannelID.losslessTile,
            codec: CodecID.rawBGRA,
            displayID: job.geometry.displayID,
            codedWidth: UInt16(job.geometry.width),
            codedHeight: UInt16(job.geometry.height),
            fpsNum: 60,
            fpsDen: 1,
            chroma: 0,
            paramSets: Data()
        ))
    }

    private func makeLossyConfig(_ encoded: EncodedAccessUnit, job: InflightCapture) -> LossyConfigOffer {
        let sets = encoded.parameterSets.isEmpty ? (lastParameterSets ?? Data()) : encoded.parameterSets
        let setsChanged = !sets.isEmpty && sets != lastParameterSets
        let channelChanged = lossyConfigID != 0 && lossyChannel != encoder.channelID
        let needed = lossyConfigID == 0 || job.geometryChanged || setsChanged || channelChanged
        if !needed { return .unchanged }
        guard !sets.isEmpty else { return .blocked }
        lossyConfigID = bumpConfigID()
        lossyChannel = encoder.channelID
        lastParameterSets = sets
        return .ready(.videoConfig(VideoConfig(
            encoderConfigID: lossyConfigID,
            channelID: encoder.channelID,
            codec: encoder.codecID,
            displayID: job.geometry.displayID,
            codedWidth: UInt16(job.geometry.width),
            codedHeight: UInt16(job.geometry.height),
            paramSets: sets
        )))
    }

    private func bumpConfigID() -> UInt16 {
        if configSerial == UInt16.max {
            configSerial = 1
        } else {
            configSerial += 1
        }
        return configSerial
    }

    private func takeFrameID(_ job: InflightCapture) -> UInt64 {
        if job.frameID == 0 {
            frameID += 1
            job.frameID = frameID
        }
        return job.frameID
    }

    private func sendMessages(_ messages: [NearMessage], generation: Int, account: AccountedFrame?) {
        guard let pipe = videoPipe, !messages.isEmpty else { return }
        let previous = sendTail
        sendTail = Task { [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled, self.streaming, generation == self.videoGeneration else { return }
            var account = account
            for message in messages {
                if let pending = account, case .videoFrame(let frame) = message, frame.channelID == pending.channelID {
                    let t2 = MonoClock.nanoseconds()
                    LatencyHub.shared.noteHostVideo(frameID: frame.frameID, t1: pending.t1, t2: t2)
                    account = nil
                }
                try? await pipe.send(message)
            }
        }
    }

    private func runInput(_ pipe: MessagePipe) async throws {
        while !stopped {
            let message = try await pipe.next()
            guard let display = selected else { continue }
            do {
                let injected = try InputInjector.inject(message, display: display)
                LatencyHub.shared.noteInjected(eventID: injected.eventID, tInject: injected.tInject)
            } catch InjectError.accessibility {
                onStatus?("Accessibility is off. NearDesk did not inject input.")
            } catch InjectError.wrongDisplay {
                continue
            } catch {
                continue
            }
        }
    }
}

private final class PumpHop: @unchecked Sendable {
    weak var session: HostSession?
    init(_ session: HostSession) { self.session = session }
}

private struct PendingCapture {
    var buffer: CVPixelBuffer
    var captured: UInt64
    var dirty: DirtyEncode
}

private struct StreamGeometry: Equatable {
    var displayID: UInt32
    var width: Int
    var height: Int
}

private struct AccountedFrame {
    var channelID: UInt8
    var t1: UInt64
}

private enum LossyConfigOffer {
    case unchanged
    case ready(NearMessage)
    case blocked
}

private final class InflightCapture {
    var generation: Int
    var captureMono: UInt64
    var geometry: StreamGeometry
    var geometryChanged: Bool
    var tileRects: [NdRect]
    var tileFlags: UInt8
    var tileBytes: Data?
    var tileCopiedAt: UInt64?
    var tileQueued = false
    var lossyRects: [NdRect]
    var lossyFlags: UInt8
    var sendsLossy: Bool
    var frameID: UInt64 = 0
    var losslessDecided = false

    init(
        generation: Int,
        captureMono: UInt64,
        geometry: StreamGeometry,
        geometryChanged: Bool,
        tileRects: [NdRect],
        tileFlags: UInt8,
        tileBytes: Data?,
        tileCopiedAt: UInt64?,
        lossyRects: [NdRect],
        lossyFlags: UInt8,
        sendsLossy: Bool
    ) {
        self.generation = generation
        self.captureMono = captureMono
        self.geometry = geometry
        self.geometryChanged = geometryChanged
        self.tileRects = tileRects
        self.tileFlags = tileFlags
        self.tileBytes = tileBytes
        self.tileCopiedAt = tileCopiedAt
        self.lossyRects = lossyRects
        self.lossyFlags = lossyFlags
        self.sendsLossy = sendsLossy
    }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
    var diff: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
    return diff == 0
}
