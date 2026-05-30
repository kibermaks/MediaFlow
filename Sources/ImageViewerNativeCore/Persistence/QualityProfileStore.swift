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

struct SavedQualityLibrary: Codable {
    var entries: [String: SavedQualityProfile] = [:]
}

struct SavedQualityProfile: Codable {
    var fileName: String
    var updatedAt: Date
    var qualityModeRaw: Int
    var frameInterpolationEnabled: Bool
    var naturalDenoiseEnabled: Bool
    var naturalDenoiseStrength: Float
    var toneRecoveryEnabled: Bool
    var toneRecoveryStrength: Float
    var brightnessBoost: Float?
    var magicRescueEnabled: Bool
    var magicRescueStrength: Float
}

enum QualityProfileStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppMetadata.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("QualityProfiles.json")
    }

    static func applyProfile(for item: CollageItem) -> Bool {
        guard let hash = item.fileHash, let profile = readLibrary().entries[hash] else { return false }
        item.qualityModeRaw = profile.qualityModeRaw
        item.frameInterpolationEnabled = profile.frameInterpolationEnabled
        item.naturalDenoiseEnabled = profile.naturalDenoiseEnabled
        item.naturalDenoiseStrength = max(0, min(1, profile.naturalDenoiseStrength))
        item.toneRecoveryEnabled = profile.toneRecoveryEnabled
        item.toneRecoveryStrength = max(0, min(1, profile.toneRecoveryStrength))
        item.brightnessBoost = max(0, min(1, profile.brightnessBoost ?? item.brightnessBoost))
        item.magicRescueEnabled = profile.magicRescueEnabled
        item.magicRescueStrength = max(0, min(1, profile.magicRescueStrength))
        return true
    }

    static func saveProfile(for item: CollageItem) {
        guard let hash = item.fileHash else { return }
        var library = readLibrary()
        library.entries[hash] = SavedQualityProfile(
            fileName: item.name,
            updatedAt: Date(),
            qualityModeRaw: item.qualityModeRaw,
            frameInterpolationEnabled: item.frameInterpolationEnabled,
            naturalDenoiseEnabled: item.naturalDenoiseEnabled,
            naturalDenoiseStrength: max(0, min(1, item.naturalDenoiseStrength)),
            toneRecoveryEnabled: item.toneRecoveryEnabled,
            toneRecoveryStrength: max(0, min(1, item.toneRecoveryStrength)),
            brightnessBoost: max(0, min(1, item.brightnessBoost)),
            magicRescueEnabled: item.magicRescueEnabled,
            magicRescueStrength: max(0, min(1, item.magicRescueStrength))
        )

        do {
            try writeLibrary(library)
        } catch {
            NSLog("Quality profile save failed: \(error)")
        }
    }

    static func clearAll() throws {
        try writeLibrary(SavedQualityLibrary())
    }

    private static func readLibrary() -> SavedQualityLibrary {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SavedQualityLibrary.self, from: data)
        } catch {
            return SavedQualityLibrary()
        }
    }

    private static func writeLibrary(_ library: SavedQualityLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
    }
}
