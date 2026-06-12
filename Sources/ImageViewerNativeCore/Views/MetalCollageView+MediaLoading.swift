import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
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

private struct LoadedVideoMetadata: @unchecked Sendable {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let formatDescriptions: [CMFormatDescription]
}

private final class VideoMetadataResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LoadedVideoMetadata?, Error>?

    func complete(_ result: Result<LoadedVideoMetadata?, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func snapshot() -> Result<LoadedVideoMetadata?, Error>? {
        lock.lock()
        let result = result
        lock.unlock()
        return result
    }
}

extension MetalCollageView {
    func addMediaURLs(_ urls: [URL]) {
        loadMedia(urls: urls)
    }

    func loadMedia(urls: [URL]) {
        let previousCount = items.count
        for url in urls {
            if let item = loadImage(url: url) ?? loadVideo(url: url) {
                prepareLoadedItem(item, restoreABHistory: true)
                items.append(item)
            }
        }
        guard items.count != previousCount else { return }
        if !items.isEmpty {
            items.forEach { $0.selected = false }
            items.last?.selected = true
        }
        isPaused = !items.contains { $0.kind == .video }
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        resetFlowSelection()
        tickVideoUI()
    }

    func prepareLoadedItem(_ item: CollageItem, restoreABHistory: Bool) {
        ensureFileHash(for: item)
        let appliedProfile = QualityProfileStore.applyProfile(for: item)
        if appliedProfile {
            applyLoadedColorOutputProfile(to: item)
        }
        if restoreABHistory {
            _ = restoreSavedABHistory(for: item, seekToFirst: false, refreshUI: false)
        }
    }

    func applyLoadedColorOutputProfile(to item: CollageItem) {
        let canvasColorMode = canvasColorMode(adding: item.dynamicRange)
        switch item.kind {
        case .image:
            reloadImageTexture(for: item, canvasColorMode: canvasColorMode)
        case .video:
            refreshVideoOutput(for: item, canvasColorMode: canvasColorMode)
        }
    }

    func ensureFileHash(for item: CollageItem) {
        guard item.fileHash == nil else {
            if let hash = item.fileHash {
                item.hasSavedABHistory = ABHistoryStore.hasHistory(forHash: hash)
            }
            return
        }
        item.fileHash = ABHistoryStore.fileHash(for: item.url)
        if let hash = item.fileHash {
            item.hasSavedABHistory = ABHistoryStore.hasHistory(forHash: hash)
        }
    }

    func loadImage(url: URL) -> CollageItem? {
        let colorOutputModeRaw = ColorOutputStore.modeRaw
        if let rendered = renderImageTexture(url: url, colorOutputModeRaw: colorOutputModeRaw, canvasColorMode: nil) {
            let item = CollageItem(url: url, kind: .image, pixelSize: rendered.pixelSize, texture: rendered.texture)
            item.dynamicRange = rendered.dynamicRange
            item.colorOutputModeRaw = colorOutputModeRaw
            item.renderedColorOutputModeRaw = colorOutputModeRaw
            item.renderedCanvasColorModeRaw = rendered.canvasColorMode.rawValue
            return item
        }

        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        do {
            let texture = try textureLoader.newTexture(cgImage: cgImage, options: [
                MTKTextureLoader.Option.SRGB: false,
                MTKTextureLoader.Option.origin: MTKTextureLoader.Origin.topLeft,
                MTKTextureLoader.Option.generateMipmaps: true
            ])
            let item = CollageItem(url: url, kind: .image, pixelSize: CGSize(width: cgImage.width, height: cgImage.height), texture: texture)
            item.dynamicRange = imageDynamicRange(source: source, ciImage: nil)
            item.renderedColorOutputModeRaw = colorOutputModeRaw
            item.renderedCanvasColorModeRaw = CanvasColorMode.displayP3.rawValue
            return item
        } catch {
            NSLog("Image texture failed for \(url.path): \(error)")
            return nil
        }
    }

    func reloadImageTexture(for item: CollageItem) {
        reloadImageTexture(for: item, canvasColorMode: currentCanvasColorMode())
    }

    func reloadImageTexture(for item: CollageItem, canvasColorMode: CanvasColorMode) {
        guard item.kind == .image,
              let rendered = renderImageTexture(
                url: item.url,
                colorOutputModeRaw: item.colorOutputModeRaw,
                canvasColorMode: canvasColorMode
              ) else { return }
        item.texture = rendered.texture
        item.dynamicRange = rendered.dynamicRange
        item.renderedColorOutputModeRaw = item.colorOutputModeRaw
        item.renderedCanvasColorModeRaw = rendered.canvasColorMode.rawValue
        needsDisplay = true
    }

