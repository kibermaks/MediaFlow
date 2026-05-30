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

enum AppMetadata {
    static let name = "MediaFlow"
    static let supportDirectoryName = "MediaFlow"
    static let tagline = "Fullscreen live media walls for local photos and videos"
    static let playbackFileExtension = "ivplayback"
    static let playbackContentTypeIdentifier = "com.kibermaks.mediaflow.playback"
    static let playbackContentType = UTType(exportedAs: playbackContentTypeIdentifier, conformingTo: .data)
    static var playbackPanelContentType: UTType {
        UTType(filenameExtension: playbackFileExtension) ?? playbackContentType
    }
    static let authorName = "kibermaks"
    static let repositoryOwner = "kibermaks"
    static let repositoryName = "MediaFlow"
    static let authorURL = URL(string: "https://github.com/kibermaks")!
    static let repositoryURL = URL(string: "https://github.com/kibermaks/MediaFlow")!
    static let licenseName = "MIT License"
    static let lastUpdateCheckDefaultsKey = "MediaFlow.LastUpdateCheckDate"
    static let changelogCacheDefaultsKey = "MediaFlow.CachedChangelog"

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var isPublicReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MediaFlowPublicRelease") as? Bool ?? false
    }

    static var worktreeName: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "MediaFlowWorktreeName") as? String else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var displayVersion: String {
        guard !isPublicReleaseBuild else { return shortVersion }
        var details = [buildNumber]
        if let worktreeName {
            details.append(worktreeName)
        }
        return "\(shortVersion) (\(details.joined(separator: " - ")))"
    }
}

enum MediaKind {
    case image
    case video
}

enum MediaDynamicRange: Int {
    case standard
    case wide
    case adaptiveHDR
    case hlg
    case pq

    var usesEDR: Bool {
        switch self {
        case .standard, .wide:
            return false
        case .adaptiveHDR, .hlg, .pq:
            return true
        }
    }

    var priority: Int {
        switch self {
        case .standard:
            return 0
        case .wide:
            return 1
        case .adaptiveHDR:
            return 2
        case .pq:
            return 3
        case .hlg:
            return 4
        }
    }
}

extension Notification.Name {
    static let recentPlaybacksChanged = Notification.Name("RecentPlaybacksChanged")
    static let metalQualityModeChanged = Notification.Name("MetalQualityModeChanged")
    static let qualitySettingsChanged = Notification.Name("QualitySettingsChanged")
    static let flowLibraryChanged = Notification.Name("FlowLibraryChanged")
    static let flowSettingsChanged = Notification.Name("FlowSettingsChanged")
}

enum FlowRotationMode: Int, Codable, CaseIterable {
    case roundRobin
    case random

    var displayName: String {
        switch self {
        case .roundRobin:
            return "Round Robin"
        case .random:
            return "Random"
        }
    }
}
