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

final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var canvas: MetalCollageView?
    var qualityMode: MetalQualityMode = .best
    var frameInterpolationEnabled = FrameInterpolationStore.enabled
    var naturalDenoiseEnabled = NaturalDenoiseStore.enabled
    var naturalDenoiseStrength = NaturalDenoiseStore.strength
    var toneRecoveryEnabled = ToneRecoveryStore.enabled
    var toneRecoveryStrength = ToneRecoveryStore.strength
    var brightnessBoost = BrightnessBoostStore.strength
    var magicRescueEnabled = MagicRescueStore.enabled
    var magicRescueStrength = MagicRescueStore.strength
    var splitCompareEnabled = SplitCompareStore.enabled
    var splitCompareReversed = SplitCompareStore.reversed
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    init?(device: MTLDevice, colorPixelFormat: MTLPixelFormat) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue

        let source = MetalRendererShaderSource.source

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Metal pipeline failed: \(error)")
            return nil
        }

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        linearDescriptor.mipFilter = .linear
        linearDescriptor.maxAnisotropy = 16
        linearDescriptor.sAddressMode = .clampToEdge
        linearDescriptor.tAddressMode = .clampToEdge
        guard let linearSampler = device.makeSamplerState(descriptor: linearDescriptor) else { return nil }
        self.linearSampler = linearSampler

        let nearestDescriptor = MTLSamplerDescriptor()
        nearestDescriptor.minFilter = .nearest
        nearestDescriptor.magFilter = .nearest
        nearestDescriptor.mipFilter = .nearest
        nearestDescriptor.sAddressMode = .clampToEdge
        nearestDescriptor.tAddressMode = .clampToEdge
        guard let nearestSampler = device.makeSamplerState(descriptor: nearestDescriptor) else { return nil }
        self.nearestSampler = nearestSampler

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        canvas?.relayout()
    }

    func draw(in view: MTKView) {
        guard let canvas,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        encoder.setFragmentSamplerState(nearestSampler, index: 1)

        for slot in canvas.visibleSlots {
            let item = slot.item
            updateVideoTextureIfNeeded(for: item)
            guard let texture = item.texture else { continue }
            let drawRect = canvas.drawRect(for: slot)
            guard drawRect.width > 1, drawRect.height > 1 else { continue }
            drawTexture(texture, for: item, in: drawRect, viewport: view.bounds.size, drawableSize: view.drawableSize, encoder: encoder)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        canvas.recordRenderedFrame()
    }

    private func updateVideoTextureIfNeeded(for item: CollageItem) {
        guard item.kind == .video,
              let output = item.videoOutput,
              let cache = textureCache else { return }

        let hostTime = CACurrentMediaTime()
        let time = output.itemTime(forHostTime: hostTime)
        var displayTime = CMTime.invalid
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else { return }

        logVideoBufferFormatIfNeeded(pixelBuffer, for: item)

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let texturePixelFormat: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_64RGBAHalf:
            texturePixelFormat = .rgba16Float
        case kCVPixelFormatType_128RGBAFloat:
            texturePixelFormat = .rgba32Float
        default:
            texturePixelFormat = .bgra8Unorm
        }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            texturePixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        if status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
            let itemTime = displayTime.isNumeric ? displayTime.seconds : time.seconds
            let lastItemTime = item.videoLastItemTime
            var canBlendFromCurrentTexture = false
            if let lastItemTime, itemTime.isFinite {
                let frameDelta = itemTime - lastItemTime
                let maxBlendGap = max(0.08, item.videoNominalFrameDuration * 4.0)
                canBlendFromCurrentTexture = frameDelta > 0.0001 && frameDelta <= maxBlendGap
            }

            if canBlendFromCurrentTexture, let current = item.texture {
                item.previousVideoTexture = current
                item.previousVideoTextureRef = item.currentVideoTextureRef
                item.videoFrameTransitionStart = hostTime
            } else {
                item.previousVideoTexture = nil
                item.previousVideoTextureRef = nil
                item.videoFrameTransitionStart = hostTime
            }
            if let lastItemTime, itemTime.isFinite {
                let frameDelta = abs(itemTime - lastItemTime)
                if frameDelta > 0.0001 {
                    item.videoNominalFrameDuration = max(1.0 / 240.0, min(0.5, frameDelta))
                }
            }
            if let lastHostTime = item.videoLastHostTime {
                let hostDelta = hostTime - lastHostTime
                if hostDelta > 0.0001 {
                    item.videoObservedFrameInterval = max(1.0 / 240.0, min(1.0, hostDelta))
                }
            }
            item.videoLastItemTime = itemTime.isFinite ? itemTime : nil
            item.videoLastHostTime = hostTime
            item.currentVideoTextureRef = cvTexture
            item.texture = texture
        }
    }

    private func logVideoBufferFormatIfNeeded(_ pixelBuffer: CVPixelBuffer, for item: CollageItem) {
        guard !item.didLogVideoBufferFormat else { return }
        item.didLogVideoBufferFormat = true
        let pixelFormat = fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
        let transfer = attachmentDescription(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
        let primaries = attachmentDescription(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
        let matrix = attachmentDescription(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
        let contentLight = attachmentDescription(pixelBuffer, key: kCVImageBufferContentLightLevelInfoKey)
        NSLog("Video output \(item.name): pixelFormat=\(pixelFormat) primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) contentLight=\(contentLight)")
    }

    private func attachmentDescription(_ pixelBuffer: CVPixelBuffer, key: CFString) -> String {
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil) else { return "nil" }
        return String(describing: value)
    }

    private func fourCC(_ value: OSType) -> String {
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if scalars.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return String(bytes: scalars, encoding: .macOSRoman) ?? "\(value)"
        }
        return "\(value)"
    }

    private func drawTexture(_ texture: MTLTexture, for item: CollageItem, in rect: CGRect, viewport: CGSize, drawableSize: CGSize, encoder: MTLRenderCommandEncoder) {
        let texRect = sourceRect(for: item, targetAspect: rect.width / max(1, rect.height))
        let mode = MetalQualityMode(rawValue: item.qualityModeRaw) ?? qualityMode
        let outputPixels = CGSize(
            width: max(1, rect.width / max(1, viewport.width) * drawableSize.width),
            height: max(1, rect.height / max(1, viewport.height) * drawableSize.height)
        )
        let sourcePixels = CGSize(
            width: max(1, texRect.width * item.pixelSize.width),
            height: max(1, texRect.height * item.pixelSize.height)
        )
        let isMinifying = sourcePixels.width > outputPixels.width * 1.05 || sourcePixels.height > outputPixels.height * 1.05
        let temporal = temporalBlend(for: item)
        var uniforms = MetalFragmentUniforms(
            samplingMode: mode.shaderSamplingMode(isMinifying: isMinifying),
            hasPreviousTexture: temporal.hasPrevious ? 1 : 0,
            splitCompare: splitCompareEnabled ? (splitCompareReversed ? 2 : 1) : 0,
            viewportWidth: Float(max(1, drawableSize.width)),
            temporalBlend: temporal.blend,
            denoiseStrength: item.naturalDenoiseEnabled ? item.naturalDenoiseStrength : 0,
            toneStrength: item.toneRecoveryEnabled ? item.toneRecoveryStrength : 0,
            magicStrength: item.magicRescueEnabled ? item.magicRescueStrength : 0,
            brightnessBoost: item.brightnessBoost,
            temporalGuard: item.dynamicRange.usesEDR ? 1 : 0
        )

        let minX = Float(rect.minX / viewport.width * 2 - 1)
        let maxX = Float(rect.maxX / viewport.width * 2 - 1)
        let minY = Float(rect.minY / viewport.height * 2 - 1)
        let maxY = Float(rect.maxY / viewport.height * 2 - 1)

        let u0 = Float(texRect.minX)
        let u1 = Float(texRect.maxX)
        let v0 = Float(texRect.minY)
        let v1 = Float(texRect.maxY)
        let sourceTopLeft = textureCoordinate(for: item, u: u0, v: v0)
        let sourceTopRight = textureCoordinate(for: item, u: u1, v: v0)
        let sourceBottomLeft = textureCoordinate(for: item, u: u0, v: v1)
        let sourceBottomRight = textureCoordinate(for: item, u: u1, v: v1)
        let uv = rotatedTextureCorners(
            for: item,
            sourceTopLeft: sourceTopLeft,
            sourceTopRight: sourceTopRight,
            sourceBottomLeft: sourceBottomLeft,
            sourceBottomRight: sourceBottomRight
        )

        var vertices = [
            MetalVertex(position: SIMD2(minX, minY), texCoord: uv.bottomLeft),
            MetalVertex(position: SIMD2(maxX, minY), texCoord: uv.bottomRight),
            MetalVertex(position: SIMD2(minX, maxY), texCoord: uv.topLeft),
            MetalVertex(position: SIMD2(maxX, minY), texCoord: uv.bottomRight),
            MetalVertex(position: SIMD2(maxX, maxY), texCoord: uv.topRight),
            MetalVertex(position: SIMD2(minX, maxY), texCoord: uv.topLeft)
        ]

        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(temporal.previousTexture ?? texture, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalFragmentUniforms>.stride, index: 0)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<MetalVertex>.stride * vertices.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func textureCoordinate(for item: CollageItem, u: Float, v: Float) -> SIMD2<Float> {
        guard let mapping = item.videoTextureMapping else {
            return SIMD2(u, v)
        }
        return mapping.textureCoordinate(displayUV: SIMD2(u, v))
    }

    private func rotatedTextureCorners(
        for item: CollageItem,
        sourceTopLeft: SIMD2<Float>,
        sourceTopRight: SIMD2<Float>,
        sourceBottomLeft: SIMD2<Float>,
        sourceBottomRight: SIMD2<Float>
    ) -> (topLeft: SIMD2<Float>, topRight: SIMD2<Float>, bottomLeft: SIMD2<Float>, bottomRight: SIMD2<Float>) {
        switch item.normalizedRotationQuarterTurns {
        case 1:
            return (
                topLeft: sourceBottomLeft,
                topRight: sourceTopLeft,
                bottomLeft: sourceBottomRight,
                bottomRight: sourceTopRight
            )
        case 2:
            return (
                topLeft: sourceBottomRight,
                topRight: sourceBottomLeft,
                bottomLeft: sourceTopRight,
                bottomRight: sourceTopLeft
            )
        case 3:
            return (
                topLeft: sourceTopRight,
                topRight: sourceBottomRight,
                bottomLeft: sourceTopLeft,
                bottomRight: sourceBottomLeft
            )
        default:
            return (
                topLeft: sourceTopLeft,
                topRight: sourceTopRight,
                bottomLeft: sourceBottomLeft,
                bottomRight: sourceBottomRight
            )
        }
    }

    private func temporalBlend(for item: CollageItem) -> (hasPrevious: Bool, previousTexture: MTLTexture?, blend: Float) {
        guard item.kind == .video,
              item.frameInterpolationEnabled,
              item.speed < 0.999,
              let previousTexture = item.previousVideoTexture else {
            return (false, nil, 1)
        }

        let now = CACurrentMediaTime()
        let speed = max(0.05, TimeInterval(item.speed))
        let expectedInterval = item.videoNominalFrameDuration / speed
        let frameInterval = max(expectedInterval, item.videoObservedFrameInterval)
        let transitionScale: TimeInterval = item.dynamicRange.usesEDR ? 0.42 : 0.56
        let maxTransition: TimeInterval = item.dynamicRange.usesEDR ? 0.12 : 0.18
        let transitionDuration = max(1.0 / 120.0, min(maxTransition, frameInterval * transitionScale))
        let blend = max(0, min(1, (now - item.videoFrameTransitionStart) / transitionDuration))
        if blend >= 0.999 {
            item.previousVideoTexture = nil
            item.previousVideoTextureRef = nil
            return (false, nil, 1)
        }
        return (true, previousTexture, Float(blend))
    }

    private func sourceRect(for item: CollageItem, targetAspect: CGFloat) -> CGRect {
        let base = item.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let sourceTargetAspect = item.sourceAspect(forDisplayAspect: targetAspect)
        let sourceAspect = (base.width * item.pixelSize.width) / max(1, base.height * item.pixelSize.height)
        var width = base.width
        var height = base.height

        if sourceAspect > sourceTargetAspect {
            width = base.height * sourceTargetAspect * item.pixelSize.height / max(1, item.pixelSize.width)
        } else {
            height = base.width * item.pixelSize.width / max(1, sourceTargetAspect * item.pixelSize.height)
        }

        let zoom = max(1, min(6, item.zoom))
        width /= zoom
        height /= zoom

        let maxOffsetX = max(0, (base.width - width) / 2)
        let maxOffsetY = max(0, (base.height - height) / 2)
        let centerX = min(base.maxX - width / 2, max(base.minX + width / 2, base.midX + item.pan.x * maxOffsetX))
        let centerY = min(base.maxY - height / 2, max(base.minY + height / 2, base.midY + item.pan.y * maxOffsetY))

        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
}