    func renderImageTexture(
        url: URL,
        colorOutputModeRaw: Int,
        canvasColorMode preferredCanvasColorMode: CanvasColorMode?
    ) -> (texture: MTLTexture, pixelSize: CGSize, dynamicRange: MediaDynamicRange, canvasColorMode: CanvasColorMode)? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard let ciImage = hdrAwareCIImage(contentsOf: url) else { return nil }
        let dynamicRange = imageDynamicRange(source: source, ciImage: ciImage)
        let canvasColorMode = preferredCanvasColorMode ?? canvasColorMode(adding: dynamicRange)
        let displayImage = displayMappedImage(ciImage, dynamicRange: dynamicRange)
        let renderColorSpace = imageRenderColorSpace(
            for: dynamicRange,
            colorOutputModeRaw: colorOutputModeRaw,
            canvasColorMode: canvasColorMode
        )
        let extent = ciImage.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let width = max(1, Int(ceil(extent.width)))
        let height = max(1, Int(ceil(extent.height)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device?.makeTexture(descriptor: descriptor) else { return nil }

        let normalized = displayImage.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        // Keep EXIF orientation, then write rows in the top-left texture space used by the renderer.
        let metalOriented = normalized.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        imageContext.render(
            metalOriented,
            to: texture,
            commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            colorSpace: renderColorSpace
        )
        generateMipmaps(for: texture)
        return (texture, CGSize(width: width, height: height), dynamicRange, canvasColorMode)
    }

    func displayMappedImage(_ image: CIImage, dynamicRange: MediaDynamicRange) -> CIImage {
        guard dynamicRange.usesEDR else { return image }
        if #available(macOS 15.0, *) {
            let targetHeadroom = displayTargetHeadroom()
            let sourceHeadroom = image.contentHeadroom
            let toneMap = CIFilter.toneMapHeadroom()
            toneMap.inputImage = image
            toneMap.targetHeadroom = targetHeadroom
            if sourceHeadroom > 1.01 {
                toneMap.sourceHeadroom = sourceHeadroom
            }
            return toneMap.outputImage ?? image
        }
        return image
    }

    func imageRenderColorSpace(
        for dynamicRange: MediaDynamicRange,
        colorOutputModeRaw: Int,
        canvasColorMode: CanvasColorMode
    ) -> CGColorSpace {
        switch ColorOutputMode(rawValue: colorOutputModeRaw) ?? .auto {
        case .auto:
            return colorSpace(for: canvasColorMode)
        case .unmanaged:
            return colorSpace(for: dynamicRange.canvasColorMode)
        case .sRGB:
            return mediaStandardColorSpace
        case .displayP3:
            return mediaDisplayColorSpace
        case .linearSRGB:
            return mediaLinearStandardColorSpace
        case .linearDisplayP3:
            return mediaWorkingColorSpace
        }
    }

    func currentCanvasColorMode() -> CanvasColorMode {
        let displayedItems = visibleSlots.isEmpty ? items : visibleSlots.map(\.item)
        return layerOutputMode(for: displayedItems).canvasColorMode
    }

    func canvasColorMode(adding dynamicRange: MediaDynamicRange) -> CanvasColorMode {
        let displayedItems = visibleSlots.isEmpty ? items : visibleSlots.map(\.item)
        let existingRange = displayedItems
            .map(\.dynamicRange)
            .max { $0.priority < $1.priority } ?? .standard
        return (dynamicRange.priority > existingRange.priority ? dynamicRange : existingRange).canvasColorMode
    }

    func syncVisibleMediaColorOutputs(for canvasColorMode: CanvasColorMode, items displayedItems: [CollageItem]) {
        for item in displayedItems {
            switch item.kind {
            case .image:
                guard item.renderedColorOutputModeRaw != item.colorOutputModeRaw ||
                      item.renderedCanvasColorModeRaw != canvasColorMode.rawValue else { continue }
                reloadImageTexture(for: item, canvasColorMode: canvasColorMode)
            case .video:
                guard item.videoOutputColorOutputModeRaw != item.colorOutputModeRaw ||
                      item.videoOutputCanvasColorModeRaw != canvasColorMode.rawValue else { continue }
                refreshVideoOutput(for: item, canvasColorMode: canvasColorMode)
            }
        }
    }

