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

struct MetalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

struct VideoTextureMapping {
    let encodedSize: CGSize
    let displayRect: CGRect
    let displayToEncoded: CGAffineTransform

    static func make(encodedSize: CGSize, preferredTransform: CGAffineTransform) -> VideoTextureMapping? {
        guard encodedSize.width > 0,
              encodedSize.height > 0,
              encodedSize.width.isFinite,
              encodedSize.height.isFinite else { return nil }
        let displayRect = CGRect(origin: .zero, size: encodedSize).applying(preferredTransform).standardized
        guard displayRect.width > 0,
              displayRect.height > 0,
              displayRect.width.isFinite,
              displayRect.height.isFinite else { return nil }
        return VideoTextureMapping(
            encodedSize: encodedSize,
            displayRect: displayRect,
            displayToEncoded: preferredTransform.inverted()
        )
    }

    func textureCoordinate(displayUV: SIMD2<Float>) -> SIMD2<Float> {
        let displayPoint = CGPoint(
            x: displayRect.minX + CGFloat(displayUV.x) * displayRect.width,
            y: displayRect.minY + CGFloat(displayUV.y) * displayRect.height
        )
        let encodedPoint = displayPoint.applying(displayToEncoded)
        let u = max(0, min(1, encodedPoint.x / max(1, encodedSize.width)))
        let v = max(0, min(1, encodedPoint.y / max(1, encodedSize.height)))
        return SIMD2(Float(u), Float(v))
    }
}

enum MetalQualityMode: Int, CaseIterable {
    case best
    case linear
    case nearest
    case bicubic
    case lanczos2

    var displayName: String {
        switch self {
        case .best:
            return "Best"
        case .linear:
            return "Linear"
        case .nearest:
            return "Nearest"
        case .bicubic:
            return "Bicubic"
        case .lanczos2:
            return "Lanczos 2"
        }
    }

    var tooltip: String {
        switch self {
        case .best:
            return "Best adaptive Metal quality for images and video"
        case .linear:
            return "Hardware linear sampling"
        case .nearest:
            return "Nearest-neighbor diagnostic sampling"
        case .bicubic:
            return "Catmull-Rom bicubic magnification"
        case .lanczos2:
            return "Lanczos 2 magnification"
        }
    }

    func shaderSamplingMode(isMinifying: Bool) -> UInt32 {
        switch self {
        case .best:
            return isMinifying ? 0 : 3
        case .linear:
            return 0
        case .nearest:
            return 1
        case .bicubic:
            return 2
        case .lanczos2:
            return 3
        }
    }
}

struct MetalFragmentUniforms {
    var samplingMode: UInt32
    var hasPreviousTexture: UInt32
    var splitCompare: UInt32
    var viewportWidth: Float
    var temporalBlend: Float
    var denoiseStrength: Float
    var toneStrength: Float
    var magicStrength: Float
    var brightnessBoost: Float
    var temporalGuard: Float = 0
}
