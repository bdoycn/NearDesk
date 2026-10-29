// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Foundation
import Network

public struct PresentedFrame {
    public var pixelBuffer: CVPixelBuffer
    public var codedWidth: Int
    public var codedHeight: Int
    public var display: RemoteDisplay
}

public final class ViewerSession {
    public var onStatus: ((String) -> Void)?
    public var onDisplays: (([RemoteDisplay]) -> Void)?
    public var onFrame: ((PresentedFrame) -> Void)?
    public var confirmTrust: ((String) async -> Bool)?
    public var onTrustMismatch: ((String) -> Void)?

    private var group: QuicGroup?
    private var tasks: [Task<Void, Never>] = []
    private var inputPipe: MessagePipe?
    private var controlPipe: MessagePipe?
    private let decoder = VideoDecoder()
    private let compositor = TileCompositor()
    private var displays: [RemoteDisplay] = []
    private var selected: RemoteDisplay?
    private var codedWidth = 0
    private var codedHeight = 0
    private var eventID: UInt64 = 0
    private var stopped = false
    private var authed = false
    private var videoTimeout: Task<Void, Never>?

    public init() {}

    public func connect(endpoint: NWEndpoint, hostKey: String, password: String, name: String) {
        disconnect()
        stopped = false
        authed = false
        LatencyHub.shared.beginViewer(clocksMatch: Self.clocksMatch(endpoint))
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.run(endpoint: endpoint, hostKey: hostKey, password: password, name: name)
        }
        tasks.append(task)
    }

    public func disconnect() {
        stopped = true
        videoTimeout?.cancel()
        videoTimeout = nil
        authed = false
        group?.cancel()
        group = nil
        inputPipe?.cancel()
        inputPipe = nil
        controlPipe?.cancel()
        controlPipe = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        decoder.reset()
        compositor.reset()
    }

    public func choose(displayID: UInt32) {
        guard let display = displays.first(where: { $0.displayID == displayID }), let control = controlPipe else { return }
        selected = display
        waitForVideo()
        Task {
            try? await control.send(.selectDisplay(SelectDisplay(displayID: displayID)))
        }
    }

    public func send(_ message: NearMessage) {
        guard authed, let pipe = inputPipe, let selected else { return }
        let stamped = stamp(message, display: selected)
        guard let event = eventParts(stamped) else { return }
        LatencyHub.shared.noteInput(
            eventID: event.id,
            kind: event.kind,
            displayID: selected.displayID,
            eventMono: event.mono
        )
        Task {
            try? await pipe.send(stamped)
        }
    }

    private func run(endpoint: NWEndpoint, hostKey: String, password: String, name: String) async {
        do {
            let identity = try SpikeIdentity.loadOrCreate()
            let parameters = QuicParameters.make(identity: identity.networkIdentity, verify: .tofu { [weak self] metadata, complete in
                self?.decide(metadata: metadata, hostKey: hostKey, complete: complete)
            })
            let group = QuicGroup(group: NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters))
            self.group = group
            try await group.start()
            let inbound: Task<Void, Never> = Task { [weak self] in
                for await connection in group.inbound {
                    guard let self else { return }
                    await self.readVideo(connection)
                }
            }
            tasks.append(inbound)
            let control = try group.openStream(.bidirectional)
            try await control.writePreface(.control)
            controlPipe = control
            let helloName = String(data: UTF8Bytes.clipped(name, maxBytes: 64), encoding: .utf8) ?? "NearDesk"
            try await control.send(.hello(Hello(name: helloName)))
            guard (1...128).contains(password.utf8.count) else {
                onStatus?("Enter a password of 1 to 128 bytes.")
                disconnect()
                return
            }
            try await control.send(.authPassword(AuthPassword(password: Data(password.utf8))))
            let result = try await control.next()
            guard case .authResult(let auth) = result, auth.ok else {
                onStatus?(authReason(result))
                disconnect()
                return
            }
            let list = try await control.next()
            guard case .displayList(let displayList) = list, !displayList.displays.isEmpty else {
                onStatus?("The host did not offer a display.")
                disconnect()
                return
            }
            displays = displayList.displays
            onDisplays?(displays)
            let chosen = displays.first { $0.displayID == DisplayCatalog.mainID } ?? displays[0]
            selected = chosen
            let input = try group.openStream(.unidirectional)
            try await input.writePreface(.input)
            inputPipe = input
            authed = true
            waitForVideo()
            try await control.send(.selectDisplay(SelectDisplay(displayID: chosen.displayID)))
            onStatus?("Watching \(chosen.widthPx)×\(chosen.heightPx). Click the picture to control it.")
            while !stopped {
                _ = try await control.next()
            }
        } catch {
            videoTimeout?.cancel()
            if !stopped {
                onStatus?("Disconnected. \(error.localizedDescription)")
            }
        }
    }

    private func waitForVideo() {
        videoTimeout?.cancel()
        videoTimeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch { return }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.onStatus?("Host is not sending video (check Screen Recording). The host may need to fully quit and relaunch NearDesk.app after allowing it.")
        }
    }

    private func decide(metadata: sec_protocol_metadata_t, hostKey: String, complete: @escaping (Bool) -> Void) {
        guard let der = PeerCertificate.leafDER(metadata) else {
            onStatus?("No certificate. Password was not sent.")
            complete(false)
            return
        }
        let hex = SpikeIdentity.fingerprint(of: der)
        if let saved = TofuStore.remembered(host: hostKey) {
            if saved == hex {
                complete(true)
            } else {
                onTrustMismatch?(SpikeIdentity.grouped(hex))
                onStatus?("Certificate changed. Password was not sent. Forget the saved fingerprint to review it again.")
                complete(false)
            }
            return
        }
        Task {
            let accepted = await confirmTrust?(SpikeIdentity.grouped(hex)) ?? false
            if accepted {
                TofuStore.remember(host: hostKey, fingerprint: hex)
            }
            complete(accepted)
        }
    }

    private func readVideo(_ pipe: MessagePipe) async {
        do {
            let preface = try await pipe.readPreface()
            guard preface.kind == .video else {
                pipe.cancel()
                return
            }
            decoder.reset()
            compositor.reset()
            while !stopped {
                let message = try await pipe.next()
                let received = MonoClock.nanoseconds()
                switch message {
                case .videoConfig(let config):
                    videoTimeout?.cancel()
                    try compositor.apply(config)
                    if config.channelID != ChannelID.losslessTile {
                        try decoder.apply(config)
                    }
                    codedWidth = Int(config.codedWidth)
                    codedHeight = Int(config.codedHeight)
                    if let match = displays.first(where: { $0.displayID == config.displayID }) {
                        selected = match
                    }
                case .videoFrame(let frame):
                    videoTimeout?.cancel()
                    try compositor.validate(frame)
                    let picture: ComposedFrame?
                    if frame.channelID == ChannelID.losslessTile {
                        picture = try compositor.compositeTile(frame)
                    } else {
                        guard let image = await decoder.decode(frame) else { continue }
                        picture = try compositor.compositeLossy(frame, decoded: image)
                    }
                    if let picture {
                        await publish(frame, picture: picture, received: received)
                    }
                default:
                    pipe.cancel()
                    return
                }
            }
        } catch is ProtocolError {
            pipe.cancel()
            if !stopped { onStatus?("Video stream reset.") }
        } catch {
            pipe.cancel()
            if !stopped { onStatus?("Video stream ended.") }
        }
    }

    private func publish(_ frame: VideoFrame, picture: ComposedFrame, received: UInt64) async {
        guard let display = selected else { return }
        let presented = PresentedFrame(
            pixelBuffer: picture.pixelBuffer,
            codedWidth: codedWidth,
            codedHeight: codedHeight,
            display: display
        )
        let record = picture.recordLatency
        await MainActor.run {
            self.onFrame?(presented)
            guard record else { return }
            let t4 = MonoClock.nanoseconds()
            LatencyHub.shared.noteClientVideo(
                frameID: frame.frameID,
                channelID: frame.channelID,
                encoderConfigID: frame.encoderConfigID,
                dirtyCount: frame.rects.count,
                auBytes: frame.accessUnit.count,
                t0: frame.captureMono,
                t3: received,
                t4: t4
            )
            LatencyHub.shared.notePresented(
                frameID: frame.frameID,
                t0: frame.captureMono,
                t4: t4,
                qualifies: frame.qualifiesForInputMatch
            )
        }
    }

    private func stamp(_ message: NearMessage, display: RemoteDisplay) -> NearMessage {
        eventID += 1
        let mono = MonoClock.nanoseconds()
        let prefix = InputPrefix(eventID: eventID, eventMono: mono, displayID: display.displayID)
        switch message {
        case .mouseMove(let move):
            return .mouseMove(MouseMove(prefix: prefix, xPx: move.xPx, yPx: move.yPx))
        case .mouseButton(let button):
            return .mouseButton(MouseButton(prefix: prefix, xPx: button.xPx, yPx: button.yPx, button: button.button, action: button.action))
        case .wheel(let wheel):
            return .wheel(Wheel(prefix: prefix, xPx: wheel.xPx, yPx: wheel.yPx, deltaX: wheel.deltaX, deltaY: wheel.deltaY, unit: wheel.unit))
        case .key(let key):
            return .key(KeyEvent(prefix: prefix, keycode: key.keycode, action: key.action, modifiers: key.modifiers, utf32: key.utf32))
        default:
            return message
        }
    }

    private func eventParts(_ message: NearMessage) -> (id: UInt64, kind: String, mono: UInt64)? {
        switch message {
        case .mouseMove(let value):
            return (value.prefix.eventID, MessageType.mouseMove.kindName, value.prefix.eventMono)
        case .mouseButton(let value):
            return (value.prefix.eventID, MessageType.mouseButton.kindName, value.prefix.eventMono)
        case .wheel(let value):
            return (value.prefix.eventID, MessageType.wheel.kindName, value.prefix.eventMono)
        case .key(let value):
            return (value.prefix.eventID, MessageType.key.kindName, value.prefix.eventMono)
        default:
            return nil
        }
    }

    private static func clocksMatch(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == .loopback
        case .ipv6(let address):
            return address == .loopback
        default:
            return false
        }
    }

    private func authReason(_ message: NearMessage) -> String {
        guard case .authResult(let result) = message else { return "Login failed." }
        if result.reason == AuthResult.badPassword { return "Password was not accepted." }
        if result.reason == AuthResult.version { return "This host speaks a different NearDesk version." }
        return "Login failed."
    }
}