    func displayTargetHeadroom() -> Float {
        let screen = window?.screen ?? NSScreen.main
        let currentHeadroom = Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let potentialHeadroom = Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? CGFloat(currentHeadroom))
        return max(1, currentHeadroom, potentialHeadroom)
    }

    func hdrAwareCIImage(contentsOf url: URL) -> CIImage? {
        var options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ]
        if #available(macOS 14.0, *) {
            options[.expandToHDR] = true
        }
        guard var image = CIImage(contentsOf: url, options: options) else { return nil }

        if #available(macOS 15.0, *),
           image.contentHeadroom <= 1.01,
           let gainMap = CIImage(contentsOf: url, options: [
            .auxiliaryHDRGainMap: true,
            .applyOrientationProperty: true
           ]) {
            image = image.applyingGainMap(gainMap)
        }
        return image
    }

    func generateMipmaps(for texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1,
              let commandQueue = imageCommandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func imageDynamicRange(source: CGImageSource?, ciImage: CIImage?) -> MediaDynamicRange {
        var description = ""
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            if #available(macOS 15.0, *), let ciImage, ciImage.contentHeadroom > 1.01 {
                return .adaptiveHDR
            }
            return .standard
        }
        description = properties
            .map { "\(String(describing: $0.key))=\(String(describing: $0.value))" }
            .joined(separator: " ")
            .lowercased()
        if description.contains("hlg") || description.contains("arib") || description.contains("b67") {
            return .hlg
        }
        if description.contains("pq") || description.contains("2084") {
            return .pq
        }
        if #available(macOS 15.0, *), let ciImage, ciImage.contentHeadroom > 1.01 {
            return .adaptiveHDR
        }
        if imageHasHDRGainMap(source) {
            return .adaptiveHDR
        }
        if description.contains("display p3") || description.contains("display-p3") || description.contains("p3") || description.contains("2020") {
            return .wide
        }
        return .standard
    }

    func imageHasHDRGainMap(_ source: CGImageSource?) -> Bool {
        guard let source else { return false }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }
        if #available(macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }
        return false
    }

    func loadVideo(url: URL) -> CollageItem? {
        let metadata: LoadedVideoMetadata
        do {
            guard let loadedMetadata = try loadVideoMetadata(url: url) else { return nil }
            metadata = loadedMetadata
        } catch {
            NSLog("Video metadata failed for \(url.path): \(error)")
            return nil
        }

        let asset = AVURLAsset(url: url)
        let mapping = VideoTextureMapping.make(
            encodedSize: metadata.naturalSize,
            preferredTransform: metadata.preferredTransform
        )
        let size = mapping?.displayRect.size ?? metadata.naturalSize
        let dynamicRange = videoDynamicRange(formatDescriptions: metadata.formatDescriptions)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        let colorOutputModeRaw = ColorOutputStore.modeRaw
        let canvasColorMode = canvasColorMode(adding: dynamicRange)
        let outputSettings = Self.videoOutputSettings(
            for: dynamicRange,
            colorOutputModeRaw: colorOutputModeRaw,
            canvasColorMode: canvasColorMode
        )
        let output = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        output.suppressesPlayerRendering = true
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = false
        player.volume = 1
        player.actionAtItemEnd = .none
        let item = CollageItem(url: url, kind: .video, pixelSize: size.width > 0 ? size : CGSize(width: 16, height: 9), texture: nil)
        item.player = player
        item.videoOutput = output
        item.videoTextureMapping = mapping
        item.dynamicRange = dynamicRange
        item.colorOutputModeRaw = colorOutputModeRaw
        item.videoOutputColorOutputModeRaw = colorOutputModeRaw
        item.videoOutputCanvasColorModeRaw = canvasColorMode.rawValue
        item.muted = false
        item.volume = 1
        item.speed = 1
        if metadata.nominalFrameRate > 0 {
            item.videoNominalFrameDuration = 1.0 / TimeInterval(metadata.nominalFrameRate)
            item.videoObservedFrameInterval = item.videoNominalFrameDuration
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoItemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        player.play()
        return item
    }

    func refreshVideoOutput(for item: CollageItem) {
        refreshVideoOutput(for: item, canvasColorMode: currentCanvasColorMode())
    }

    func refreshVideoOutput(for item: CollageItem, canvasColorMode: CanvasColorMode) {
        guard item.kind == .video,
              let playerItem = item.player?.currentItem else { return }
        if let oldOutput = item.videoOutput {
            playerItem.remove(oldOutput)
        }
        let outputSettings = Self.videoOutputSettings(
            for: item.dynamicRange,
            colorOutputModeRaw: item.colorOutputModeRaw,
            canvasColorMode: canvasColorMode
        )
        let output = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        output.suppressesPlayerRendering = true
        playerItem.add(output)
        item.videoOutput = output
        item.videoOutputColorOutputModeRaw = item.colorOutputModeRaw
        item.videoOutputCanvasColorModeRaw = canvasColorMode.rawValue
        item.texture = nil
        item.currentVideoTextureRef = nil
        item.previousVideoTexture = nil
        item.previousVideoTextureRef = nil
        item.videoLastItemTime = nil
        item.videoLastHostTime = nil
        item.didLogVideoBufferFormat = false
        needsDisplay = true
    }

    nonisolated private static func videoOutputSettings(
        for dynamicRange: MediaDynamicRange,
        colorOutputModeRaw: Int,
        canvasColorMode: CanvasColorMode
    ) -> [String: any Sendable] {
        switch ColorOutputMode(rawValue: colorOutputModeRaw) ?? .auto {
        case .auto:
            return automaticVideoOutputSettings(for: dynamicRange, canvasColorMode: canvasColorMode)
        case .sRGB:
            return sdrVideoOutputSettings(
                primaries: AVVideoColorPrimaries_ITU_R_709_2,
                transfer: AVVideoTransferFunction_ITU_R_709_2,
                allowWideColor: false
            )
        case .displayP3:
            return sdrVideoOutputSettings(
                primaries: AVVideoColorPrimaries_P3_D65,
                transfer: AVVideoTransferFunction_ITU_R_709_2,
                allowWideColor: true
            )
        case .linearSRGB:
            return linearVideoOutputSettings(primaries: AVVideoColorPrimaries_ITU_R_709_2)
        case .linearDisplayP3:
            return linearVideoOutputSettings(primaries: AVVideoColorPrimaries_P3_D65)
        case .unmanaged:
            return rawVideoOutputSettings(for: dynamicRange)
        }
    }

    nonisolated private static func automaticVideoOutputSettings(
        for dynamicRange: MediaDynamicRange,
        canvasColorMode: CanvasColorMode
    ) -> [String: any Sendable] {
        guard canvasColorMode == .linearDisplayP3 else {
            return sdrVideoOutputSettings(
                primaries: AVVideoColorPrimaries_P3_D65,
                transfer: AVVideoTransferFunction_ITU_R_709_2,
                allowWideColor: true
            )
        }
        return linearVideoOutputSettings(primaries: AVVideoColorPrimaries_P3_D65)
    }

    nonisolated private static func rawVideoOutputSettings(for dynamicRange: MediaDynamicRange) -> [String: any Sendable] {
        guard dynamicRange.usesEDR else {
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        }
        return linearVideoOutputSettings(primaries: AVVideoColorPrimaries_P3_D65)
    }

    nonisolated private static func sdrVideoOutputSettings(
        primaries: String,
        transfer: String,
        allowWideColor: Bool
    ) -> [String: any Sendable] {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: allowWideColor,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ] as [String: any Sendable]
        ]
    }

    nonisolated private static func linearVideoOutputSettings(primaries: String) -> [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: true,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ] as [String: any Sendable]
        ]
    }

    private func loadVideoMetadata(url: URL) throws -> LoadedVideoMetadata? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = VideoMetadataResultBox()
        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    resultBox.complete(.success(nil))
                    return
                }

                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let nominalFrameRate = try await track.load(.nominalFrameRate)
                let formatDescriptions = try await track.load(.formatDescriptions)
                let metadata = LoadedVideoMetadata(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    nominalFrameRate: nominalFrameRate,
                    formatDescriptions: formatDescriptions
                )
                resultBox.complete(.success(metadata))
            } catch {
                resultBox.complete(.failure(error))
            }
        }
        semaphore.wait()
        return try resultBox.snapshot()?.get()
    }

    func videoDynamicRange(formatDescriptions: [CMFormatDescription]) -> MediaDynamicRange {
        var fallback: MediaDynamicRange = .standard
        for formatDescription in formatDescriptions {
            guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else { continue }
            let transfer = String(describing: extensions[kCMFormatDescriptionExtension_TransferFunction] ?? "").lowercased()
            let primaries = String(describing: extensions[kCMFormatDescriptionExtension_ColorPrimaries] ?? "").lowercased()
            let matrix = String(describing: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] ?? "").lowercased()
            let combined = "\(transfer) \(primaries) \(matrix)"
            if combined.contains("hlg") || combined.contains("arib") || combined.contains("b67") || combined.contains("2100") {
                return .hlg
            }
            if combined.contains("pq") || combined.contains("2084") {
                return .pq
            }
            if combined.contains("2020") || combined.contains("p3") {
                fallback = .wide
            }
        }
        return fallback
    }

    @objc func videoItemDidPlayToEnd(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let item = items.first(where: { $0.player?.currentItem === playerItem }) else { return }
        seekPlaybackPlayer(item, to: 0, resumeWhenDone: item.playWhenVisible)
    }

}
