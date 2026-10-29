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
    private let pumpQueue = DispatchQueue(label: "neardesk.pump")
    private var videoPipe: MessagePipe?
    private var busy = false
    private var pending: PendingCapture?
    private var frameID: UInt64 = 0
    private var encodedCount: UInt64 = 0
    private var configID: UInt16 = 0
    private var lastParameterSets: Data?
    private var codedWidth = 0
    private var codedHeight = 0
    private var sendTail: Task<Void, Never>?
    private var stopped = false
    private var streaming = false

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
        frameID = 0
        encodedCount = 0
        configID = 0
        lastParameterSets = nil
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
            let size = codedSize(widthPx: display.widthPx, heightPx: display.heightPx)
            codedWidth = size.width
            codedHeight = size.height
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
        pumpQueue.async { [weak self] in
            guard let self, self.streaming else { return }
            self.pending = PendingCapture(buffer: image, captured: captured, dirty: dirty)
            self.kick()
        }
    }

    private func kick() {
        guard !busy, let next = pending else { return }
        pending = nil
        busy = true
        let forceKey = encodedCount == 0 || encodedCount % 120 == 0
        encodedCount += 1
        encoder.encode(next.buffer, forceKey: forceKey) { [weak self] result in
            self?.pumpQueue.async {
                self?.finish(result, capture: next)
            }
        }
    }

    private func finish(_ result: Result<EncodedAccessUnit, Error>, capture: PendingCapture) {
        busy = false
        defer { kick() }
        guard streaming, let pipe = videoPipe else { return }
        switch result {
        case .failure:
            onStatus?("Encoder failed. Video paused.")
        case .success(let encoded):
            let t1 = MonoClock.nanoseconds()
            frameID += 1
            let id = frameID
            var flags = capture.dirty.flags
            if encoded.isKeyframe { flags |= FrameFlag.keyframe }
            var configMessage: NearMessage?
            if encoded.parameterSets != lastParameterSets, !encoded.parameterSets.isEmpty {
                configID = configID == 0 ? 1 : configID &+ 1
                lastParameterSets = encoded.parameterSets
                configMessage = .videoConfig(VideoConfig(
                    encoderConfigID: configID,
                    channelID: encoder.channelID,
                    codec: encoder.codecID,
                    displayID: selected?.displayID ?? 0,
                    codedWidth: UInt16(codedWidth),
                    codedHeight: UInt16(codedHeight),
                    paramSets: encoded.parameterSets
                ))
            }
            guard configID != 0 else { return }
            let frame = NearMessage.videoFrame(VideoFrame(
                frameID: id,
                encoderConfigID: configID,
                channelID: encoder.channelID,
                frameFlags: flags,
                captureMono: capture.captured,
                rects: capture.dirty.rects,
                accessUnit: encoded.annexB
            ))
            let previous = sendTail
            sendTail = Task {
                _ = await previous?.value
                guard !Task.isCancelled else { return }
                if let configMessage {
                    try? await pipe.send(configMessage)
                }
                let t2 = MonoClock.nanoseconds()
                LatencyHub.shared.noteHostVideo(frameID: id, t1: t1, t2: t2)
                try? await pipe.send(frame)
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

private struct PendingCapture {
    var buffer: CVPixelBuffer
    var captured: UInt64
    var dirty: DirtyEncode
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
    var diff: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
    return diff == 0
}
