import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import MetalKit
import Photos
import QuartzCore
import CryptoKit
import Darwin
import Security
import simd
import UniformTypeIdentifiers

enum PlaybackCryptoError: LocalizedError {
    case invalidFile
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "This encrypted playback file is invalid."
        case .randomFailed:
            return "Could not generate secure random bytes for playback encryption."
        }
    }
}

enum PlaybackCrypto {
    private static let magic = Data("IVPLAYBK1".utf8)
    private static let saltByteCount = 16
    // Keep the pre-rename HKDF info so older .ivplayback files remain readable.
    private static let info = Data("Image Viewer ivplayback v1".utf8)
    private static let embeddedSecret = Data([
        0x7d, 0x34, 0x09, 0xc8, 0x91, 0x52, 0xaf, 0x6e,
        0x20, 0xd7, 0x4b, 0xe3, 0x18, 0xa0, 0x65, 0xf9,
        0x43, 0xb2, 0x8c, 0x11, 0xfe, 0x5a, 0x76, 0xd0,
        0x9b, 0x27, 0xcc, 0x3f, 0x84, 0x6d, 0x01, 0xba
    ])

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encrypt(_ plaintext: Data) throws -> Data {
        let salt = try randomData(count: saltByteCount)
        let key = deriveKey(salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw PlaybackCryptoError.invalidFile }
        var output = Data()
        output.append(magic)
        output.append(salt)
        output.append(combined)
        return output
    }

    static func decrypt(_ data: Data) throws -> Data {
        guard data.starts(with: magic), data.count > magic.count + saltByteCount else {
            throw PlaybackCryptoError.invalidFile
        }
        let saltStart = magic.count
        let saltEnd = saltStart + saltByteCount
        let salt = data[saltStart..<saltEnd]
        let combined = data[saltEnd..<data.count]
        let key = deriveKey(salt: salt)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key)
    }

    private static func deriveKey(salt: some DataProtocol) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: embeddedSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PlaybackCryptoError.randomFailed }
        return Data(bytes)
    }
}
