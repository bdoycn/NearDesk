// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SpikePaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NearDesk", isDirectory: true)
    }

    public static var spike: URL { support.appendingPathComponent("spike", isDirectory: true) }
    public static var identity: URL { support.appendingPathComponent("identity", isDirectory: true) }

    public static var videoCSV: URL { spike.appendingPathComponent("latency-video.csv") }
    public static var inputCSV: URL { spike.appendingPathComponent("latency-input.csv") }
    public static var videoMarks: URL { spike.appendingPathComponent("host-video-marks.csv") }
    public static var injectMarks: URL { spike.appendingPathComponent("host-inject-marks.csv") }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
