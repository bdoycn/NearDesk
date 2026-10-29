// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum AnnexB {
    public static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    public static func fromLengthPrefixed(_ data: Data, lengthSize: Int = 4) -> Data {
        guard lengthSize == 4 || lengthSize == 3 || lengthSize == 2 || lengthSize == 1 else { return Data() }
        var output = Data()
        var index = 0
        let bytes = [UInt8](data)
        while index + lengthSize <= bytes.count {
            var length = 0
            for shift in 0..<lengthSize {
                length = (length << 8) | Int(bytes[index + shift])
            }
            index += lengthSize
            guard length > 0, index + length <= bytes.count else { break }
            output.append(startCode)
            output.append(contentsOf: bytes[index..<(index + length)])
            index += length
        }
        return output
    }

    /// NAL payloads without start codes.
    public static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var markers: [(payload: Int, codeLength: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                markers.append((index + 4, 4))
                index += 4
                continue
            }
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                markers.append((index + 3, 3))
                index += 3
                continue
            }
            index += 1
        }
        var nals: [Data] = []
        for (offset, marker) in markers.enumerated() {
            let end: Int
            if offset + 1 < markers.count {
                let next = markers[offset + 1]
                end = next.payload - next.codeLength
            } else {
                end = bytes.count
            }
            if end > marker.payload {
                nals.append(Data(bytes[marker.payload..<end]))
            }
        }
        return nals
    }

    public static func join(_ nals: [Data]) -> Data {
        var output = Data()
        for nal in nals where !nal.isEmpty {
            output.append(startCode)
            output.append(nal)
        }
        return output
    }

    public static func toLengthPrefixed(_ annexB: Data, drop: (Data) -> Bool = { _ in false }) -> Data {
        var output = Data()
        for nal in split(annexB) where !nal.isEmpty && !drop(nal) {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(nal)
        }
        return output
    }

    public static func hevcType(_ nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return (first >> 1) & 0x3F
    }

    public static func h264Type(_ nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return first & 0x1F
    }

    public static func isParameterSet(nal: Data, hevc: Bool) -> Bool {
        if hevc {
            guard let type = hevcType(nal) else { return false }
            return type == 32 || type == 33 || type == 34
        }
        guard let type = h264Type(nal) else { return false }
        return type == 7 || type == 8
    }
}
