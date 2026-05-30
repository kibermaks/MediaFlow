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

struct SavedPlayback: Codable {
    var items: [SavedItem]
    var flowSettings: SavedFlowSettings?
}

struct SavedFlowSettings: Codable {
    var maxVisibleItems: Int
    var rotationMode: FlowRotationMode
    var allowsRandomDuplicates: Bool
    var autoRotateEnabled: Bool
    var rotationInterval: TimeInterval
}

struct SavedItem: Codable {
    var path: String
    var weight: CGFloat
    var zoom: CGFloat
    var panX: CGFloat
    var panY: CGFloat
    var crop: CGRect?
    var rotationQuarterTurns: Int?
    var speed: Float
    var volume: Float?
    var muted: Bool
    var currentTime: Double?
    var playing: Bool?
    var abLoops: [SavedLoop]
}

enum PlaybackFile {
    static func isPlaybackURL(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare(AppMetadata.playbackFileExtension) == .orderedSame
    }

    static func normalizedSaveURL(_ url: URL) -> URL {
        var normalized = url
        while isPlaybackURL(normalized),
              normalized.deletingPathExtension().pathExtension.caseInsensitiveCompare(AppMetadata.playbackFileExtension) == .orderedSame {
            normalized = normalized.deletingPathExtension()
        }
        if !isPlaybackURL(normalized) {
            normalized = normalized.appendingPathExtension(AppMetadata.playbackFileExtension)
        }
        return normalized
    }
}

struct SavedLoop: Codable, Equatable {
    var a: Double
    var b: Double
}

struct SavedABLibrary: Codable {
    var entries: [String: SavedABEntry] = [:]
}

struct SavedABEntry: Codable {
    var fileName: String
    var updatedAt: Date
    var histories: [SavedABSnapshot]
}

struct SavedABSnapshot: Codable, Equatable {
    var createdAt: Date
    var loops: [SavedLoop]
}
