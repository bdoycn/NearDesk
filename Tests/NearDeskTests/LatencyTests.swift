// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import NearDeskCore

final class LatencyTests: XCTestCase {
    private var directory: URL!
    private var hub: LatencyHub!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        hub = LatencyHub(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        hub = nil
    }

    func testLoopbackCSVJoinsInputToLaterDirtyFrame() throws {
        hub.beginHost()
        hub.beginViewer(clocksMatch: true)
        hub.noteHostVideo(frameID: 3, t1: 200, t2: 300)
        hub.noteInput(eventID: 9, kind: "mouse_move", displayID: 42, eventMono: 1_000)
        hub.noteInjected(eventID: 9, tInject: 5_000)
        hub.notePresented(frameID: 1, t0: 4_000, t4: 8_000, qualifies: true)
        hub.notePresented(frameID: 2, t0: 5_000, t4: 9_000, qualifies: false)
        hub.noteClientVideo(
            frameID: 3,
            channelID: 1,
            encoderConfigID: 1,
            dirtyCount: 0,
            auBytes: 12,
            t0: 6_000,
            t3: 7_000,
            t4: 15_000
        )
        hub.notePresented(frameID: 3, t0: 6_000, t4: 15_000, qualifies: true)

        let video = try String(contentsOf: directory.appendingPathComponent("latency-video.csv"), encoding: .utf8)
        XCTAssertTrue(video.contains("frame_id,channel_id,encoder_config_id,dirty_rect_count,au_bytes,t0_capture_ns,t1_encode_done_ns,t2_send_ns,t3_recv_ns,t4_present_ns,gg_ns"))
        XCTAssertTrue(video.contains("3,1,1,0,12,6000,200,300,7000,15000,9000"))
        let input = try String(contentsOf: directory.appendingPathComponent("latency-input.csv"), encoding: .utf8)
        XCTAssertTrue(input.contains("event_id,kind,display_id,event_mono_ns,t_inject_ns,t4_present_ns,feedback_ns,e2e_ns,matched_frame_id"))
        XCTAssertTrue(input.contains("9,mouse_move,42,1000,5000,15000,10000,14000,3"))
        XCTAssertEqual(hub.snapshot.videoCount, 1)
        XCTAssertEqual(hub.snapshot.inputCount, 1)
        XCTAssertEqual(hub.snapshot.videoP50ms, 0.009)
        XCTAssertEqual(hub.snapshot.inputP50ms, 0.01)
    }

    func testMarkFileSuppliesHostTimes() throws {
        hub.beginHost()
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("host-video-marks.csv"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("4,11,22\n".utf8))
        try handle.close()
        hub.beginViewer(clocksMatch: true)
        hub.noteClientVideo(
            frameID: 4,
            channelID: 2,
            encoderConfigID: 1,
            dirtyCount: 1,
            auBytes: 8,
            t0: 10,
            t3: 40,
            t4: 50
        )
        let video = try String(contentsOf: directory.appendingPathComponent("latency-video.csv"), encoding: .utf8)
        XCTAssertTrue(video.contains("4,2,1,1,8,10,11,22,40,50,40"))
    }

    func testRemoteClocksLeavePinnedColumnsEmpty() throws {
        hub.beginHost()
        hub.beginViewer(clocksMatch: false)
        hub.noteHostVideo(frameID: 1, t1: 2, t2: 3)
        hub.noteClientVideo(
            frameID: 1,
            channelID: 1,
            encoderConfigID: 1,
            dirtyCount: 1,
            auBytes: 4,
            t0: 1,
            t3: 5,
            t4: 9
        )
        hub.noteInput(eventID: 2, kind: "key", displayID: 1, eventMono: 10)
        hub.noteInjected(eventID: 2, tInject: 20)
        hub.notePresented(frameID: 1, t0: 20, t4: 9, qualifies: true)
        let video = try String(contentsOf: directory.appendingPathComponent("latency-video.csv"), encoding: .utf8)
        XCTAssertTrue(video.contains("1,1,1,1,4,1,2,3,5,9,\n"))
        let input = try String(contentsOf: directory.appendingPathComponent("latency-input.csv"), encoding: .utf8)
        XCTAssertTrue(input.contains("2,key,1,10,20,9,,-1,1"))
        XCTAssertEqual(hub.snapshot.videoCount, 0)
        XCTAssertEqual(hub.snapshot.inputCount, 0)
    }
}
