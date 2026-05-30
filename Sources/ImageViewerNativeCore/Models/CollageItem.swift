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

final class CollageItem: Equatable, @unchecked Sendable {
    static func == (lhs: CollageItem, rhs: CollageItem) -> Bool { lhs === rhs }

    let id = UUID()
    let url: URL
    let name: String
    let kind: MediaKind
    let pixelSize: CGSize
    var texture: MTLTexture?
    var dynamicRange: MediaDynamicRange = .standard

    var player: AVPlayer?
    var videoOutput: AVPlayerItemVideoOutput?
    var videoTextureMapping: VideoTextureMapping?
    var didLogVideoBufferFormat = false
    var currentVideoTextureRef: CVMetalTexture?
    var previousVideoTexture: MTLTexture?
    var previousVideoTextureRef: CVMetalTexture?
    var videoLastItemTime: Double?
    var videoLastHostTime: TimeInterval?
    var videoNominalFrameDuration: TimeInterval = 1.0 / 30.0
    var videoObservedFrameInterval: TimeInterval = 1.0 / 30.0
    var videoFrameTransitionStart: TimeInterval = 0
    var abLoops: [(a: Double, b: Double)] = []
    var pendingA: Double?
    var pendingB: Double?
    var abLoopBypassUntil: TimeInterval = 0
    var fileHash: String?
    var hasSavedABHistory = false
    var qualityModeRaw = DefaultQualityStore.qualityModeRaw
    var frameInterpolationEnabled = FrameInterpolationStore.enabled
    var naturalDenoiseEnabled = NaturalDenoiseStore.enabled
    var naturalDenoiseStrength = NaturalDenoiseStore.strength
    var toneRecoveryEnabled = ToneRecoveryStore.enabled
    var toneRecoveryStrength = ToneRecoveryStore.strength
    var brightnessBoost = BrightnessBoostStore.strength
    var magicRescueEnabled = MagicRescueStore.enabled
    var magicRescueStrength = MagicRescueStore.strength
    var speed: Float = 1
    var volume: Float = 1
    var muted = false
    var playWhenVisible = true
    var frozenPlayWhenVisible: Bool?

    var cellRect: CGRect = .zero
    var contentRect: CGRect = .zero
    var cropRect: CGRect?
    var weight: CGFloat = 1
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero
    var rotationQuarterTurns: Int = 0 {
        didSet {
            let normalized = Self.normalizedRotationQuarterTurns(rotationQuarterTurns)
            if rotationQuarterTurns != normalized {
                rotationQuarterTurns = normalized
            }
        }
    }
    var selected = false

    init(url: URL, kind: MediaKind, pixelSize: CGSize, texture: MTLTexture?) {
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.pixelSize = pixelSize
        self.texture = texture
    }

    func resetVideoFrameHistory() {
        previousVideoTexture = nil
        previousVideoTextureRef = nil
        videoLastItemTime = nil
        videoLastHostTime = nil
        videoObservedFrameInterval = videoNominalFrameDuration
        videoFrameTransitionStart = CACurrentMediaTime()
    }

    var naturalAspect: CGFloat {
        max(0.08, pixelSize.width / max(1, pixelSize.height))
    }

    var cropAspect: CGFloat? {
        guard let cropRect else { return nil }
        return max(0.08, (cropRect.width * pixelSize.width) / max(1, cropRect.height * pixelSize.height))
    }

    var sourceVisibleAspect: CGFloat {
        cropAspect ?? naturalAspect
    }

    var visibleAspect: CGFloat {
        displayAspect(forSourceAspect: sourceVisibleAspect)
    }

    var packingAspect: CGFloat {
        max(0.12, min(10, visibleAspect * weight))
    }

    var canPan: Bool {
        cropRect != nil || zoom > 1.001
    }

    var durationSeconds: Double {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    var currentTimeSeconds: Double {
        player?.currentTime().seconds ?? 0
    }

    var isVideoPlaying: Bool {
        guard kind == .video, let player else { return false }
        return abs(player.rate) > 0.001 || player.timeControlStatus == .playing
    }

    var normalizedRotationQuarterTurns: Int {
        Self.normalizedRotationQuarterTurns(rotationQuarterTurns)
    }

    var isSideways: Bool {
        normalizedRotationQuarterTurns % 2 != 0
    }

    var playbackRate: Float {
        speed
    }

    static func normalizedRotationQuarterTurns(_ turns: Int) -> Int {
        let remainder = turns % 4
        return remainder >= 0 ? remainder : remainder + 4
    }

    func displayAspect(forSourceAspect sourceAspect: CGFloat) -> CGFloat {
        let safeAspect = max(0.08, sourceAspect)
        return isSideways ? max(0.08, 1 / safeAspect) : safeAspect
    }

    func sourceAspect(forDisplayAspect displayAspect: CGFloat) -> CGFloat {
        let safeAspect = max(0.08, displayAspect)
        return isSideways ? max(0.08, 1 / safeAspect) : safeAspect
    }

    func sourcePoint(fromDisplayNormalizedPoint point: CGPoint) -> CGPoint {
        let x = max(0, min(1, point.x))
        let y = max(0, min(1, point.y))
        switch normalizedRotationQuarterTurns {
        case 1:
            return CGPoint(x: y, y: 1 - x)
        case 2:
            return CGPoint(x: 1 - x, y: 1 - y)
        case 3:
            return CGPoint(x: 1 - y, y: x)
        default:
            return CGPoint(x: x, y: y)
        }
    }

    func sourceRect(fromDisplayNormalizedRect rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let corners = [
            CGPoint(x: standardized.minX, y: standardized.minY),
            CGPoint(x: standardized.maxX, y: standardized.minY),
            CGPoint(x: standardized.minX, y: standardized.maxY),
            CGPoint(x: standardized.maxX, y: standardized.maxY)
        ].map(sourcePoint(fromDisplayNormalizedPoint:))
        let minX = max(0, min(1, corners.map(\.x).min() ?? 0))
        let maxX = max(0, min(1, corners.map(\.x).max() ?? 1))
        let minY = max(0, min(1, corners.map(\.y).min() ?? 0))
        let maxY = max(0, min(1, corners.map(\.y).max() ?? 1))
        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }
}

struct FlowSlot {
    let item: CollageItem
    var cellRect: CGRect = .zero
    var contentRect: CGRect = .zero
}
