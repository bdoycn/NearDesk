// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `mach_continuous_time` converted to nanoseconds. Same value on every
/// process of one Mac, including across sleep.
public enum MonoClock {
    private static let scale: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public static func nanoseconds() -> UInt64 {
        let ticks = mach_continuous_time()
        return ticks * scale.numer / scale.denom
    }
}

public func nsDelta(_ later: UInt64, _ earlier: UInt64) -> Int64 {
    if later >= earlier { return Int64(later - earlier) }
    return -Int64(earlier - later)
}
