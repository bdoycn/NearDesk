// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
@preconcurrency import Security

public struct SpikeIdentity {
    public let identity: SecIdentity
    public let certificateDER: Data
    public let fingerprintHex: String

    public var networkIdentity: sec_identity_t {
        guard let wrapped = sec_identity_create(identity) else {
            fatalError("sec_identity_create failed")
        }
        return wrapped
    }

    public static func loadOrCreate() throws -> SpikeIdentity {
        try SpikePaths.ensure(SpikePaths.identity)
        let certURL = SpikePaths.identity.appendingPathComponent("cert.der")
        let keyURL = SpikePaths.identity.appendingPathComponent("key.dat")
        if let certData = try? Data(contentsOf: certURL),
           let keyData = try? Data(contentsOf: keyURL),
           let loaded = try? importIdentity(certificateDER: certData, privateKey: keyData) {
            return loaded
        }
        let created = try generate()
        try created.identity.certificateDER.write(to: certURL, options: .atomic)
        try created.privateKeyData.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return created.identity
    }

    static func generate() throws -> (identity: SpikeIdentity, privateKeyData: Data) {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.key
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw IdentityError.key }
        var copyError: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &copyError) as Data? else {
            throw copyError?.takeRetainedValue() ?? IdentityError.key
        }
        guard let privateBytes = SecKeyCopyExternalRepresentation(privateKey, &copyError) as Data? else {
            throw copyError?.takeRetainedValue() ?? IdentityError.key
        }
        let der = try SelfSignedP256.certificateDER(publicPoint: publicBytes, privateKey: privateKey)
        let identity = try importIdentity(certificateDER: der, privateKey: privateBytes)
        return (identity, privateBytes)
    }

    private static func importIdentity(certificateDER: Data, privateKey: Data) throws -> SpikeIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw IdentityError.certificate
        }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? IdentityError.key
        }
        guard let identity = SecIdentityCreate(nil, certificate, key) else {
            throw IdentityError.identity
        }
        return SpikeIdentity(
            identity: identity,
            certificateDER: certificateDER,
            fingerprintHex: fingerprint(of: certificateDER)
        )
    }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: min(2, hex.distance(from: start, to: hex.endIndex)))
            return String(hex[start..<end])
        }.joined(separator: ":").uppercased()
    }
}

enum IdentityError: Error {
    case key
    case certificate
    case identity
    case signature
}

enum SelfSignedP256 {
    static func certificateDER(publicPoint: Data, privateKey: SecKey) throws -> Data {
        var point = publicPoint
        if point.count == 64 { point.insert(0x04, at: 0) }
        guard point.count == 65, point.first == 0x04 else { throw IdentityError.key }

        let serial = serialNumber()
        let notBefore = Date().addingTimeInterval(-3600)
        let notAfter = Date().addingTimeInterval(730 * 24 * 3600)
        let tbs = tbsCertificate(serial: serial, notBefore: notBefore, notAfter: notAfter, publicPoint: point)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            nil
        ) as Data? else { throw IdentityError.signature }
        let signatureDER = try derSignature(signature)
        return ASN1.sequence([
            tbs,
            algorithmIdentifier,
            ASN1.bitString(signatureDER),
        ])
    }

    private static func tbsCertificate(serial: Data, notBefore: Date, notAfter: Date, publicPoint: Data) -> Data {
        let name = distinguishedName("NearDesk")
        let keyUsage = ASN1.sequence([
            OID.keyUsage,
            ASN1.boolean(true),
            ASN1.octetString(ASN1.bitString(Data([0x05, 0xA0]), unusedBitsAlreadyIncluded: true)),
        ])
        let extensions = ASN1.sequence([keyUsage])
        return ASN1.sequence([
            ASN1.explicit(0, ASN1.integer(Data([0x02]))),
            ASN1.integer(serial),
            algorithmIdentifier,
            name,
            ASN1.sequence([ASN1.utcTime(notBefore), ASN1.utcTime(notAfter)]),
            name,
            subjectPublicKeyInfo(publicPoint),
            ASN1.explicit(3, extensions),
        ])
    }

    private static func distinguishedName(_ commonName: String) -> Data {
        ASN1.sequence([
            ASN1.set([
                ASN1.sequence([
                    OID.commonName,
                    ASN1.utf8(commonName),
                ]),
            ]),
        ])
    }

    private static func subjectPublicKeyInfo(_ point: Data) -> Data {
        ASN1.sequence([
            ASN1.sequence([OID.ecPublicKey, OID.prime256v1]),
            ASN1.bitString(point),
        ])
    }

    private static var algorithmIdentifier: Data {
        ASN1.sequence([OID.ecdsaWithSHA256])
    }

    private static func serialNumber() -> Data {
        var bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        bytes[0] &= 0x7F
        if bytes.allSatisfy({ $0 == 0 }) { bytes[7] = 1 }
        return Data(bytes)
    }

    private static func derSignature(_ rawOrDER: Data) throws -> Data {
        if rawOrDER.first == 0x30 { return rawOrDER }
        guard rawOrDER.count == 64 else { throw IdentityError.signature }
        let r = Data(rawOrDER.prefix(32))
        let s = Data(rawOrDER.suffix(32))
        return ASN1.sequence([ASN1.integer(r), ASN1.integer(s)])
    }
}

enum OID {
    static let ecdsaWithSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let ecPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let prime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])
    static let keyUsage = Data([0x06, 0x03, 0x55, 0x1D, 0x0F])
}

enum ASN1 {
    static func tag(_ identifier: UInt8, _ content: Data) -> Data {
        var out = Data([identifier])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ parts: [Data]) -> Data {
        tag(0x30, parts.reduce(into: Data()) { $0.append($1) })
    }

    static func set(_ parts: [Data]) -> Data {
        tag(0x31, parts.reduce(into: Data()) { $0.append($1) })
    }

    static func integer(_ data: Data) -> Data {
        var bytes = data
        while bytes.count > 1, bytes.first == 0x00, (bytes.dropFirst().first ?? 0) < 0x80 {
            bytes.removeFirst()
        }
        if bytes.first ?? 0 >= 0x80 { bytes.insert(0x00, at: 0) }
        if bytes.isEmpty { bytes = Data([0]) }
        return tag(0x02, bytes)
    }

    static func bitString(_ content: Data) -> Data {
        tag(0x03, Data([0x00]) + content)
    }

    /// `content` already begins with the unused-bits byte.
    static func bitString(_ content: Data, unusedBitsAlreadyIncluded: Bool) -> Data {
        if unusedBitsAlreadyIncluded { return tag(0x03, content) }
        return bitString(content)
    }

    static func octetString(_ content: Data) -> Data { tag(0x04, content) }
    static func utf8(_ string: String) -> Data { tag(0x0C, Data(string.utf8)) }
    static func boolean(_ value: Bool) -> Data { Data([0x01, 0x01, value ? 0xFF : 0x00]) }

    static func explicit(_ number: UInt8, _ content: Data) -> Data {
        tag(0xA0 | number, content)
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tag(0x17, Data(formatter.string(from: date).utf8))
    }
}
