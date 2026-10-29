// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(truncatingIfNeeded: value))
        u16(UInt16(truncatingIfNeeded: value >> 16))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value))
        u32(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func i32(_ value: Int32) {
        u32(UInt32(bitPattern: value))
    }

    mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

struct ByteCursor {
    private let data: Data
    private var index: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - index }
    var isEmpty: Bool { remaining == 0 }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.malformed }
        defer { index += 1 }
        return data[data.startIndex + index]
    }

    mutating func u16() throws -> UInt16 {
        let lo = UInt16(try u8())
        let hi = UInt16(try u8())
        return lo | (hi << 8)
    }

    mutating func u32() throws -> UInt32 {
        let lo = UInt32(try u16())
        let hi = UInt32(try u16())
        return lo | (hi << 16)
    }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | (hi << 32)
    }

    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ProtocolError.malformed }
        let start = data.startIndex + index
        let out = data.subdata(in: start..<(start + count))
        index += count
        return out
    }

    func expectExhausted() throws {
        if remaining != 0 { throw ProtocolError.malformed }
    }
}

enum UTF8Bytes {
    static func clipped(_ string: String, maxBytes: Int) -> Data {
        var data = Data()
        data.reserveCapacity(min(maxBytes, string.utf8.count))
        for scalar in string.unicodeScalars {
            let encoded = Data(String(scalar).utf8)
            if data.count + encoded.count > maxBytes { break }
            data.append(encoded)
        }
        return data
    }
}
