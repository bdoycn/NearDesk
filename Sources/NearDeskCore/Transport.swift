// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
@preconcurrency import Security

enum TransportError: Error {
    case cancelled
    case closed
    case failed(NWError)
    case extract
    case preface(StreamKind)
}

func describeNetwork(_ error: NWError) -> String {
    switch error {
    case .posix(let code) where code == .EPERM || code == .EACCES:
        return "Local Network permission is off. Allow NearDesk in System Settings → Privacy & Security → Local Network."
    case .dns(let code) where code == -65570 || code == -65554:
        return "Local Network permission is off. Allow NearDesk in System Settings → Privacy & Security → Local Network."
    case .posix(let code):
        return "Network error \(code.rawValue) \(code)"
    case .dns(let code):
        return "Discovery error \(code)"
    case .tls(let status):
        return "TLS failed (\(status))"
    default:
        return String(describing: error)
    }
}

enum PeerCertificate {
    static func leafDER(_ metadata: sec_protocol_metadata_t) -> Data? {
        let box = LeafBox()
        let ok = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            guard box.der == nil else { return }
            let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
            box.der = SecCertificateCopyData(ref) as Data
        }
        return ok ? box.der : nil
    }
}

private final class LeafBox {
    var der: Data?
}

enum QuicParameters {
    enum Verify {
        case acceptPeer
        case tofu((sec_protocol_metadata_t, @escaping (Bool) -> Void) -> Void)
    }

    static func make(identity: sec_identity_t, verify: Verify) -> NWParameters {
        let options = NWProtocolQUIC.Options(alpn: [NearDeskWire.alpn])
        options.initialMaxStreamsBidirectional = 16
        options.initialMaxStreamsUnidirectional = 16
        options.initialMaxData = 32 * 1024 * 1024
        options.initialMaxStreamDataBidirectionalLocal = 8 * 1024 * 1024
        options.initialMaxStreamDataBidirectionalRemote = 8 * 1024 * 1024
        options.initialMaxStreamDataUnidirectional = 8 * 1024 * 1024
        options.idleTimeout = 60_000
        let security = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, identity)
        let queue = DispatchQueue(label: "neardesk.tls")
        switch verify {
        case .acceptPeer:
            sec_protocol_options_set_verify_block(security, { _, _, complete in
                complete(true)
            }, queue)
        case .tofu(let decide):
            sec_protocol_options_set_verify_block(security, { metadata, _, complete in
                decide(metadata, complete)
            }, queue)
        }
        let parameters = NWParameters(quic: options)
        parameters.includePeerToPeer = true
        return parameters
    }
}

final class BytePipe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var offset = 0
    private var pending: (Int, CheckedContinuation<Data, Error>)?
    private var failed: Error?
    private var eof = false
    private var reading = false
    private var ready = false
    private let receives: Bool
    private var onReady: (() -> Void)?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var sending = false
    private var sendWaiters: [(Data, CheckedContinuation<Void, Error>)] = []

    init(connection: NWConnection, queue: DispatchQueue, receives: Bool, onReady: (() -> Void)?) {
        self.connection = connection
        self.queue = queue
        self.receives = receives
        self.onReady = onReady
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handle(state) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.ready, self.failed == nil else { return }
            self.fail(TransportError.failed(.posix(.ETIMEDOUT)))
            // A preparing callback may be the group-owned underlying connection.
            // Do not cancel it here: that would tear down the other live streams.
            // The session owner cancels the group if an application stream fails.
        }
    }

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let failed = self.failed {
                    cont.resume(throwing: failed)
                    return
                }
                if self.ready {
                    cont.resume()
                    return
                }
                self.readyWaiters.append(cont)
            }
        }
    }

    func readSome(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                if self.pending != nil {
                    cont.resume(throwing: TransportError.closed)
                    return
                }
                self.pending = (max, cont)
                self.satisfy()
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let failed = self.failed {
                    cont.resume(throwing: failed)
                    return
                }
                self.sendWaiters.append((data, cont))
                self.pumpSend()
            }
        }
    }

    func cancel() {
        connection.cancel()
        queue.async { self.fail(TransportError.cancelled) }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !ready, failed == nil else { return }
            ready = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters.removeAll()
            let notify = onReady
            onReady = nil
            notify?()
            if receives && !reading {
                reading = true
                pumpRead()
            }
        case .failed(let error):
            fail(TransportError.failed(error))
        case .cancelled:
            fail(TransportError.cancelled)
        default:
            break
        }
    }

    private func pumpRead() {
        guard failed == nil, !eof else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                }
                if let error {
                    self.fail(TransportError.failed(error))
                    return
                }
                if isComplete {
                    self.eof = true
                    self.satisfy()
                    return
                }
                self.satisfy()
                self.pumpRead()
            }
        }
    }

    private func satisfy() {
        guard let pending else { return }
        let available = buffer.count - offset
        if available > 0 {
            let count = min(pending.0, available)
            let start = buffer.startIndex + offset
            let data = buffer.subdata(in: start..<(start + count))
            offset += count
            self.pending = nil
            compact()
            pending.1.resume(returning: data)
            return
        }
        if eof || failed != nil {
            self.pending = nil
            pending.1.resume(throwing: failed ?? TransportError.closed)
        }
    }

    private func compact() {
        if offset > 256 * 1024 && offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
    }

    private func pumpSend() {
        guard !sending, failed == nil, !sendWaiters.isEmpty else { return }
        let (data, cont) = sendWaiters.removeFirst()
        sending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if let error {
                    cont.resume(throwing: TransportError.failed(error))
                    self.fail(TransportError.failed(error))
                } else {
                    cont.resume()
                    self.pumpSend()
                }
            }
        })
    }

    private func fail(_ error: Error) {
        onReady = nil
        if failed == nil { failed = error }
        eof = true
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        if let pending {
            self.pending = nil
            pending.1.resume(throwing: error)
        }
        let waiters = sendWaiters
        sendWaiters.removeAll()
        waiters.forEach { $0.1.resume(throwing: error) }
    }
}

