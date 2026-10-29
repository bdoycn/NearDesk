// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Darwin
import Network
import XCTest
@testable import NearDeskCore

final class LoopbackTests: XCTestCase {
    func testQuicAuthThenHostVideoStream() async throws {
        let identity = try SpikeIdentity.loadOrCreate()
        let listener = QuicListener()
        let clientHolder = GroupHolder()
        let hostHolder = GroupHolder()
        defer {
            clientHolder.group?.cancel()
            hostHolder.group?.cancel()
            listener.stop()
        }

        let port: UInt16 = try await once(seconds: 8) { resume in
            listener.onReady = { resume(.success($0)) }
            do {
                try listener.start(identity: identity.networkIdentity, serviceName: nil, txt: [:])
            } catch {
                resume(.failure(error))
            }
        }
        let portValue = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let parameters = QuicParameters.make(identity: identity.networkIdentity, verify: .tofu { _, complete in
            complete(true)
        })
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: portValue)
        let client = QuicGroup(group: NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters))
        clientHolder.group = client

        var clientStarted: Task<Void, Error>!
        let host: QuicGroup = try await once(seconds: 8) { resume in
            listener.onGroup = { resume(.success($0)) }
            clientStarted = Task { try await client.start() }
        }
        hostHolder.group = host
        try await host.start()
        try await clientStarted.value

        let capture = MonoClock.nanoseconds()
        let sets = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01])
        let served = Task { try await serve(host: host, password: Data("secret".utf8), capture: capture, sets: sets) }
        defer { served.cancel() }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 8_000_000_000)
            client.cancel()
            host.cancel()
        }
        defer { deadline.cancel() }
        let frame = try await once(seconds: 8) { resume in
            Task {
                do {
                    resume(.success(try await watch(client: client, password: Data("secret".utf8))))
                } catch {
                    resume(.failure(error))
                }
            }
        }
        let servedCapture = try await served.value
        XCTAssertEqual(frame.frameID, 1)
        XCTAssertEqual(frame.captureMono, servedCapture)
        XCTAssertEqual(frame.channelID, ChannelID.hevcMain)
        XCTAssertEqual(frame.frameFlags & FrameFlag.dirtyNone, FrameFlag.dirtyNone)
        XCTAssertTrue(frame.accessUnit.starts(with: [0x00, 0x00, 0x00, 0x01]))
    }

    func testEncoderEmitsAnnexBKeyframe() async throws {
        let encoder = VideoEncoder()
        try encoder.start(width: 320, height: 180)
        defer { encoder.stop() }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            180,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) {
            memset(base, 0x10, CVPixelBufferGetBytesPerRowOfPlane(image, 0) * CVPixelBufferGetHeightOfPlane(image, 0))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let encoded = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EncodedAccessUnit, Error>) in
            encoder.encode(image, forceKey: true) { cont.resume(with: $0) }
        }
        XCTAssertTrue(encoded.isKeyframe)
        XCTAssertFalse(encoded.parameterSets.isEmpty)
        XCTAssertTrue(encoded.annexB.starts(with: AnnexB.startCode))
        XCTAssertTrue(encoded.parameterSets.starts(with: AnnexB.startCode))
    }
}

private func serve(host: QuicGroup, password: Data, capture: UInt64, sets: Data) async throws -> UInt64 {
    for await pipe in host.inbound {
        let preface = try await pipe.readPreface()
        guard preface.kind == .control else { continue }
        let hello = try await pipe.next()
        guard case .hello(let hello) = hello, hello.role == 1, hello.major == 1 else {
            throw ProtocolError.malformed
        }
        let auth = try await pipe.next()
        guard case .authPassword(let provided) = auth, provided.password == password else {
            throw ProtocolError.malformed
        }
        try await pipe.send(.authResult(AuthResult(ok: true, reason: AuthResult.none)))
        try await pipe.send(.displayList(DisplayList(displays: [
            RemoteDisplay(displayID: 42, originX: 0, originY: 0, widthPx: 1920, heightPx: 1080, scaleNum: 2, scaleDen: 1)
        ])))
        let select = try await pipe.next()
        guard case .selectDisplay(let select) = select, select.displayID == 42 else {
            throw ProtocolError.malformed
        }
        let videoPipe = try host.openStream(.unidirectional)
        try await videoPipe.writePreface(.video)
        try await videoPipe.send(.videoConfig(VideoConfig(
            encoderConfigID: 1,
            channelID: ChannelID.hevcMain,
            codec: CodecID.hevc,
            displayID: 42,
            codedWidth: 1920,
            codedHeight: 1080,
            paramSets: sets
        )))
        try await videoPipe.send(.videoFrame(VideoFrame(
            frameID: 1,
            encoderConfigID: 1,
            channelID: ChannelID.hevcMain,
            frameFlags: FrameFlag.keyframe | FrameFlag.dirtyNone,
            captureMono: capture,
            rects: [],
            accessUnit: sets
        )))
        for await input in host.inbound {
            let inputPreface = try await input.readPreface()
            guard inputPreface.kind == .input else { throw ProtocolError.badPreface }
            guard case .key(let event) = try await input.next(),
                  event.prefix.eventID == 1, event.prefix.displayID == 42 else {
                throw ProtocolError.malformed
            }
            return capture
        }
        throw TransportError.closed
    }
    throw TransportError.closed
}

private func watch(client: QuicGroup, password: Data) async throws -> VideoFrame {
    let control = try client.openStream(.bidirectional)
    try await control.writePreface(.control)
    try await control.send(.hello(Hello(name: "NearDesk")))
    try await control.send(.authPassword(AuthPassword(password: password)))
    let auth = try await control.next()
    guard case .authResult(let result) = auth, result.ok else { throw ProtocolError.malformed }
    let list = try await control.next()
    guard case .displayList(let displays) = list, displays.displays.count == 1 else {
        throw ProtocolError.malformed
    }
    async let incoming = firstVideoFrame(client)
    try await control.send(.selectDisplay(SelectDisplay(displayID: 42)))
    let input = try client.openStream(.unidirectional)
    try await input.writePreface(.input)
    try await input.send(.key(KeyEvent(
        prefix: InputPrefix(eventID: 1, eventMono: MonoClock.nanoseconds(), displayID: 42),
        keycode: 0, action: 1, modifiers: 0, utf32: 65
    )))
    return try await incoming
}

private func firstVideoFrame(_ client: QuicGroup) async throws -> VideoFrame {
    for await pipe in client.inbound {
        let preface = try await pipe.readPreface()
        guard preface.kind == .video else { continue }
        let config = try await pipe.next()
        guard case .videoConfig(let config) = config, config.encoderConfigID == 1, config.chroma == 1 else {
            throw ProtocolError.malformed
        }
        let frame = try await pipe.next()
        guard case .videoFrame(let frame) = frame else { throw ProtocolError.malformed }
        return frame
    }
    throw TransportError.closed
}

private final class GroupHolder: @unchecked Sendable {
    var group: QuicGroup?
}

private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func once<T>(seconds: Double, _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let box = OnceBox(cont)
        start { box.resume($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            box.resume(.failure(TransportError.closed))
        }
    }
}
