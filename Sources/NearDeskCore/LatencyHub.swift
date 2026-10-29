// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct LatencySnapshot: Equatable {
    public var videoCount: Int = 0
    public var videoP50ms: Double?
    public var videoP95ms: Double?
    public var inputCount: Int = 0
    public var inputP50ms: Double?

    public static let empty = LatencySnapshot()
}

public final class LatencyHub {
    public static let shared = LatencyHub()
    private let directory: URL
    private var videoCSV: URL { directory.appendingPathComponent("latency-video.csv") }
    private var inputCSV: URL { directory.appendingPathComponent("latency-input.csv") }
    private var videoMarks: URL { directory.appendingPathComponent("host-video-marks.csv") }
    private var injectMarks: URL { directory.appendingPathComponent("host-inject-marks.csv") }

    init(directory: URL = SpikePaths.spike) {
        self.directory = directory
    }

    public var onSnapshot: ((LatencySnapshot) -> Void)?

    private let lock = NSLock()
    private var videoHost: [UInt64: (t1: UInt64, t2: UInt64)] = [:]
    private var videoClient: [UInt64: ClientVideo] = [:]
    private var writtenVideo = Set<UInt64>()
    private var inputs: [UInt64: PendingInput] = [:]
    private var frames: [QualifyingFrame] = []
    private var videoGG: [Double] = []
    private var inputFeedback: [Double] = []
    private var videoLinesRead = 0
    private var injectLinesRead = 0
    private var clocksMatch = false
    private let videoHeader = "frame_id,channel_id,encoder_config_id,dirty_rect_count,au_bytes,t0_capture_ns,t1_encode_done_ns,t2_send_ns,t3_recv_ns,t4_present_ns,gg_ns"
    private let inputHeader = "event_id,kind,display_id,event_mono_ns,t_inject_ns,t4_present_ns,feedback_ns,e2e_ns,matched_frame_id"

    public func beginHost() {
        lock.lock()
        videoHost.removeAll()
        videoLinesRead = 0
        injectLinesRead = 0
        lock.unlock()
        rewrite(videoMarks, header: "frame_id,t1_encode_done_ns,t2_send_ns")
        rewrite(injectMarks, header: "event_id,t_inject_ns")
    }

    /// `clocksMatch` is true only when both sides share `mach_continuous_time`
    /// (this Mac's loopback). Across Macs, `gg_ns` and `feedback_ns` stay empty.
    public func beginViewer(clocksMatch: Bool) {
        lock.lock()
        videoHost.removeAll()
        videoClient.removeAll()
        writtenVideo.removeAll()
        inputs.removeAll()
        frames.removeAll()
        videoGG.removeAll()
        inputFeedback.removeAll()
        videoLinesRead = 0
        injectLinesRead = 0
        self.clocksMatch = clocksMatch
        lock.unlock()
        rewrite(videoCSV, header: videoHeader)
        rewrite(inputCSV, header: inputHeader)
        publish()
    }

    public func noteHostVideo(frameID: UInt64, t1: UInt64, t2: UInt64) {
        lock.lock()
        videoHost[frameID] = (t1, t2)
        lock.unlock()
        append(videoMarks, line: "\(frameID),\(t1),\(t2)")
        flushLockedWork()
    }

    public func noteClientVideo(
        frameID: UInt64,
        channelID: UInt8,
        encoderConfigID: UInt16,
        dirtyCount: Int,
        auBytes: Int,
        t0: UInt64,
        t3: UInt64,
        t4: UInt64
    ) {
        lock.lock()
        videoClient[frameID] = ClientVideo(
            channelID: channelID,
            encoderConfigID: encoderConfigID,
            dirtyCount: dirtyCount,
            auBytes: auBytes,
            t0: t0,
            t3: t3,
            t4: t4
        )
        lock.unlock()
        flushLockedWork()
    }

    public func noteInput(eventID: UInt64, kind: String, displayID: UInt32, eventMono: UInt64) {
        lock.lock()
        var pending = inputs[eventID] ?? PendingInput(eventID: eventID, kind: kind, displayID: displayID, eventMono: eventMono, tInject: nil)
        pending.kind = kind
        pending.displayID = displayID
        pending.eventMono = eventMono
        inputs[eventID] = pending
        lock.unlock()
        flushLockedWork()
    }

    public func noteInjected(eventID: UInt64, tInject: UInt64) {
        lock.lock()
        var pending = inputs[eventID] ?? PendingInput(eventID: eventID, kind: "key", displayID: 0, eventMono: 0, tInject: nil)
        pending.tInject = tInject
        inputs[eventID] = pending
        lock.unlock()
        append(injectMarks, line: "\(eventID),\(tInject)")
        flushLockedWork()
    }

    public func notePresented(frameID: UInt64, t0: UInt64, t4: UInt64, qualifies: Bool) {
        guard qualifies else { return }
        lock.lock()
        frames.append(QualifyingFrame(frameID: frameID, t0: t0, t4: t4))
        if frames.count > 240 { frames.removeFirst(frames.count - 240) }
        lock.unlock()
        flushLockedWork()
    }