final class MessagePipe {
    private let bytes: BytePipe
    private let decoder = FrameDecoder()
    private(set) var kind: StreamKind?

    init(connection: NWConnection, queue: DispatchQueue, receives: Bool = true, onReady: (() -> Void)? = nil) {
        bytes = BytePipe(connection: connection, queue: queue, receives: receives, onReady: onReady)
        bytes.start()
    }

    func writePreface(_ kind: StreamKind) async throws {
        try await bytes.waitUntilReady()
        self.kind = kind
        // The opener declares the stream kind once; replies begin with envelopes.
        try decoder.append(Preface(kind: kind).encode())
        try await bytes.write(Preface(kind: kind).encode())
    }

    func readPreface() async throws -> Preface {
        try await bytes.waitUntilReady()
        while decoder.preface == nil {
            let chunk = try await bytes.readSome(max: 64 * 1024)
            try decoder.append(chunk)
        }
        guard let preface = decoder.preface else { throw ProtocolError.badPreface }
        kind = preface.kind
        return preface
    }

    func send(_ message: NearMessage) async throws {
        try await bytes.write(Wire.encode(message))
    }

    func next() async throws -> NearMessage {
        while true {
            if let message = decoder.pop() { return message }
            let chunk = try await bytes.readSome(max: 256 * 1024)
            try decoder.append(chunk)
        }
    }

    func cancel() {
        bytes.cancel()
    }
}

final class QuicGroup {
    let group: NWConnectionGroup
    let queue = DispatchQueue(label: "neardesk.quic.group")
    private static let tokenKey = DispatchSpecificKey<ObjectIdentifier>()
    private var inboundContinuation: AsyncStream<MessagePipe>.Continuation?
    let inbound: AsyncStream<MessagePipe>
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didResume = false
    private var pipes: [ObjectIdentifier: MessagePipe] = [:]
    var onLost: (() -> Void)?

    init(group: NWConnectionGroup) {
        self.group = group
        var continuation: AsyncStream<MessagePipe>.Continuation?
        inbound = AsyncStream { continuation = $0 }
        inboundContinuation = continuation
        queue.setSpecific(key: Self.tokenKey, value: ObjectIdentifier(self))
    }

