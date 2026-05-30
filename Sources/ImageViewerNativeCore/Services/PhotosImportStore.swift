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

enum PhotosImportStore {
    private final class ImportedURLAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        func snapshot() -> [URL] {
            lock.lock()
            let result = urls
            lock.unlock()
            return result
        }
    }

    private final class SendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private static var importsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppMetadata.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Photos Imports", isDirectory: true)
    }

    @MainActor static func importAssets(_ assets: [PHAsset], completion: @escaping @MainActor ([URL]) -> Void) {
        guard !assets.isEmpty else {
            completion([])
            return
        }

        do {
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Photos import directory failed: \(error)")
            completion([])
            return
        }

        let group = DispatchGroup()
        let importedURLs = ImportedURLAccumulator()

        for asset in assets {
            group.enter()
            switch asset.mediaType {
            case .image:
                importImage(asset) { url in
                    if let url {
                        importedURLs.append(url)
                    }
                    group.leave()
                }
            case .video:
                importVideo(asset) { url in
                    if let url {
                        importedURLs.append(url)
                    }
                    group.leave()
                }
            default:
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let result = importedURLs.snapshot()
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private static func importImage(_ asset: PHAsset, completion: @escaping @Sendable (URL?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
            guard let data else {
                completion(nil)
                return
            }
            let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
            let destination = destinationURL(for: asset, fileExtension: ext)
            do {
                try data.write(to: destination, options: .atomic)
                completion(destination)
            } catch {
                NSLog("Photos image import failed: \(error)")
                completion(nil)
            }
        }
    }

    private static func importVideo(_ asset: PHAsset, completion: @escaping @Sendable (URL?) -> Void) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            guard let avAsset else {
                completion(nil)
                return
            }

            let destination = destinationURL(for: asset, fileExtension: "mov")
            if let urlAsset = avAsset as? AVURLAsset {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: urlAsset.url, to: destination)
                    completion(destination)
                } catch {
                    NSLog("Photos video copy failed: \(error)")
                    completion(nil)
                }
                return
            }

            let assetBox = SendableBox(avAsset)
            Task {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    let export = AVAssetExportSession(asset: assetBox.value, presetName: AVAssetExportPresetPassthrough)
                        ?? AVAssetExportSession(asset: assetBox.value, presetName: AVAssetExportPresetHighestQuality)
                    guard let export else {
                        completion(nil)
                        return
                    }
                    try await export.export(to: destination, as: .mov)
                    completion(destination)
                } catch {
                    NSLog("Photos video export failed: \(error)")
                    completion(nil)
                }
            }
        }
    }

    private static func destinationURL(for asset: PHAsset, fileExtension ext: String) -> URL {
        let safeID = asset.localIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let timestamp = Int(Date().timeIntervalSince1970)
        return importsDirectory.appendingPathComponent("\(safeID)-\(timestamp).\(ext)")
    }
}
