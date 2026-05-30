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
    var playbackMode: VideoPlaybackMode?
    var swingDirection: Float?
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

enum VideoLoopBoundaryPlanner {
    static func swingDecision(
        loops: [(a: Double, b: Double)],
        time: Double,
        direction: Float,
        guardBand: Double,
        edgeOffset: Double = 0.02
    ) -> (target: Double, direction: Float)? {
        let ordered = loops
            .filter { $0.b - $0.a > 0.05 }
            .sorted { $0.a < $1.a }
        guard !ordered.isEmpty else { return nil }

        let isForward = direction >= 0
        if let index = ordered.firstIndex(where: { time >= $0.a - guardBand && time <= $0.b + guardBand }) {
            let loop = ordered[index]
            if isForward, time >= loop.b - guardBand {
                if index < ordered.count - 1 {
                    return (ordered[index + 1].a, 1)
                }
                return (max(loop.a, loop.b - edgeOffset), -1)
            }
            if !isForward, time <= loop.a + guardBand {
                if index > 0 {
                    return (ordered[index - 1].b, -1)
                }
                return (loop.a, 1)
            }
            return nil
        }

        if isForward {
            if let next = ordered.first(where: { $0.b > time }) {
                return (next.a, 1)
            }
            let last = ordered[ordered.count - 1]
            return (max(last.a, last.b - edgeOffset), -1)
        }

        if let previous = ordered.last(where: { $0.a < time }) {
            return (previous.b, -1)
        }
        return (ordered[0].a, 1)
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
