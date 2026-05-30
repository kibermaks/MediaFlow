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

    var visibleAspect: CGFloat {
        cropAspect ?? naturalAspect
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
        return player.rate > 0.001 || player.timeControlStatus == .playing
    }
}

struct FlowSlot {
    let item: CollageItem
    var cellRect: CGRect = .zero
    var contentRect: CGRect = .zero
}