    func start() async throws {
        group.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            guard self.pipes[id] == nil else { return }
            // Start and retain on this queue before returning from the callback.
            // Only ready application streams reach the consumer; an underlying
            // connection callback can remain preparing without application bytes.
            let pipe = MessagePipe(connection: connection, queue: self.queue, onReady: { [weak self] in
                guard let self, let pipe = self.pipes[id] else { return }
                self.inboundContinuation?.yield(pipe)
            })
            self.pipes[id] = pipe
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuation = cont
            group.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            group.start(queue: queue)
        }
    }

    func openStream(_ direction: NWProtocolQUIC.Options.Direction) throws -> MessagePipe {
        if DispatchQueue.getSpecific(key: Self.tokenKey) == ObjectIdentifier(self) {
            return try extract(direction)
        }
        return try queue.sync { try extract(direction) }
    }

    private func extract(_ direction: NWProtocolQUIC.Options.Direction) throws -> MessagePipe {
        let options = NWProtocolQUIC.Options()
        options.direction = direction
        guard let connection = group.extract(connectionTo: nil, using: options) else {
            throw TransportError.extract
        }
        // A locally opened unidirectional stream is send-only.
        let pipe = MessagePipe(connection: connection, queue: queue, receives: direction == .bidirectional)
        pipes[ObjectIdentifier(connection)] = pipe
        return pipe
    }

    func cancel() {
        if DispatchQueue.getSpecific(key: Self.tokenKey) == ObjectIdentifier(self) {
            cancelOnQueue()
        } else {
            queue.sync { cancelOnQueue() }
        }
    }

    private func cancelOnQueue() {
        inboundContinuation?.finish()
        pipes.values.forEach { $0.cancel() }
        group.cancel()
        resume(with: .failure(TransportError.cancelled))
    }

    private func handle(_ state: NWConnectionGroup.State) {
        switch state {
        case .ready:
            resume(with: .success(()))
        case .waiting:
            break
        case .failed(let error):
            if didResume { onLost?() } else { resume(with: .failure(TransportError.failed(error))) }
        case .cancelled:
            if didResume { onLost?() } else { resume(with: .failure(TransportError.cancelled)) }
        default:
            break
        }
    }

    private func resume(with result: Result<Void, Error>) {
        guard !didResume, let readyContinuation else { return }
        didResume = true
        self.readyContinuation = nil
        readyContinuation.resume(with: result)
    }
}

final class QuicListener {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "neardesk.listen")
    var onFailure: ((Error) -> Void)?
    var onReady: ((UInt16) -> Void)?
    var onState: ((String) -> Void)?
    var onGroup: ((QuicGroup) -> Void)?

    func start(identity: sec_identity_t, serviceName: String?, txt: [String: String]) throws {
        let parameters = QuicParameters.make(identity: identity, verify: .acceptPeer)
        let listener = try NWListener(using: parameters, on: .any)
        if let serviceName {
            var record = NWTXTRecord()
            for (key, value) in txt where !key.isEmpty && !value.isEmpty {
                record[key] = value
            }
            listener.service = NWListener.Service(
                name: serviceName,
                type: NearDeskWire.serviceType,
                domain: nil,
                txtRecord: record
            )
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard self?.listener === listener else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self?.onReady?(port)
                self?.onState?("Sharing on UDP \(port)")
            case .waiting(let error):
                self?.onState?(describeNetwork(error))
            case .failed(let error):
                self?.onFailure?(error)
            case .cancelled:
                self?.onState?("Sharing stopped")
            default:
                break
            }
        }
        listener.newConnectionGroupHandler = { [weak self] group in
            self?.onGroup?(QuicGroup(group: group))
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

public struct DiscoveredMac: Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var endpoint: NWEndpoint

    public init(id: String, name: String, version: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.version = version
        self.endpoint = endpoint
    }
}

public final class HostBrowser {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "neardesk.browse")
    public var onMacs: (([DiscoveredMac]) -> Void)?
    public var onState: ((String) -> Void)?

    public init() {}

    public func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: NearDeskWire.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("Looking for NearDesk Macs")
            case .waiting(let error):
                self?.onState?(describeNetwork(error))
            case .failed(let error):
                self?.onState?(describeNetwork(error))
            case .cancelled:
                break
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                let endpoint = result.endpoint
                let fallback = endpoint.serviceName ?? "NearDesk Mac"
                var name = fallback
                var version = ""
                if case .bonjour(let record) = result.metadata {
                    if let advertised = record["name"], !advertised.isEmpty { name = advertised }
                    version = record["ver"] ?? ""
                }
                return DiscoveredMac(id: "\(endpoint)", name: name, version: version, endpoint: endpoint)
            }.sorted { $0.name < $1.name }
            self?.onMacs?(macs)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

extension NWEndpoint {
    var serviceName: String? {
        switch self {
        case .service(let name, _, _, _):
            return name
        default:
            return nil
        }
    }
}

public enum TofuStore {
    private static func key(_ host: String) -> String { "neardesk.tofu." + host }

    public static func remembered(host: String) -> String? {
        UserDefaults.standard.string(forKey: key(host))
    }

    public static func remember(host: String, fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: key(host))
    }

    public static func forget(host: String) {
        UserDefaults.standard.removeObject(forKey: key(host))
    }
}