    public var snapshot: LatencySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    private func flushLockedWork() {
        lock.lock()
        ingestMarkFiles()
        var videoLines: [String] = []
        var inputLines: [String] = []
        for (frameID, client) in videoClient where !writtenVideo.contains(frameID) {
            guard let host = videoHost[frameID] else { continue }
            let gg = nsDelta(client.t4, client.t0)
            let ggField = clocksMatch ? String(gg) : ""
            videoLines.append("\(frameID),\(client.channelID),\(client.encoderConfigID),\(client.dirtyCount),\(client.auBytes),\(client.t0),\(host.t1),\(host.t2),\(client.t3),\(client.t4),\(ggField)")
            writtenVideo.insert(frameID)
            videoClient[frameID] = nil
            videoHost[frameID] = nil
            if clocksMatch {
                videoGG.append(Double(gg) / 1_000_000)
                if videoGG.count > 300 { videoGG.removeFirst(videoGG.count - 300) }
            }
        }
        let pendingIDs = inputs.keys.filter { inputs[$0]?.tInject != nil && inputs[$0]?.written != true }
        for eventID in pendingIDs {
            guard var input = inputs[eventID], let tInject = input.tInject else { continue }
            guard let frame = frames.first(where: { $0.t0 >= tInject }) else { continue }
            let feedback = nsDelta(frame.t4, tInject)
            let e2e = nsDelta(frame.t4, input.eventMono)
            let feedbackField = clocksMatch ? String(feedback) : ""
            inputLines.append("\(input.eventID),\(input.kind),\(input.displayID),\(input.eventMono),\(tInject),\(frame.t4),\(feedbackField),\(e2e),\(frame.frameID)")
            input.written = true
            inputs[eventID] = input
            if clocksMatch {
                inputFeedback.append(Double(feedback) / 1_000_000)
                if inputFeedback.count > 100 { inputFeedback.removeFirst(inputFeedback.count - 100) }
            }
        }
        if let oldest = frames.first?.t0 {
            inputs = inputs.filter { _, input in
                if input.written { return false }
                if let tInject = input.tInject, tInject + 2_000_000_000 < oldest { return false }
                return true
            }
        }
        lock.unlock()
        videoLines.forEach { append(videoCSV, line: $0) }
        inputLines.forEach { append(inputCSV, line: $0) }
        if !videoLines.isEmpty || !inputLines.isEmpty { publish() }
    }

    private func ingestMarkFiles() {
        ingest(videoMarks, cursor: &videoLinesRead) { fields in
            guard fields.count == 3, let id = UInt64(fields[0]), let t1 = UInt64(fields[1]), let t2 = UInt64(fields[2]) else { return }
            if videoHost[id] == nil { videoHost[id] = (t1, t2) }
        }
        ingest(injectMarks, cursor: &injectLinesRead) { fields in
            guard fields.count == 2, let id = UInt64(fields[0]), let tInject = UInt64(fields[1]) else { return }
            var pending = inputs[id] ?? PendingInput(eventID: id, kind: "key", displayID: 0, eventMono: 0, tInject: nil)
            if pending.tInject == nil { pending.tInject = tInject }
            inputs[id] = pending
        }
    }

    private func ingest(_ url: URL, cursor: inout Int, apply: ([String]) -> Void) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        if lines.count < cursor { cursor = 0 }
        guard cursor < lines.count else { return }
        for raw in lines.dropFirst(cursor) {
            if raw.hasPrefix("frame_id") || raw.hasPrefix("event_id") || raw.isEmpty { continue }
            apply(raw.split(separator: ",").map(String.init))
        }
        cursor = lines.count
    }

    private func publish() {
        let snap = snapshot
        let callback = onSnapshot
        DispatchQueue.main.async { callback?(snap) }
    }

    private func makeSnapshot() -> LatencySnapshot {
        LatencySnapshot(
            videoCount: videoGG.count,
            videoP50ms: percentile(videoGG, 0.50),
            videoP95ms: percentile(videoGG, 0.95),
            inputCount: inputFeedback.count,
            inputP50ms: percentile(inputFeedback, 0.50)
        )
    }

    private func rewrite(_ url: URL, header: String) {
        try? SpikePaths.ensure(directory)
        try? (header + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ url: URL, line: String) {
        try? SpikePaths.ensure(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

private struct ClientVideo {
    var channelID: UInt8
    var encoderConfigID: UInt16
    var dirtyCount: Int
    var auBytes: Int
    var t0: UInt64
    var t3: UInt64
    var t4: UInt64
}

private struct PendingInput {
    var eventID: UInt64
    var kind: String
    var displayID: UInt32
    var eventMono: UInt64
    var tInject: UInt64?
    var written = false
}

private struct QualifyingFrame {
    var frameID: UInt64
    var t0: UInt64
    var t4: UInt64
}

private func percentile(_ samples: [Double], _ p: Double) -> Double? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
}
