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

@MainActor final class FlowThumbnailCache {
    private var images: [String: NSImage] = [:]
    private var requested = Set<String>()

    func thumbnail(for item: CollageItem, redraw: @escaping @MainActor @Sendable () -> Void) -> NSImage? {
        let key = item.url.path
        if let cached = images[key] { return cached }
        guard requested.insert(key).inserted else { return nil }

        let url = item.url
        let kind = item.kind
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.generateThumbnail(url: url, kind: kind)
            Task { @MainActor [weak self] in
                if let image {
                    self?.images[key] = image
                }
                redraw()
            }
        }
        return nil
    }

    nonisolated private static func generateThumbnail(url: URL, kind: MediaKind) -> NSImage? {
        let image: NSImage?
        switch kind {
        case .image:
            image = NSImage(contentsOf: url)
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            do {
                let cgImage = try generator.copyCGImage(at: CMTime(seconds: 0.12, preferredTimescale: 600), actualTime: nil)
                image = NSImage(cgImage: cgImage, size: .zero)
            } catch {
                image = nil
            }
        }
        return image
    }
}
