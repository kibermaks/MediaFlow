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

enum FlowSettingsStore {
    private static let maxVisibleKey = "flowMaxVisibleItems"
    private static let rotationModeKey = "flowRotationModeRaw"
    private static let allowRandomDuplicatesKey = "flowAllowRandomDuplicates"
    private static let autoRotateKey = "flowAutoRotateEnabled"
    private static let rotationIntervalKey = "flowRotationInterval"

    static var maxVisibleItems: Int {
        get {
            guard UserDefaults.standard.object(forKey: maxVisibleKey) != nil else { return 6 }
            return max(1, min(64, UserDefaults.standard.integer(forKey: maxVisibleKey)))
        }
        set {
            UserDefaults.standard.set(max(1, min(64, newValue)), forKey: maxVisibleKey)
        }
    }

    static var rotationMode: FlowRotationMode {
        get {
            let raw = UserDefaults.standard.integer(forKey: rotationModeKey)
            return FlowRotationMode(rawValue: raw) ?? .roundRobin
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: rotationModeKey)
        }
    }

    static var allowsRandomDuplicates: Bool {
        get { UserDefaults.standard.bool(forKey: allowRandomDuplicatesKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowRandomDuplicatesKey) }
    }

    static var autoRotateEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: autoRotateKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: autoRotateKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoRotateKey)
        }
    }

    static var rotationInterval: TimeInterval {
        get {
            guard UserDefaults.standard.object(forKey: rotationIntervalKey) != nil else { return 20 }
            return max(4, min(600, UserDefaults.standard.double(forKey: rotationIntervalKey)))
        }
        set {
            UserDefaults.standard.set(max(4, min(600, newValue)), forKey: rotationIntervalKey)
        }
    }
}

enum RecentPlaybacksStore {
    private static let key = "recentPlaybackPaths"
    private static let limit = 12

    static func urls() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit {
            paths = Array(paths.prefix(limit))
        }
        UserDefaults.standard.set(paths, forKey: key)
        NotificationCenter.default.post(name: .recentPlaybacksChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .recentPlaybacksChanged, object: nil)
    }
}

enum LastPlaybackStore {
    private static let legacySupportDirectoryName = "Image Viewer"

    static var url: URL {
        supportURL(directoryName: AppMetadata.supportDirectoryName)
            .appendingPathComponent("LastPlayback.ivplayback")
    }

    static var legacyURL: URL {
        supportURL(directoryName: legacySupportDirectoryName)
            .appendingPathComponent("LastPlayback.ivplayback")
    }

    static var existingURL: URL? {
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return nil
    }

    private static func supportURL(directoryName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func deleteExisting() throws -> Bool {
        var deleted = false
        for candidate in [url, legacyURL] where FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
            deleted = true
        }
        return deleted
    }
}

@MainActor enum WindowFrameStore {
    private static let key = "mainWindowFrame"

    static func restore(_ window: NSWindow) -> Bool {
        guard let frameString = UserDefaults.standard.string(forKey: key) else { return false }
        let frame = NSRectFromString(frameString)
        guard frame.width >= 520, frame.height >= 360, frame.width.isFinite, frame.height.isFinite else { return false }
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let visible = screens.first(where: { $0.intersects(frame) }) ?? NSScreen.main?.visibleFrame else { return false }
        let width = min(max(520, frame.width), visible.width)
        let height = min(max(360, frame.height), visible.height)
        let x = max(visible.minX, min(visible.maxX - width, frame.minX))
        let y = max(visible.minY, min(visible.maxY - height, frame.minY))
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: false)
        return true
    }

    static func save(_ window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }
}
