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
import Security
import simd
import UniformTypeIdentifiers

private enum AppMetadata {
    static let name = "MediaFlow"
    static let supportDirectoryName = "MediaFlow"
    static let tagline = "Fullscreen live media walls for local photos and videos"
    static let authorName = "kibermaks"
    static let repositoryOwner = "kibermaks"
    static let repositoryName = "MediaFlow"
    static let authorURL = URL(string: "https://github.com/kibermaks")!
    static let repositoryURL = URL(string: "https://github.com/kibermaks/MediaFlow")!
    static let licenseName = "MIT License"
    static let lastUpdateCheckDefaultsKey = "MediaFlow.LastUpdateCheckDate"
    static let changelogCacheDefaultsKey = "MediaFlow.CachedChangelog"
}

private enum MediaKind {
    case image
    case video
}

private enum MediaDynamicRange: Int {
    case standard
    case wide
    case hlg
    case pq

    var usesEDR: Bool {
        switch self {
        case .standard, .wide:
            return false
        case .hlg, .pq:
            return true
        }
    }

    var priority: Int {
        switch self {
        case .standard:
            return 0
        case .wide:
            return 1
        case .pq:
            return 2
        case .hlg:
            return 3
        }
    }
}

private extension Notification.Name {
    static let recentPlaybacksChanged = Notification.Name("RecentPlaybacksChanged")
    static let metalQualityModeChanged = Notification.Name("MetalQualityModeChanged")
    static let qualitySettingsChanged = Notification.Name("QualitySettingsChanged")
    static let flowLibraryChanged = Notification.Name("FlowLibraryChanged")
    static let flowSettingsChanged = Notification.Name("FlowSettingsChanged")
}

private enum FlowRotationMode: Int, Codable, CaseIterable {
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

private enum FlowSettingsStore {
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

private enum RecentPlaybacksStore {
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

private enum LastPlaybackStore {
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

@MainActor private enum WindowFrameStore {
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

private enum FrameInterpolationStore {
    private static let key = "frameInterpolationEnabled"

    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

private enum NaturalDenoiseStore {
    private static let key = "naturalDenoiseEnabled"
    private static let strengthKey = "naturalDenoiseStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.72 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

private enum ToneRecoveryStore {
    private static let enabledKey = "toneRecoveryEnabled"
    private static let strengthKey = "toneRecoveryStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.58 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

private enum MagicRescueStore {
    private static let enabledKey = "magicRescueEnabled"
    private static let strengthKey = "magicRescueStrength"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var strength: Float {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return 0.82 }
            return max(0, min(1, UserDefaults.standard.float(forKey: strengthKey)))
        }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: strengthKey)
        }
    }
}

private enum SplitCompareStore {
    private static let key = "splitCompareEnabled"
    private static let reversedKey = "splitCompareReversed"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var reversed: Bool {
        get { UserDefaults.standard.bool(forKey: reversedKey) }
        set { UserDefaults.standard.set(newValue, forKey: reversedKey) }
    }
}

private enum DefaultQualityStore {
    private static let qualityModeKey = "defaultMetalQualityModeRaw"

    static var qualityModeRaw: Int {
        get {
            guard UserDefaults.standard.object(forKey: qualityModeKey) != nil else { return 0 }
            return UserDefaults.standard.integer(forKey: qualityModeKey)
        }
        set {
            UserDefaults.standard.set(max(0, min(4, newValue)), forKey: qualityModeKey)
        }
    }
}

private final class CollageItem: Equatable, @unchecked Sendable {
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

private struct FlowSlot {
    let item: CollageItem
    var cellRect: CGRect = .zero
    var contentRect: CGRect = .zero
}

private struct SavedPlayback: Codable {
    var items: [SavedItem]
    var flowSettings: SavedFlowSettings?
}

private struct SavedFlowSettings: Codable {
    var maxVisibleItems: Int
    var rotationMode: FlowRotationMode
    var allowsRandomDuplicates: Bool
    var autoRotateEnabled: Bool
    var rotationInterval: TimeInterval
}

private struct SavedItem: Codable {
    var path: String
    var weight: CGFloat
    var zoom: CGFloat
    var panX: CGFloat
    var panY: CGFloat
    var crop: CGRect?
    var speed: Float
    var volume: Float?
    var muted: Bool
    var currentTime: Double?
    var playing: Bool?
    var abLoops: [SavedLoop]
}

private struct SavedLoop: Codable, Equatable {
    var a: Double
    var b: Double
}

private struct SavedABLibrary: Codable {
    var entries: [String: SavedABEntry] = [:]
}

private struct SavedABEntry: Codable {
    var fileName: String
    var updatedAt: Date
    var histories: [SavedABSnapshot]
}

private struct SavedABSnapshot: Codable, Equatable {
    var createdAt: Date
    var loops: [SavedLoop]
}

private enum ABHistoryStore {
    private static let maxSnapshotsPerFile = 12

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppMetadata.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("ABHistory.json")
    }

    static func fileHash(for url: URL) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            NSLog("A-B history hash failed for \(url.path): \(error)")
            return nil
        }
    }

    static func hasHistory(forHash hash: String) -> Bool {
        guard let entry = readLibrary().entries[hash] else { return false }
        return entry.histories.contains { !$0.loops.isEmpty }
    }

    static func latestLoops(forHash hash: String) -> [(a: Double, b: Double)]? {
        guard let snapshot = readLibrary().entries[hash]?.histories.first(where: { !$0.loops.isEmpty }) else { return nil }
        let restored = snapshot.loops.map { loop in
            (a: loop.a, b: loop.b)
        }
        let valid = restored.filter { loop in
            loop.b - loop.a > 0.05
        }
        let loops = valid.sorted { lhs, rhs in
            lhs.a < rhs.a
        }
        return loops.isEmpty ? nil : loops
    }

    static func save(loops: [(a: Double, b: Double)], for item: CollageItem) {
        guard item.kind == .video, !loops.isEmpty else { return }
        let hash = item.fileHash ?? fileHash(for: item.url)
        guard let hash else { return }
        item.fileHash = hash

        let savedLoops = loops
            .map { SavedLoop(a: max(0, $0.a), b: max($0.a, $0.b)) }
            .filter { $0.b - $0.a > 0.05 }
            .sorted { $0.a < $1.a }
        guard !savedLoops.isEmpty else { return }

        var library = readLibrary()
        var entry = library.entries[hash] ?? SavedABEntry(fileName: item.name, updatedAt: Date(), histories: [])
        let snapshot = SavedABSnapshot(createdAt: Date(), loops: savedLoops)
        entry.histories.removeAll { $0.loops == savedLoops }
        entry.histories.insert(snapshot, at: 0)
        if entry.histories.count > maxSnapshotsPerFile {
            entry.histories = Array(entry.histories.prefix(maxSnapshotsPerFile))
        }
        entry.fileName = item.name
        entry.updatedAt = snapshot.createdAt
        library.entries[hash] = entry

        do {
            try writeLibrary(library)
            item.hasSavedABHistory = true
        } catch {
            NSLog("A-B history save failed: \(error)")
        }
    }

    static func clearHistory(for item: CollageItem) {
        guard item.kind == .video else { return }
        let hash = item.fileHash ?? fileHash(for: item.url)
        guard let hash else { return }
        var library = readLibrary()
        guard library.entries.removeValue(forKey: hash) != nil else { return }
        do {
            try writeLibrary(library)
            item.fileHash = hash
            item.hasSavedABHistory = false
        } catch {
            NSLog("A-B history clear failed: \(error)")
        }
    }

    static func clearAll() throws {
        try writeLibrary(SavedABLibrary())
    }

    private static func readLibrary() -> SavedABLibrary {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SavedABLibrary.self, from: data)
        } catch {
            return SavedABLibrary()
        }
    }

    private static func writeLibrary(_ library: SavedABLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
    }
}

private struct SavedQualityLibrary: Codable {
    var entries: [String: SavedQualityProfile] = [:]
}

private struct SavedQualityProfile: Codable {
    var fileName: String
    var updatedAt: Date
    var qualityModeRaw: Int
    var frameInterpolationEnabled: Bool
    var naturalDenoiseEnabled: Bool
    var naturalDenoiseStrength: Float
    var toneRecoveryEnabled: Bool
    var toneRecoveryStrength: Float
    var magicRescueEnabled: Bool
    var magicRescueStrength: Float
}

private enum QualityProfileStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppMetadata.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("QualityProfiles.json")
    }

    static func applyProfile(for item: CollageItem) -> Bool {
        guard let hash = item.fileHash, let profile = readLibrary().entries[hash] else { return false }
        item.qualityModeRaw = profile.qualityModeRaw
        item.frameInterpolationEnabled = profile.frameInterpolationEnabled
        item.naturalDenoiseEnabled = profile.naturalDenoiseEnabled
        item.naturalDenoiseStrength = max(0, min(1, profile.naturalDenoiseStrength))
        item.toneRecoveryEnabled = profile.toneRecoveryEnabled
        item.toneRecoveryStrength = max(0, min(1, profile.toneRecoveryStrength))
        item.magicRescueEnabled = profile.magicRescueEnabled
        item.magicRescueStrength = max(0, min(1, profile.magicRescueStrength))
        return true
    }

    static func saveProfile(for item: CollageItem) {
        guard let hash = item.fileHash else { return }
        var library = readLibrary()
        library.entries[hash] = SavedQualityProfile(
            fileName: item.name,
            updatedAt: Date(),
            qualityModeRaw: item.qualityModeRaw,
            frameInterpolationEnabled: item.frameInterpolationEnabled,
            naturalDenoiseEnabled: item.naturalDenoiseEnabled,
            naturalDenoiseStrength: max(0, min(1, item.naturalDenoiseStrength)),
            toneRecoveryEnabled: item.toneRecoveryEnabled,
            toneRecoveryStrength: max(0, min(1, item.toneRecoveryStrength)),
            magicRescueEnabled: item.magicRescueEnabled,
            magicRescueStrength: max(0, min(1, item.magicRescueStrength))
        )

        do {
            try writeLibrary(library)
        } catch {
            NSLog("Quality profile save failed: \(error)")
        }
    }

    static func clearAll() throws {
        try writeLibrary(SavedQualityLibrary())
    }

    private static func readLibrary() -> SavedQualityLibrary {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SavedQualityLibrary.self, from: data)
        } catch {
            return SavedQualityLibrary()
        }
    }

    private static func writeLibrary(_ library: SavedQualityLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try data.write(to: url, options: .atomic)
    }
}

private enum PlaybackCryptoError: LocalizedError {
    case invalidFile
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "This encrypted playback file is invalid."
        case .randomFailed:
            return "Could not generate secure random bytes for playback encryption."
        }
    }
}

private enum PlaybackCrypto {
    private static let magic = Data("IVPLAYBK1".utf8)
    private static let saltByteCount = 16
    // Keep the pre-rename HKDF info so older .ivplayback files remain readable.
    private static let info = Data("Image Viewer ivplayback v1".utf8)
    private static let embeddedSecret = Data([
        0x7d, 0x34, 0x09, 0xc8, 0x91, 0x52, 0xaf, 0x6e,
        0x20, 0xd7, 0x4b, 0xe3, 0x18, 0xa0, 0x65, 0xf9,
        0x43, 0xb2, 0x8c, 0x11, 0xfe, 0x5a, 0x76, 0xd0,
        0x9b, 0x27, 0xcc, 0x3f, 0x84, 0x6d, 0x01, 0xba
    ])

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encrypt(_ plaintext: Data) throws -> Data {
        let salt = try randomData(count: saltByteCount)
        let key = deriveKey(salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw PlaybackCryptoError.invalidFile }
        var output = Data()
        output.append(magic)
        output.append(salt)
        output.append(combined)
        return output
    }

    static func decrypt(_ data: Data) throws -> Data {
        guard data.starts(with: magic), data.count > magic.count + saltByteCount else {
            throw PlaybackCryptoError.invalidFile
        }
        let saltStart = magic.count
        let saltEnd = saltStart + saltByteCount
        let salt = data[saltStart..<saltEnd]
        let combined = data[saltEnd..<data.count]
        let key = deriveKey(salt: salt)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key)
    }

    private static func deriveKey(salt: some DataProtocol) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: embeddedSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PlaybackCryptoError.randomFailed }
        return Data(bytes)
    }
}

private struct MetalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct VideoTextureMapping {
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

private enum MetalQualityMode: Int, CaseIterable {
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

private struct MetalFragmentUniforms {
    var samplingMode: UInt32
    var hasPreviousTexture: UInt32
    var splitCompare: UInt32
    var viewportWidth: Float
    var temporalBlend: Float
    var denoiseStrength: Float
    var toneStrength: Float
    var magicStrength: Float
    var reserved: Float = 0
}

private final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var canvas: MetalCollageView?
    var qualityMode: MetalQualityMode = .best
    var frameInterpolationEnabled = FrameInterpolationStore.enabled
    var naturalDenoiseEnabled = NaturalDenoiseStore.enabled
    var naturalDenoiseStrength = NaturalDenoiseStore.strength
    var toneRecoveryEnabled = ToneRecoveryStore.enabled
    var toneRecoveryStrength = ToneRecoveryStore.strength
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

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct FragmentUniforms {
            uint samplingMode;
            uint hasPreviousTexture;
            uint splitCompare;
            float viewportWidth;
            float temporalBlend;
            float denoiseStrength;
            float toneStrength;
            float magicStrength;
            float reserved;
        };

        vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                     const device VertexIn *vertices [[buffer(0)]]) {
            VertexOut out;
            out.position = float4(vertices[vid].position, 0.0, 1.0);
            out.texCoord = vertices[vid].texCoord;
            return out;
        }

        half4 read_clamped(texture2d<half> tex, int2 coord) {
            int2 size = int2(tex.get_width(), tex.get_height());
            coord = clamp(coord, int2(0), size - int2(1));
            return tex.read(uint2(coord));
        }

        float cubic_weight(float x) {
            x = abs(x);
            if (x <= 1.0) {
                return ((1.5 * x - 2.5) * x * x) + 1.0;
            }
            if (x < 2.0) {
                return (((-0.5 * x + 2.5) * x - 4.0) * x) + 2.0;
            }
            return 0.0;
        }

        half4 sample_bicubic(texture2d<half> tex, float2 uv) {
            float2 size = float2(tex.get_width(), tex.get_height());
            float2 position = clamp(uv, float2(0.0), float2(1.0)) * size - 0.5;
            float2 baseFloat = floor(position);
            int2 base = int2(baseFloat);
            float2 fraction = position - baseFloat;

            float4 color = float4(0.0);
            float weightSum = 0.0;
            for (int y = -1; y <= 2; y++) {
                float wy = cubic_weight(float(y) - fraction.y);
                for (int x = -1; x <= 2; x++) {
                    float wx = cubic_weight(float(x) - fraction.x);
                    float weight = wx * wy;
                    color += float4(read_clamped(tex, base + int2(x, y))) * weight;
                    weightSum += weight;
                }
            }
            color /= max(weightSum, 0.0001);
            return half4(max(color, float4(0.0)));
        }

        float sinc_weight(float x) {
            x = abs(x);
            if (x < 0.0001) {
                return 1.0;
            }
            float px = x * 3.14159265358979323846;
            return sin(px) / px;
        }

        float lanczos2_weight(float x) {
            x = abs(x);
            if (x >= 2.0) {
                return 0.0;
            }
            return sinc_weight(x) * sinc_weight(x * 0.5);
        }

        half4 sample_lanczos2(texture2d<half> tex, float2 uv) {
            float2 size = float2(tex.get_width(), tex.get_height());
            float2 position = clamp(uv, float2(0.0), float2(1.0)) * size - 0.5;
            float2 baseFloat = floor(position);
            int2 base = int2(baseFloat);
            float2 fraction = position - baseFloat;

            float4 color = float4(0.0);
            float weightSum = 0.0;
            for (int y = -1; y <= 2; y++) {
                float wy = lanczos2_weight(float(y) - fraction.y);
                for (int x = -1; x <= 2; x++) {
                    float wx = lanczos2_weight(float(x) - fraction.x);
                    float weight = wx * wy;
                    color += float4(read_clamped(tex, base + int2(x, y))) * weight;
                    weightSum += weight;
                }
            }
            color /= max(weightSum, 0.0001);
            return half4(max(color, float4(0.0)));
        }

        half4 sample_mode(texture2d<half> tex,
                          float2 uv,
                          sampler linearSampler,
                          sampler nearestSampler,
                          uint samplingMode) {
            if (samplingMode == 1) {
                return tex.sample(nearestSampler, uv);
            }
            if (samplingMode == 2) {
                return sample_bicubic(tex, uv);
            }
            if (samplingMode == 3) {
                return sample_lanczos2(tex, uv);
            }
            return tex.sample(linearSampler, uv);
        }

        float luminance(half3 color) {
            return dot(float3(color), float3(0.2126, 0.7152, 0.0722));
        }

        half4 natural_denoise(texture2d<half> tex,
                              half4 center,
                              float2 uv,
                              sampler linearSampler,
                              float strength) {
            if (strength <= 0.001) {
                return center;
            }

            float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
            float centerLuma = luminance(center.rgb);
            float4 weighted = float4(0.0);
            float totalWeight = 0.0;

            for (int y = -2; y <= 2; y++) {
                for (int x = -2; x <= 2; x++) {
                    float2 offset = float2(x, y);
                    half4 sampleColor = tex.sample(linearSampler, uv + offset * texel);
                    float sampleLuma = luminance(sampleColor.rgb);
                    float spatialWeight = exp(-dot(offset, offset) * 0.30);
                    float rangeDelta = sampleLuma - centerLuma;
                    float rangeWeight = exp(-(rangeDelta * rangeDelta) * 95.0);
                    float weight = spatialWeight * rangeWeight;
                    weighted += float4(sampleColor) * weight;
                    totalWeight += weight;
                }
            }

            half4 smooth = half4(weighted / max(totalWeight, 0.0001));
            float left = luminance(tex.sample(linearSampler, uv + float2(-1.0, 0.0) * texel).rgb);
            float right = luminance(tex.sample(linearSampler, uv + float2(1.0, 0.0) * texel).rgb);
            float down = luminance(tex.sample(linearSampler, uv + float2(0.0, -1.0) * texel).rgb);
            float up = luminance(tex.sample(linearSampler, uv + float2(0.0, 1.0) * texel).rgb);
            float edge = smoothstep(0.025, 0.18, max(abs(right - left), abs(up - down)));

            half3 detail = center.rgb - smooth.rgb;
            half detailKeep = half(mix(0.20, 0.86, edge));
            half3 restored = smooth.rgb + detail * detailKeep;
            half3 contrasted = max((restored - half3(0.5)) * half3(1.065) + half3(0.5), half3(0.0));
            restored = mix(restored, contrasted, half(0.24 * strength));

            half applyAmount = half(strength * mix(0.88, 0.36, edge));
            half3 rgb = mix(center.rgb, restored, applyAmount);
            return half4(max(rgb, half3(0.0)), center.a);
        }

        half4 tone_recovery(half4 color, float strength) {
            if (strength <= 0.001) {
                return color;
            }

            float3 rgb = float3(color.rgb);
            float peak = max(1.0, max(max(rgb.r, rgb.g), rgb.b));
            rgb /= peak;
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float shadowMask = 1.0 - smoothstep(0.06, 0.48, luma);
            float highlightMask = smoothstep(0.56, 0.98, luma);

            float shadowGamma = mix(1.0, 0.58, strength * shadowMask);
            float3 lifted = pow(max(rgb, float3(0.0)), float3(shadowGamma));

            float highlightGamma = mix(1.0, 0.70, strength * highlightMask);
            float3 compressed = 1.0 - pow(max(1.0 - lifted, float3(0.0)), float3(highlightGamma));

            float3 localContrast = max((compressed - 0.5) * (1.0 + 0.18 * strength) + 0.5, float3(0.0));
            float3 recovered = mix(compressed, localContrast, 0.34 * strength);
            return half4(half3(max(recovered * peak, float3(0.0))), color.a);
        }

        half4 magic_rescue(texture2d<half> tex,
                           half4 color,
                           float2 uv,
                           sampler linearSampler,
                           float strength) {
            if (strength <= 0.001) {
                return color;
            }

            float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
            float3 rgb = float3(color.rgb);
            float peak = max(1.0, max(max(rgb.r, rgb.g), rgb.b));
            rgb /= peak;
            float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float shadowMask = 1.0 - smoothstep(0.08, 0.52, luma);
            float highlightMask = smoothstep(0.58, 0.985, luma);

            float3 n1 = float3(tex.sample(linearSampler, uv + float2(-1.0, 0.0) * texel).rgb) / peak;
            float3 n2 = float3(tex.sample(linearSampler, uv + float2(1.0, 0.0) * texel).rgb) / peak;
            float3 n3 = float3(tex.sample(linearSampler, uv + float2(0.0, -1.0) * texel).rgb) / peak;
            float3 n4 = float3(tex.sample(linearSampler, uv + float2(0.0, 1.0) * texel).rgb) / peak;
            float3 d1 = float3(tex.sample(linearSampler, uv + float2(-2.0, -2.0) * texel).rgb) / peak;
            float3 d2 = float3(tex.sample(linearSampler, uv + float2(2.0, -2.0) * texel).rgb) / peak;
            float3 d3 = float3(tex.sample(linearSampler, uv + float2(-2.0, 2.0) * texel).rgb) / peak;
            float3 d4 = float3(tex.sample(linearSampler, uv + float2(2.0, 2.0) * texel).rgb) / peak;
            float3 localMean = (n1 + n2 + n3 + n4) * 0.18 + (d1 + d2 + d3 + d4) * 0.07;
            float3 highpass = rgb - localMean;

            float edge = smoothstep(0.035, 0.22, length(highpass));
            float detailGain = strength * (0.18 + 0.42 * shadowMask + 0.24 * highlightMask + 0.20 * edge);
            rgb += highpass * detailGain;

            float3 shadowLift = pow(max(rgb, float3(0.0)), float3(mix(1.0, 0.46, strength * shadowMask)));
            rgb = mix(rgb, shadowLift, min(0.92, strength * (0.50 + 0.34 * shadowMask)));

            float3 highlightRolloff = 1.0 - pow(max(1.0 - rgb, float3(0.0)), float3(mix(1.0, 0.54, strength * highlightMask)));
            rgb = mix(rgb, highlightRolloff, min(0.86, strength * highlightMask));

            float rescuedLuma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            float3 clarity = max((rgb - rescuedLuma) * (1.0 + 0.42 * strength) + rescuedLuma, float3(0.0));
            rgb = mix(rgb, clarity, 0.42 * strength);

            float sat = max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b);
            float vibrance = strength * (0.16 + 0.22 * (1.0 - sat));
            float gray = dot(rgb, float3(0.299, 0.587, 0.114));
            rgb = mix(float3(gray), rgb, 1.0 + vibrance);

            float3 filmic = rgb * (1.0 + 0.44 * strength);
            filmic = filmic / (filmic + float3(0.30 + 0.16 * (1.0 - strength)));
            rgb = mix(rgb, filmic, 0.34 * strength);

            return half4(half3(max(rgb * peak, float3(0.0))), color.a);
        }

        fragment half4 fragment_main(VertexOut in [[stage_in]],
                                     texture2d<half> tex [[texture(0)]],
                                     texture2d<half> previousTex [[texture(1)]],
                                     sampler linearSampler [[sampler(0)]],
                                     sampler nearestSampler [[sampler(1)]],
                                     constant FragmentUniforms &uniforms [[buffer(0)]]) {
            bool leftSide = in.position.x < uniforms.viewportWidth * 0.5;
            bool reversedCompare = uniforms.splitCompare == 2;
            bool rawSide = uniforms.splitCompare != 0 && (reversedCompare ? !leftSide : leftSide);
            uint samplingMode = rawSide ? 0 : uniforms.samplingMode;
            half4 color = sample_mode(tex, in.texCoord, linearSampler, nearestSampler, samplingMode);
            if (!rawSide && uniforms.hasPreviousTexture != 0) {
                half4 previous = sample_mode(previousTex, in.texCoord, linearSampler, nearestSampler, uniforms.samplingMode);
                color = mix(previous, color, half(clamp(uniforms.temporalBlend, 0.0, 1.0)));
            }
            if (!rawSide) {
                color = natural_denoise(tex, color, in.texCoord, linearSampler, uniforms.denoiseStrength);
                color = tone_recovery(color, uniforms.toneStrength);
                color = magic_rescue(tex, color, in.texCoord, linearSampler, uniforms.magicStrength);
            }
            if (uniforms.splitCompare != 0 && abs(in.position.x - uniforms.viewportWidth * 0.5) < 1.0) {
                color = half4(1.0, 1.0, 1.0, 1.0);
            }
            return color;
        }
        """

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
            if let current = item.texture {
                item.previousVideoTexture = current
                item.previousVideoTextureRef = item.currentVideoTextureRef
                item.videoFrameTransitionStart = hostTime
            }
            if let lastItemTime = item.videoLastItemTime, itemTime.isFinite {
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
            magicStrength: item.magicRescueEnabled ? item.magicRescueStrength : 0
        )

        let minX = Float(rect.minX / viewport.width * 2 - 1)
        let maxX = Float(rect.maxX / viewport.width * 2 - 1)
        let minY = Float(rect.minY / viewport.height * 2 - 1)
        let maxY = Float(rect.maxY / viewport.height * 2 - 1)

        let u0 = Float(texRect.minX)
        let u1 = Float(texRect.maxX)
        let v0 = Float(texRect.minY)
        let v1 = Float(texRect.maxY)
        let uvTopLeft = textureCoordinate(for: item, u: u0, v: v0)
        let uvTopRight = textureCoordinate(for: item, u: u1, v: v0)
        let uvBottomLeft = textureCoordinate(for: item, u: u0, v: v1)
        let uvBottomRight = textureCoordinate(for: item, u: u1, v: v1)

        var vertices = [
            MetalVertex(position: SIMD2(minX, minY), texCoord: uvBottomLeft),
            MetalVertex(position: SIMD2(maxX, minY), texCoord: uvBottomRight),
            MetalVertex(position: SIMD2(minX, maxY), texCoord: uvTopLeft),
            MetalVertex(position: SIMD2(maxX, minY), texCoord: uvBottomRight),
            MetalVertex(position: SIMD2(maxX, maxY), texCoord: uvTopRight),
            MetalVertex(position: SIMD2(minX, maxY), texCoord: uvTopLeft)
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

    private func temporalBlend(for item: CollageItem) -> (hasPrevious: Bool, previousTexture: MTLTexture?, blend: Float) {
        guard item.kind == .video,
              item.frameInterpolationEnabled,
              item.speed < 0.999,
              let previousTexture = item.previousVideoTexture else {
            return (false, nil, 1)
        }

        let now = CACurrentMediaTime()
        let expectedInterval = item.videoNominalFrameDuration / max(0.05, TimeInterval(item.speed))
        let frameInterval = max(expectedInterval, item.videoObservedFrameInterval)
        let transitionDuration = max(1.0 / 120.0, min(0.22, frameInterval * 0.72))
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
        let sourceAspect = (base.width * item.pixelSize.width) / max(1, base.height * item.pixelSize.height)
        var width = base.width
        var height = base.height

        if sourceAspect > targetAspect {
            width = base.height * targetAspect * item.pixelSize.height / max(1, item.pixelSize.width)
        } else {
            height = base.width * item.pixelSize.width / max(1, targetAspect * item.pixelSize.height)
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

private final class OverlayView: NSView {
    weak var canvas: MetalCollageView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }

        if canvas.items.isEmpty {
            drawEmptyState(in: bounds, isDragging: canvas.isDraggingMedia)
            return
        }

        if canvas.splitCompareEnabled {
            drawSplitCompareOverlay(in: bounds, reversed: canvas.splitCompareReversed)
        }

        for slot in canvas.visibleSlots where canvas.panItem === slot.item || (slot.item.selected && canvas.visibleSlots.count > 1) {
            let color = canvas.panItem === slot.item ? NSColor.systemOrange : NSColor.systemTeal
            color.setStroke()
            let path = NSBezierPath(roundedRect: slot.cellRect, xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            path.stroke()
        }

        for slot in canvas.visibleSlots where slot.item.kind == .video {
            drawVideoBadges(for: slot.item, in: slot.cellRect, solo: canvas.soloVideoItem === slot.item)
        }

        if let rect = canvas.activeCropRect {
            NSColor.systemTeal.withAlphaComponent(0.16).setFill()
            rect.fill()
            NSColor.systemTeal.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.setLineDash([7, 5], count: 2, phase: 0)
            path.stroke()
        }
    }

    private func drawSplitCompareOverlay(in rect: CGRect, reversed: Bool) {
        let dividerX = rect.midX
        NSColor.white.withAlphaComponent(0.76).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: dividerX, y: rect.minY))
        divider.line(to: CGPoint(x: dividerX, y: rect.maxY))
        divider.lineWidth = 1
        divider.stroke()

        let leftLabel = reversed ? "B QUALITY" : "A RAW"
        let rightLabel = reversed ? "A RAW" : "B QUALITY"
        drawPill(leftLabel, at: CGPoint(x: max(rect.minX + 58, dividerX - 62), y: rect.maxY - 30), color: reversed ? .systemTeal : .secondaryLabelColor)
        drawPill(rightLabel, at: CGPoint(x: min(rect.maxX - 72, dividerX + 78), y: rect.maxY - 30), color: reversed ? .secondaryLabelColor : .systemTeal)
    }

    private func drawPill(_ text: String, at center: CGPoint, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: center.x - textSize.width / 2 - 9, y: center.y - 8, width: textSize.width + 18, height: 17)
        NSColor.black.withAlphaComponent(0.56).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        color.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.8
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 4, dy: 2), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ])
    }

    private func drawVideoBadges(for item: CollageItem, in cellRect: CGRect, solo: Bool) {
        var labels: [(String, NSColor)] = []
        if !item.abLoops.isEmpty {
            labels.append(("A-B", .systemOrange))
        }
        if !item.isVideoPlaying {
            labels.append(("Pause", .secondaryLabelColor))
        }
        if solo {
            labels.append(("Solo", .systemTeal))
        }
        guard !labels.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let gap: CGFloat = 4
        var x = cellRect.maxX - 8
        let y = cellRect.maxY - 22

        for (label, color) in labels.reversed() {
            let textSize = (label as NSString).size(withAttributes: [.font: font])
            let badge = CGRect(x: x - textSize.width - 14, y: y, width: textSize.width + 14, height: 16)
            x = badge.minX - gap

            NSColor.black.withAlphaComponent(0.56).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            color.withAlphaComponent(0.88).setStroke()
            let border = NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7)
            border.lineWidth = 0.8
            border.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            label.draw(in: badge.insetBy(dx: 5, dy: 1.5), withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                .paragraphStyle: paragraph
            ])
        }
    }

    private func drawEmptyState(in rect: CGRect, isDragging: Bool) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.020, green: 0.023, blue: 0.027, alpha: 1),
            NSColor(calibratedRed: 0.040, green: 0.050, blue: 0.058, alpha: 1)
        ])?.draw(in: rect, angle: 90)

        let scale = max(0.78, min(1.0, min(rect.width / 980, rect.height / 720)))
        let panelWidth = min(rect.width - 48, max(420, 560 * scale))
        let panelHeight = max(250, 292 * scale)
        let panel = CGRect(
            x: rect.midX - panelWidth / 2,
            y: rect.midY - panelHeight / 2,
            width: panelWidth,
            height: panelHeight
        )

        let accent = isDragging ? NSColor.systemTeal : NSColor(calibratedRed: 0.38, green: 0.72, blue: 0.78, alpha: 1)
        let fill = NSColor.white.withAlphaComponent(isDragging ? 0.095 : 0.055)
        fill.setFill()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22)
        panelPath.fill()

        accent.withAlphaComponent(isDragging ? 0.80 : 0.36).setStroke()
        panelPath.lineWidth = isDragging ? 2.5 : 1.2
        if !isDragging {
            panelPath.setLineDash([8, 7], count: 2, phase: 0)
        }
        panelPath.stroke()

        drawEmptyGlyph(in: CGRect(x: panel.midX - 72 * scale, y: panel.maxY - 118 * scale, width: 144 * scale, height: 80 * scale), accent: accent, scale: scale)

        let title = isDragging ? "Release to Add" : "Drop Images or Videos"
        drawCentered(
            title,
            in: CGRect(x: panel.minX + 32, y: panel.midY - 8 * scale, width: panel.width - 64, height: 34),
            font: .systemFont(ofSize: 26 * scale, weight: .semibold),
            color: .white
        )

        drawCentered(
            "File -> Add Files (Cmd-O)  •  Quality Controls (Cmd-K)",
            in: CGRect(x: panel.minX + 34, y: panel.midY - 44 * scale, width: panel.width - 68, height: 22),
            font: .systemFont(ofSize: 13 * scale, weight: .medium),
            color: NSColor.white.withAlphaComponent(0.58)
        )

        drawCentered(
            "Load Playback (Cmd-L) and Recent Playbacks are in File",
            in: CGRect(x: panel.minX + 34, y: panel.midY - 72 * scale, width: panel.width - 68, height: 20),
            font: .systemFont(ofSize: 12 * scale, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.38)
        )
    }

    private func drawEmptyGlyph(in rect: CGRect, accent: NSColor, scale: CGFloat) {
        let tileSize = CGSize(width: 62 * scale, height: 46 * scale)
        let tiles: [(CGPoint, CGFloat, NSColor)] = [
            (CGPoint(x: rect.minX + 12 * scale, y: rect.minY + 18 * scale), -9, NSColor(calibratedRed: 0.07, green: 0.55, blue: 0.66, alpha: 1)),
            (CGPoint(x: rect.midX - tileSize.width / 2, y: rect.minY + 30 * scale), 0, NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.88, alpha: 1)),
            (CGPoint(x: rect.maxX - tileSize.width - 12 * scale, y: rect.minY + 18 * scale), 9, NSColor(calibratedRed: 0.12, green: 0.33, blue: 0.55, alpha: 1))
        ]

        for (origin, degrees, color) in tiles {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: origin.x + tileSize.width / 2, yBy: origin.y + tileSize.height / 2)
            transform.rotate(byDegrees: degrees)
            transform.translateX(by: -tileSize.width / 2, yBy: -tileSize.height / 2)
            transform.concat()

            let tile = CGRect(origin: .zero, size: tileSize)
            color.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 10 * scale, yRadius: 10 * scale).fill()
            NSColor.white.withAlphaComponent(0.36).setStroke()
            let stroke = NSBezierPath(roundedRect: tile, xRadius: 10 * scale, yRadius: 10 * scale)
            stroke.lineWidth = 1.2
            stroke.stroke()

            accent.withAlphaComponent(0.42).setStroke()
            let horizon = NSBezierPath()
            horizon.move(to: CGPoint(x: 10 * scale, y: 16 * scale))
            horizon.line(to: CGPoint(x: 26 * scale, y: 28 * scale))
            horizon.line(to: CGPoint(x: 38 * scale, y: 20 * scale))
            horizon.line(to: CGPoint(x: 52 * scale, y: 32 * scale))
            horizon.lineWidth = 2
            horizon.stroke()

            NSGraphicsContext.restoreGraphicsState()
        }

        let playRect = CGRect(x: rect.midX - 13 * scale, y: rect.minY - 1 * scale, width: 30 * scale, height: 30 * scale)
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: playRect.insetBy(dx: -7 * scale, dy: -7 * scale)).fill()
        NSColor.white.withAlphaComponent(0.88).setFill()
        let play = NSBezierPath()
        play.move(to: CGPoint(x: playRect.minX + 9 * scale, y: playRect.minY + 6 * scale))
        play.line(to: CGPoint(x: playRect.maxX - 6 * scale, y: playRect.midY))
        play.line(to: CGPoint(x: playRect.minX + 9 * scale, y: playRect.maxY - 6 * scale))
        play.close()
        play.fill()
    }

    private func drawCentered(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

private final class VideoTimelineView: NSView {
    weak var canvas: MetalCollageView?
    weak var item: CollageItem?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let duration = max(0.001, item.durationSeconds)
        let track = bounds.insetBy(dx: 8, dy: bounds.height * 0.34)

        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        for (index, loop) in item.abLoops.enumerated() {
            let x0 = track.minX + track.width * CGFloat(loop.a / duration)
            let x1 = track.minX + track.width * CGFloat(loop.b / duration)
            let rect = CGRect(x: min(x0, x1), y: track.minY, width: max(2, abs(x1 - x0)), height: track.height)
            NSColor.systemOrange.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            drawLoopLabels(index: index + 1, startX: min(x0, x1), endX: max(x0, x1), track: track)
        }

        if let a = item.pendingA {
            drawMarker("A", at: a, duration: duration, track: track, color: .systemTeal)
        }
        if let b = item.pendingB {
            drawMarker("B", at: b, duration: duration, track: track, color: .systemPink)
        }

        let progress = max(0, min(1, item.currentTimeSeconds / duration))
        let progressRect = CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(progress), height: track.height)
        FlowLibraryStyle.accent.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: progressRect, xRadius: 4, yRadius: 4).fill()

        let knobX = track.minX + track.width * CGFloat(progress)
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: CGRect(x: knobX - 5, y: track.midY - 5, width: 10, height: 10)).fill()
    }

    private func drawLoopLabels(index: Int, startX: CGFloat, endX: CGFloat, track: CGRect) {
        drawPin("A", x: startX, y: track.maxY + 2, color: .systemOrange)
        drawPin("B", x: endX, y: track.maxY + 2, color: .systemOrange)
        guard endX - startX > 38 else { return }
        let label = "\(index)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let rect = CGRect(x: (startX + endX) / 2 - 8, y: track.minY - 1.5, width: 16, height: track.height + 3)
        NSColor.black.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.draw(in: rect.insetBy(dx: 1, dy: 1), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph
        ])
    }

    private func drawMarker(_ label: String, at seconds: Double, duration: Double, track: CGRect, color: NSColor) {
        let x = track.minX + track.width * CGFloat(max(0, min(1, seconds / duration)))
        color.withAlphaComponent(0.9).setFill()
        CGRect(x: x - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        drawPin(label, x: x, y: track.maxY + 2, color: color)
    }

    private func drawPin(_ label: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let clampedX = max(bounds.minX + 8, min(bounds.maxX - 8, x))
        let rect = CGRect(x: clampedX - 8, y: min(bounds.maxY - 12, y), width: 16, height: 12)
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        color.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        border.lineWidth = 0.8
        border.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.draw(in: rect.insetBy(dx: 1, dy: 0.5), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }

    override func mouseDown(with event: NSEvent) {
        scrub(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(with: event)
    }

    private func scrub(with event: NSEvent) {
        guard let item, item.durationSeconds > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = bounds.insetBy(dx: 8, dy: bounds.height * 0.34)
        let pct = max(0, min(1, (point.x - track.minX) / max(1, track.width)))
        canvas?.suspendABLoop(for: item, seconds: 5)
        canvas?.resetVideoFrameHistory(for: item)
        item.player?.seek(to: CMTime(seconds: item.durationSeconds * Double(pct), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }
}

private final class MediaControlBarView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlPanelFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()

        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        border.lineWidth = 1
        border.stroke()
    }
}

private final class MetalCollageView: MTKView {
    var items: [CollageItem] = []
    var visibleSlots: [FlowSlot] = []
    var panItem: CollageItem?
    var activeCropRect: CGRect?
    var isDraggingMedia = false
    weak var soloVideoItem: CollageItem?

    private let textureLoader: MTKTextureLoader
    private let imageContext: CIContext
    private let imageCommandQueue: MTLCommandQueue?
    private let mediaWorkingColorSpace: CGColorSpace
    private let renderer: MetalRenderer
    private let overlay = OverlayView()
    private let toolPanel = NSVisualEffectView()
    private let toolStack = NSStackView()
    private let videoPanel = MediaControlBarView()
    private let videoStack = NSStackView()
    private let timelineView = VideoTimelineView()
    private let speedLabel = NSTextField(labelWithString: "1.00x")
    private let volumeLabel = NSTextField(labelWithString: "Vol 100%")
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let muteButton = NSButton(title: "", target: nil, action: nil)
    private let soloButton = NSButton(title: "", target: nil, action: nil)
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let restoreABButton = NSButton(title: "", target: nil, action: nil)
    private var uiTimer: Timer?
    private var flowTimer: Timer?
    private var flowVisibleIndexes: [Int] = []
    private var flowCursor = 0
    private var hoverItem: CollageItem?
    private var lastMousePoint: CGPoint?
    private var hoverToolPanelEnabled = false
    private var tracking: NSTrackingArea?
    private var isAddFilesPanelOpen = false

    private var cropMode = false
    private var cropStart: CGPoint?
    private weak var cropTarget: CollageItem?
    private var panDrag: (item: CollageItem, start: CGPoint, pan: CGPoint)?
    private weak var temporaryPanItem: CollageItem?
    private weak var pendingSelectionToggleItem: CollageItem?
    private var didPanDragItem = false
    private var dragStart: CGPoint?
    private weak var dragItem: CollageItem?
    private var didDragItem = false
    private var qualityEditsDefaults = false

    var flowMaxVisibleItems: Int = FlowSettingsStore.maxVisibleItems {
        didSet {
            flowMaxVisibleItems = max(1, min(64, flowMaxVisibleItems))
            guard oldValue != flowMaxVisibleItems else { return }
            FlowSettingsStore.maxVisibleItems = flowMaxVisibleItems
            resetFlowSelection()
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var flowRotationMode: FlowRotationMode = FlowSettingsStore.rotationMode {
        didSet {
            guard oldValue != flowRotationMode else { return }
            FlowSettingsStore.rotationMode = flowRotationMode
            resetFlowSelection()
            postFlowSettingsChanged()
        }
    }

    var flowAllowsRandomDuplicates: Bool = FlowSettingsStore.allowsRandomDuplicates {
        didSet {
            guard oldValue != flowAllowsRandomDuplicates else { return }
            FlowSettingsStore.allowsRandomDuplicates = flowAllowsRandomDuplicates
            resetFlowSelection()
            postFlowSettingsChanged()
        }
    }

    var flowAutoRotateEnabled: Bool = FlowSettingsStore.autoRotateEnabled {
        didSet {
            guard oldValue != flowAutoRotateEnabled else { return }
            FlowSettingsStore.autoRotateEnabled = flowAutoRotateEnabled
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var flowRotationInterval: TimeInterval = FlowSettingsStore.rotationInterval {
        didSet {
            flowRotationInterval = max(4, min(600, flowRotationInterval))
            guard oldValue != flowRotationInterval else { return }
            FlowSettingsStore.rotationInterval = flowRotationInterval
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var metalQualityMode: MetalQualityMode = MetalQualityMode(rawValue: DefaultQualityStore.qualityModeRaw) ?? .best {
        didSet {
            guard oldValue != metalQualityMode else { return }
            DefaultQualityStore.qualityModeRaw = metalQualityMode.rawValue
            renderer.qualityMode = metalQualityMode
            needsDisplay = true
            NotificationCenter.default.post(name: .metalQualityModeChanged, object: self)
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var frameInterpolationEnabled: Bool = FrameInterpolationStore.enabled {
        didSet {
            guard oldValue != frameInterpolationEnabled else { return }
            FrameInterpolationStore.enabled = frameInterpolationEnabled
            renderer.frameInterpolationEnabled = frameInterpolationEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var naturalDenoiseEnabled: Bool = NaturalDenoiseStore.enabled {
        didSet {
            guard oldValue != naturalDenoiseEnabled else { return }
            NaturalDenoiseStore.enabled = naturalDenoiseEnabled
            renderer.naturalDenoiseEnabled = naturalDenoiseEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var naturalDenoiseStrength: Float = NaturalDenoiseStore.strength {
        didSet {
            naturalDenoiseStrength = max(0, min(1, naturalDenoiseStrength))
            guard oldValue != naturalDenoiseStrength else { return }
            NaturalDenoiseStore.strength = naturalDenoiseStrength
            renderer.naturalDenoiseStrength = naturalDenoiseStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var toneRecoveryEnabled: Bool = ToneRecoveryStore.enabled {
        didSet {
            guard oldValue != toneRecoveryEnabled else { return }
            ToneRecoveryStore.enabled = toneRecoveryEnabled
            renderer.toneRecoveryEnabled = toneRecoveryEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var toneRecoveryStrength: Float = ToneRecoveryStore.strength {
        didSet {
            toneRecoveryStrength = max(0, min(1, toneRecoveryStrength))
            guard oldValue != toneRecoveryStrength else { return }
            ToneRecoveryStore.strength = toneRecoveryStrength
            renderer.toneRecoveryStrength = toneRecoveryStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var magicRescueEnabled: Bool = MagicRescueStore.enabled {
        didSet {
            guard oldValue != magicRescueEnabled else { return }
            MagicRescueStore.enabled = magicRescueEnabled
            renderer.magicRescueEnabled = magicRescueEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var magicRescueStrength: Float = MagicRescueStore.strength {
        didSet {
            magicRescueStrength = max(0, min(1, magicRescueStrength))
            guard oldValue != magicRescueStrength else { return }
            MagicRescueStore.strength = magicRescueStrength
            renderer.magicRescueStrength = magicRescueStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var splitCompareEnabled: Bool = SplitCompareStore.enabled {
        didSet {
            guard oldValue != splitCompareEnabled else { return }
            SplitCompareStore.enabled = splitCompareEnabled
            renderer.splitCompareEnabled = splitCompareEnabled
            needsDisplay = true
            overlay.needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var splitCompareReversed: Bool = SplitCompareStore.reversed {
        didSet {
            guard oldValue != splitCompareReversed else { return }
            SplitCompareStore.reversed = splitCompareReversed
            renderer.splitCompareReversed = splitCompareReversed
            needsDisplay = true
            overlay.needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    init(frame frameRect: NSRect, device: MTLDevice) {
        self.textureLoader = MTKTextureLoader(device: device)
        let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        self.mediaWorkingColorSpace = workingColorSpace
        self.imageContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: workingColorSpace
        ])
        self.imageCommandQueue = device.makeCommandQueue()
        guard let renderer = MetalRenderer(device: device, colorPixelFormat: .rgba16Float) else {
            fatalError("Metal is not available on this Mac.")
        }
        self.renderer = renderer
        super.init(frame: frameRect, device: device)

        colorPixelFormat = .rgba16Float
        clearColor = MTLClearColor(red: 0.025, green: 0.025, blue: 0.025, alpha: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        delegate = renderer
        renderer.canvas = self
        renderer.frameInterpolationEnabled = frameInterpolationEnabled
        renderer.naturalDenoiseEnabled = naturalDenoiseEnabled
        renderer.naturalDenoiseStrength = naturalDenoiseStrength
        renderer.toneRecoveryEnabled = toneRecoveryEnabled
        renderer.toneRecoveryStrength = toneRecoveryStrength
        renderer.magicRescueEnabled = magicRescueEnabled
        renderer.magicRescueStrength = magicRescueStrength
        renderer.splitCompareEnabled = splitCompareEnabled
        renderer.splitCompareReversed = splitCompareReversed

        wantsLayer = true
        syncLayerEDRMetadata()
        registerForDraggedTypes([.fileURL])

        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        setupToolPanel()
        setupVideoPanel()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickVideoUI()
            }
        }
        restartFlowTimer()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func syncLayerEDRMetadata() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let displayedItems = visibleSlots.isEmpty ? items : visibleSlots.map(\.item)
        let dynamicRange = displayedItems
            .map(\.dynamicRange)
            .max { $0.priority < $1.priority } ?? .standard

        metalLayer.colorspace = mediaWorkingColorSpace
        metalLayer.wantsExtendedDynamicRangeContent = dynamicRange.usesEDR
        guard CAEDRMetadata.isAvailable else {
            metalLayer.edrMetadata = nil
            return
        }

        switch dynamicRange {
        case .hlg:
            metalLayer.edrMetadata = CAEDRMetadata.hlg
        case .pq:
            metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0, maxLuminance: 1000, opticalOutputScale: 100)
        case .standard, .wide:
            metalLayer.edrMetadata = nil
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    private func setupToolPanel() {
        toolPanel.material = .hudWindow
        toolPanel.blendingMode = .withinWindow
        toolPanel.state = .active
        toolPanel.wantsLayer = true
        toolPanel.layer?.cornerRadius = 13
        toolPanel.layer?.masksToBounds = true
        toolPanel.isHidden = true

        toolStack.orientation = .horizontal
        toolStack.spacing = 4
        toolStack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        toolPanel.addSubview(toolStack)

        addToolButton(symbol: "arrow.up.left.and.arrow.down.right", fallbackTitle: "+", tooltip: "Enlarge item", #selector(enlargeHoveredItem))
        addToolButton(symbol: "arrow.down.right.and.arrow.up.left", fallbackTitle: "-", tooltip: "Reduce item", #selector(reduceHoveredItem))
        addToolButton(symbol: "plus.magnifyingglass", fallbackTitle: "+", tooltip: "Zoom in", #selector(zoomInHoveredItem))
        addToolButton(symbol: "minus.magnifyingglass", fallbackTitle: "-", tooltip: "Zoom out", #selector(zoomOutHoveredItem))
        addToolButton(symbol: "hand.draw", fallbackTitle: "P", tooltip: "Pan visible content", #selector(panHoveredItem))

        addSubview(toolPanel)
    }

    private func setupVideoPanel() {
        videoPanel.wantsLayer = true
        videoPanel.layer?.cornerRadius = 16
        videoPanel.layer?.masksToBounds = true
        videoPanel.isHidden = true

        videoStack.orientation = .horizontal
        videoStack.alignment = .centerY
        videoStack.spacing = 8
        videoStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        videoPanel.addSubview(videoStack)

        configureVideoIconButton(playButton, symbol: "pause.fill", fallbackTitle: "Pause", tooltip: "Pause or play video", accent: true)
        playButton.target = self
        playButton.action = #selector(toggleSelectedVideoPlayback)
        videoStack.addArrangedSubview(playButton)

        configureVideoIconButton(muteButton, symbol: "speaker.wave.2.fill", fallbackTitle: "Mute", tooltip: "Mute or unmute this video")
        muteButton.target = self
        muteButton.action = #selector(toggleSelectedVideoMute)
        videoStack.addArrangedSubview(muteButton)

        configureVideoIconButton(soloButton, symbol: "headphones", fallbackTitle: "Solo", tooltip: "Solo this video's audio")
        soloButton.target = self
        soloButton.action = #selector(toggleSelectedVideoSolo)
        videoStack.addArrangedSubview(soloButton)

        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeLabel.textColor = FlowLibraryStyle.secondaryText
        volumeLabel.alignment = .center
        volumeLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        videoStack.addArrangedSubview(volumeLabel)

        volumeSlider.target = self
        volumeSlider.action = #selector(selectedVideoVolumeChanged)
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Volume"
        volumeSlider.trackFillColor = FlowLibraryStyle.accent
        volumeSlider.widthAnchor.constraint(equalToConstant: 112).isActive = true
        videoStack.addArrangedSubview(volumeSlider)

        let speedStack = NSStackView()
        speedStack.orientation = .horizontal
        speedStack.alignment = .centerY
        speedStack.spacing = 3
        let speedDownButton = videoIconButton(
            symbol: "tortoise.fill",
            fallbackTitle: "-",
            tooltip: "Slow down playback",
            action: #selector(speedDownSelectedVideo),
            iconPointSize: 12.5,
            buttonSize: 30
        )
        speedStack.addArrangedSubview(speedDownButton)
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        speedLabel.textColor = FlowLibraryStyle.primaryText
        speedLabel.alignment = .center
        speedLabel.toolTip = "Double-click to reset speed to 1x"
        let speedResetClick = NSClickGestureRecognizer(target: self, action: #selector(resetSelectedVideoSpeed(_:)))
        speedResetClick.numberOfClicksRequired = 2
        speedLabel.addGestureRecognizer(speedResetClick)
        speedLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        speedStack.addArrangedSubview(speedLabel)
        let speedUpButton = videoIconButton(
            symbol: "hare.fill",
            fallbackTitle: "+",
            tooltip: "Speed up playback",
            action: #selector(speedUpSelectedVideo),
            iconPointSize: 12.5,
            buttonSize: 30
        )
        speedStack.addArrangedSubview(speedUpButton)
        videoStack.addArrangedSubview(speedStack)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = FlowLibraryStyle.secondaryText
        timeLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
        videoStack.addArrangedSubview(timeLabel)

        timelineView.canvas = self
        timelineView.wantsLayer = true
        timelineView.layer?.cornerRadius = 8
        timelineView.widthAnchor.constraint(equalToConstant: 360).isActive = true
        timelineView.heightAnchor.constraint(equalToConstant: 34).isActive = true
        videoStack.addArrangedSubview(timelineView)

        addVideoButton(symbol: "a.circle", fallbackTitle: "A", tooltip: "Set A point (1)", #selector(setAForSelectedVideo))
        addVideoButton(symbol: "b.circle", fallbackTitle: "B", tooltip: "Set B point and add A-B clip (2)", #selector(setBForSelectedVideo))
        addVideoButton(symbol: "xmark.circle", fallbackTitle: "Clear", tooltip: "Clear all A-B clips (0)", #selector(clearABForSelectedVideo))
        configureVideoIconButton(restoreABButton, symbol: "clock.arrow.circlepath", fallbackTitle: "AB", tooltip: "Restore saved A-B clips for this file")
        restoreABButton.target = self
        restoreABButton.action = #selector(restoreABForSelectedVideo)
        restoreABButton.isHidden = true
        videoStack.addArrangedSubview(restoreABButton)

        addSubview(videoPanel)
    }

    private func addToolButton(symbol: String, fallbackTitle: String, tooltip: String, _ action: Selector) {
        let button = iconButton(symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, action: action)
        toolStack.addArrangedSubview(button)
    }

    private func addVideoButton(symbol: String, fallbackTitle: String, tooltip: String, _ action: Selector) {
        let button = videoIconButton(symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, action: action, iconPointSize: 17)
        videoStack.addArrangedSubview(button)
    }

    private func iconButton(symbol: String, fallbackTitle: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        configureIconButton(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip)
        return button
    }

    private func configureIconButton(_ button: NSButton, symbol: String, fallbackTitle: String, tooltip: String) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        setIcon(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip)
    }

    private func videoIconButton(
        symbol: String,
        fallbackTitle: String,
        tooltip: String,
        action: Selector,
        iconPointSize: CGFloat,
        buttonSize: CGFloat = 34
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        configureVideoIconButton(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, iconPointSize: iconPointSize, buttonSize: buttonSize)
        return button
    }

    private func configureVideoIconButton(
        _ button: NSButton,
        symbol: String,
        fallbackTitle: String,
        tooltip: String,
        accent: Bool = false,
        iconPointSize: CGFloat = 17,
        buttonSize: CGFloat = 34
    ) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        setVideoButtonAppearance(button, accent: accent)
        setIcon(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, pointSize: iconPointSize)
    }

    private func setVideoButtonAppearance(_ button: NSButton, accent: Bool) {
        let fill = accent
            ? FlowLibraryStyle.accent
            : NSColor.white.withAlphaComponent(0.08)
        let stroke = accent
            ? FlowLibraryStyle.accent.withAlphaComponent(0.75)
            : NSColor.white.withAlphaComponent(0.08)
        button.layer?.backgroundColor = fill.cgColor
        button.layer?.borderColor = stroke.cgColor
        button.contentTintColor = accent ? NSColor.black.withAlphaComponent(0.84) : FlowLibraryStyle.primaryText
    }

    private func setIcon(_ button: NSButton, symbol: String, fallbackTitle: String, tooltip: String, pointSize: CGFloat? = nil) {
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.title = ""
            let templateImage = image.copy() as? NSImage ?? image
            if let pointSize,
               let configuredImage = templateImage.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold)) {
                configuredImage.isTemplate = true
                button.image = configuredImage
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                return
            }
            templateImage.isTemplate = true
            button.image = templateImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        } else {
            button.title = fallbackTitle
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    @objc func addFilesFromPanel() {
        guard !isAddFilesPanelOpen else { return }
        isAddFilesPanelOpen = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.begin { [weak self] response in
            self?.isAddFilesPanelOpen = false
            guard response == .OK else { return }
            self?.loadMedia(urls: panel.urls)
        }
    }

    @objc func savePlaybackFromPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "collage.ivplayback"
        panel.allowedContentTypes = [UTType(filenameExtension: "ivplayback") ?? .json]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.savePlayback(to: url, addToRecents: true)
            } catch {
                // savePlayback shows the user-facing alert for manual saves.
            }
        }
    }

    @objc func loadPlaybackFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ivplayback") ?? .json]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.loadPlayback(from: url, addToRecents: true)
        }
    }

    @objc func toggleCropFromPanel() {
        cropMode.toggle()
        activeCropRect = nil
        overlay.needsDisplay = true
    }

    @objc func clearAllFromPanel() {
        resetSceneForNewPlayback()
        syncLayerEDRMetadata()
        relayout()
        tickVideoUI()
        postFlowLibraryChanged()
    }

    func replacePlayback(withMediaURLs urls: [URL]) {
        resetSceneForNewPlayback()
        loadMedia(urls: urls)
    }

    private func resetSceneForNewPlayback() {
        clearABHistoryForClosingItems(items)
        items.forEach { $0.player?.pause() }
        items.removeAll()
        visibleSlots.removeAll()
        flowVisibleIndexes.removeAll()
        flowCursor = 0
        panItem = nil
        activeCropRect = nil
        isDraggingMedia = false
        soloVideoItem = nil
        hoverItem = nil
        cropMode = false
        cropStart = nil
        cropTarget = nil
        panDrag = nil
        temporaryPanItem = nil
        pendingSelectionToggleItem = nil
        didPanDragItem = false
        dragStart = nil
        dragItem = nil
        didDragItem = false
        toolPanel.isHidden = true
        videoPanel.isHidden = true
        timelineView.item = nil
        isPaused = true
        syncLayerEDRMetadata()
    }

    func clearABHistoryForClosingItems() {
        clearABHistoryForClosingItems(items)
    }

    private func clearABHistoryForClosingItems(_ closingItems: [CollageItem]) {
        for item in closingItems where item.kind == .video && item.abLoops.isEmpty {
            ABHistoryStore.clearHistory(for: item)
        }
    }

    func setHoverToolPanelEnabled(_ enabled: Bool) {
        hoverToolPanelEnabled = enabled
        if !enabled {
            toolPanel.isHidden = true
        } else {
            positionToolPanel()
        }
    }

    var isHoverToolPanelEnabled: Bool {
        hoverToolPanelEnabled
    }

    var flowStatusText: String {
        let visibleCount = visibleSlots.count
        let loadedCount = items.count
        let mode = flowRotationMode.displayName
        let interval = Int(flowRotationInterval.rounded())
        let suffix = flowAutoRotateEnabled ? "Every \(interval)s" : "Manual"
        return "\(loadedCount) loaded - \(visibleCount) on screen - \(mode) - \(suffix)"
    }

    func visibleIndexCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for index in flowVisibleIndexes where items.indices.contains(index) {
            counts[index, default: 0] += 1
        }
        return counts
    }

    func selectedLibraryIndex() -> Int? {
        guard let selected = items.first(where: \.selected) else { return nil }
        return items.firstIndex(of: selected)
    }

    func selectLibraryItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectOnly(items[index])
    }

    func revealLibraryItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectOnly(items[index])
        if !flowVisibleIndexes.contains(index) {
            flowCursor = index
            flowVisibleIndexes = makeFlowIndexes(including: index)
            relayout()
            postFlowLibraryChanged()
        }
    }

    @objc func advanceFlowFromMenu() {
        advanceFlow()
    }

    @objc func shuffleFlowFromMenu() {
        shuffleFlow()
    }

    func advanceFlow() {
        guard !items.isEmpty else { return }
        switch flowRotationMode {
        case .roundRobin:
            let step = max(1, flowTargetSlotCount())
            flowCursor = (flowCursor + step) % max(1, items.count)
        case .random:
            break
        }
        flowVisibleIndexes = makeFlowIndexes()
        relayout()
        postFlowLibraryChanged()
    }

    func shuffleFlow() {
        guard !items.isEmpty else { return }
        let allowsDuplicates = flowRotationMode == .random && flowAllowsRandomDuplicates
        flowVisibleIndexes = makeRandomFlowIndexes(allowsDuplicates: allowsDuplicates)
        if let firstIndex = flowVisibleIndexes.first {
            flowCursor = (firstIndex + max(1, flowTargetSlotCount())) % max(1, items.count)
        }
        relayout()
        postFlowLibraryChanged()
    }

    private func postFlowLibraryChanged() {
        NotificationCenter.default.post(name: .flowLibraryChanged, object: self)
    }

    private func postFlowSettingsChanged() {
        NotificationCenter.default.post(name: .flowSettingsChanged, object: self)
        postFlowLibraryChanged()
    }

    private func restartFlowTimer() {
        flowTimer?.invalidate()
        flowTimer = nil
        guard flowAutoRotateEnabled else { return }
        flowTimer = Timer.scheduledTimer(withTimeInterval: flowRotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.flowCanRotate else { return }
                self.advanceFlow()
            }
        }
    }

    private var flowCanRotate: Bool {
        guard !items.isEmpty else { return false }
        if flowRotationMode == .random && flowAllowsRandomDuplicates {
            return flowMaxVisibleItems > 1 || items.count > 1
        }
        return items.count > flowTargetSlotCount()
    }

    private func resetFlowSelection() {
        if items.isEmpty {
            flowVisibleIndexes.removeAll()
            visibleSlots.removeAll()
        } else {
            flowCursor = min(flowCursor, max(0, items.count - 1))
            flowVisibleIndexes = makeFlowIndexes()
        }
        relayout()
        postFlowLibraryChanged()
    }

    private func normalizeFlowSelection() {
        flowVisibleIndexes = flowVisibleIndexes.filter { items.indices.contains($0) }
        let targetCount = flowTargetSlotCount()
        guard targetCount > 0 else {
            flowVisibleIndexes.removeAll()
            return
        }
        if flowVisibleIndexes.count != targetCount || flowVisibleIndexes.isEmpty {
            flowVisibleIndexes = makeFlowIndexes()
        }
    }

    private func flowTargetSlotCount() -> Int {
        guard !items.isEmpty else { return 0 }
        if flowRotationMode == .random && flowAllowsRandomDuplicates {
            return flowMaxVisibleItems
        }
        return min(flowMaxVisibleItems, items.count)
    }

    private func makeFlowIndexes(including requiredIndex: Int? = nil) -> [Int] {
        guard !items.isEmpty else { return [] }
        let count = flowTargetSlotCount()
        guard count > 0 else { return [] }

        switch flowRotationMode {
        case .roundRobin:
            let start = requiredIndex ?? flowCursor
            return (0..<count).map { offset in
                (start + offset) % items.count
            }
        case .random:
            return makeRandomFlowIndexes(including: requiredIndex, allowsDuplicates: flowAllowsRandomDuplicates)
        }
    }

    private func makeRandomFlowIndexes(including requiredIndex: Int? = nil, allowsDuplicates: Bool) -> [Int] {
        guard !items.isEmpty else { return [] }
        let count = allowsDuplicates ? max(1, flowMaxVisibleItems) : min(max(1, flowMaxVisibleItems), items.count)
        if allowsDuplicates {
            var indexes: [Int] = []
            if let requiredIndex, items.indices.contains(requiredIndex) {
                indexes.append(requiredIndex)
            }
            while indexes.count < count {
                indexes.append(Int.random(in: 0..<items.count))
            }
            return indexes
        }

        var pool = Array(items.indices).shuffled()
        if let requiredIndex, items.indices.contains(requiredIndex) {
            pool.removeAll { $0 == requiredIndex }
            pool.insert(requiredIndex, at: 0)
        }
        return Array(pool.prefix(count))
    }

    private func savedFlowSettings() -> SavedFlowSettings {
        SavedFlowSettings(
            maxVisibleItems: flowMaxVisibleItems,
            rotationMode: flowRotationMode,
            allowsRandomDuplicates: flowAllowsRandomDuplicates,
            autoRotateEnabled: flowAutoRotateEnabled,
            rotationInterval: flowRotationInterval
        )
    }

    private func applySavedFlowSettings(_ settings: SavedFlowSettings?) {
        guard let settings else { return }
        flowMaxVisibleItems = settings.maxVisibleItems
        flowRotationMode = settings.rotationMode
        flowAllowsRandomDuplicates = settings.allowsRandomDuplicates
        flowAutoRotateEnabled = settings.autoRotateEnabled
        flowRotationInterval = settings.rotationInterval
    }

    func setQualityEditsDefaults(_ enabled: Bool) {
        qualityEditsDefaults = enabled
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
    }

    func isEditingQualityDefaults() -> Bool {
        qualityEditsDefaults || qualityTargetItemIgnoringDefaults() == nil
    }

    func hasQualityTargetItem() -> Bool {
        qualityTargetItemIgnoringDefaults() != nil
    }

    private func qualityTargetItemIgnoringDefaults() -> CollageItem? {
        if let selected = items.first(where: \.selected) { return selected }
        if let hoverItem { return hoverItem }
        if let lastMousePoint, let item = item(at: lastMousePoint) { return item }
        return items.last
    }

    private func qualityTargetItem() -> CollageItem? {
        qualityEditsDefaults ? nil : qualityTargetItemIgnoringDefaults()
    }

    func activeMetalQualityMode() -> MetalQualityMode {
        guard let item = qualityTargetItem() else { return metalQualityMode }
        return MetalQualityMode(rawValue: item.qualityModeRaw) ?? .best
    }

    func activeFrameInterpolationEnabled() -> Bool {
        qualityTargetItem()?.frameInterpolationEnabled ?? frameInterpolationEnabled
    }

    func activeNaturalDenoiseEnabled() -> Bool {
        qualityTargetItem()?.naturalDenoiseEnabled ?? naturalDenoiseEnabled
    }

    func activeNaturalDenoiseStrength() -> Float {
        qualityTargetItem()?.naturalDenoiseStrength ?? naturalDenoiseStrength
    }

    func activeToneRecoveryEnabled() -> Bool {
        qualityTargetItem()?.toneRecoveryEnabled ?? toneRecoveryEnabled
    }

    func activeToneRecoveryStrength() -> Float {
        qualityTargetItem()?.toneRecoveryStrength ?? toneRecoveryStrength
    }

    func activeMagicRescueEnabled() -> Bool {
        qualityTargetItem()?.magicRescueEnabled ?? magicRescueEnabled
    }

    func activeMagicRescueStrength() -> Float {
        qualityTargetItem()?.magicRescueStrength ?? magicRescueStrength
    }

    func activeQualityTargetName() -> String {
        isEditingQualityDefaults() ? "Defaults for new files" : (qualityTargetItem()?.name ?? "Defaults for new files")
    }

    private func persistQualitySettings(for item: CollageItem) {
        ensureFileHash(for: item)
        QualityProfileStore.saveProfile(for: item)
        needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
    }

    func setMetalQualityMode(_ mode: MetalQualityMode) {
        if let item = qualityTargetItem() {
            item.qualityModeRaw = mode.rawValue
            persistQualitySettings(for: item)
        } else {
            metalQualityMode = mode
            DefaultQualityStore.qualityModeRaw = mode.rawValue
        }
    }

    func setFrameInterpolationEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.frameInterpolationEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            frameInterpolationEnabled = enabled
        }
    }

    func setNaturalDenoiseEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.naturalDenoiseEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            naturalDenoiseEnabled = enabled
        }
    }

    func setNaturalDenoiseStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.naturalDenoiseStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            naturalDenoiseStrength = strength
        }
    }

    func setToneRecoveryEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.toneRecoveryEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            toneRecoveryEnabled = enabled
        }
    }

    func setToneRecoveryStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.toneRecoveryStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            toneRecoveryStrength = strength
        }
    }

    func setMagicRescueEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.magicRescueEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            magicRescueEnabled = enabled
        }
    }

    func setMagicRescueMode(_ enabled: Bool) {
        if enabled {
            setMetalQualityMode(.best)
            setNaturalDenoiseEnabled(true)
            setNaturalDenoiseStrength(max(activeNaturalDenoiseStrength(), 0.72))
            setToneRecoveryEnabled(true)
            setToneRecoveryStrength(max(activeToneRecoveryStrength(), 0.66))
            setMagicRescueStrength(max(activeMagicRescueStrength(), 0.82))
        }
        setMagicRescueEnabled(enabled)
    }

    func setMagicRescueStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.magicRescueStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            magicRescueStrength = strength
        }
    }

    func setSplitCompareEnabled(_ enabled: Bool) {
        splitCompareEnabled = enabled
    }

    func setSplitCompareReversed(_ reversed: Bool) {
        splitCompareReversed = reversed
    }

    func clearSavedFileProfiles() {
        do {
            try ABHistoryStore.clearAll()
            try QualityProfileStore.clearAll()
            items.forEach { $0.hasSavedABHistory = false }
            tickVideoUI()
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func cycleMetalQualityMode() {
        let cases = MetalQualityMode.allCases
        guard let index = cases.firstIndex(of: activeMetalQualityMode()) else {
            setMetalQualityMode(.best)
            return
        }
        setMetalQualityMode(cases[(index + 1) % cases.count])
    }

    func saveLastPlayback() {
        guard !items.isEmpty else { return }
        do {
            try LastPlaybackStore.ensureDirectory()
            try savePlayback(to: LastPlaybackStore.url, addToRecents: false)
        } catch {
            NSLog("Last playback save failed: \(error)")
        }
    }

    @discardableResult
    func restoreLastPlaybackIfAvailable() -> Bool {
        guard let url = LastPlaybackStore.existingURL else { return false }
        loadPlayback(from: url, addToRecents: false)
        return true
    }

    @objc func openLastClosedSessionFromMenu() {
        if !restoreLastPlaybackIfAvailable() {
            NSSound.beep()
        }
    }

    @objc func forgetLastClosedSessionFromMenu() {
        do {
            if try !LastPlaybackStore.deleteExisting() {
                NSSound.beep()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @discardableResult
    private func savePlayback(to url: URL, addToRecents: Bool) throws -> Bool {
        let payload = SavedPlayback(
            items: items.map { item in
                SavedItem(
                    path: item.url.path,
                    weight: item.weight,
                    zoom: item.zoom,
                    panX: item.pan.x,
                    panY: item.pan.y,
                    crop: item.cropRect,
                    speed: item.speed,
                    volume: item.volume,
                    muted: item.muted,
                    currentTime: item.kind == .video ? item.currentTimeSeconds : nil,
                    playing: item.kind == .video ? item.playWhenVisible : nil,
                    abLoops: item.abLoops.map { SavedLoop(a: $0.a, b: $0.b) }
                )
            },
            flowSettings: savedFlowSettings()
        )
        do {
            let data = try JSONEncoder().encode(payload)
            let encrypted = try PlaybackCrypto.encrypt(data)
            try encrypted.write(to: url, options: .atomic)
            if addToRecents {
                RecentPlaybacksStore.add(url)
            }
            return true
        } catch {
            if addToRecents {
                NSAlert(error: error).runModal()
            }
            throw error
        }
    }

    func loadPlayback(from url: URL, addToRecents: Bool) {
        do {
            let data = try Data(contentsOf: url)
            let playbackData = try PlaybackCrypto.decrypt(data)
            let payload = try JSONDecoder().decode(SavedPlayback.self, from: playbackData)
            clearABHistoryForClosingItems(items)
            items.forEach { $0.player?.pause() }
            items.removeAll()
            visibleSlots.removeAll()
            flowVisibleIndexes.removeAll()
            flowCursor = 0
            soloVideoItem = nil
            for saved in payload.items {
                let mediaURL = URL(fileURLWithPath: saved.path)
                guard let item = loadImage(url: mediaURL) ?? loadVideo(url: mediaURL) else { continue }
                prepareLoadedItem(item, restoreABHistory: false)
                item.weight = saved.weight
                item.zoom = max(1, saved.zoom)
                item.pan = CGPoint(x: saved.panX, y: saved.panY)
                item.cropRect = saved.crop
                item.speed = saved.speed
                item.volume = max(0, min(1, saved.volume ?? 1))
                item.muted = saved.muted
                item.abLoops = saved.abLoops.map { ($0.a, $0.b) }
                applyAudioState(for: item)
                if let seconds = saved.currentTime, seconds.isFinite, seconds > 0 {
                    resetVideoFrameHistory(for: item)
                    item.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                item.playWhenVisible = saved.playing ?? true
                if item.playWhenVisible {
                    item.player?.rate = saved.speed
                } else {
                    item.player?.pause()
                }
                items.append(item)
            }
            applySavedFlowSettings(payload.flowSettings)
            items.last?.selected = true
            isPaused = !items.contains { $0.kind == .video }
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
            relayout()
            postFlowLibraryChanged()
            if addToRecents {
                RecentPlaybacksStore.add(url)
            }
        } catch {
            if addToRecents {
                NSAlert(error: error).runModal()
            } else {
                NSLog("Last playback restore failed: \(error)")
            }
        }
    }

    @objc private func toggleSelectedVideoPlayback() {
        guard let item = selectedVideoItem() else { return }
        if item.isVideoPlaying {
            item.playWhenVisible = false
            item.player?.pause()
        } else {
            item.playWhenVisible = true
            item.player?.rate = item.speed
        }
        tickVideoUI()
    }

    @objc private func toggleSelectedVideoMute() {
        guard let item = selectedVideoItem() else { return }
        item.muted.toggle()
        if !item.muted, item.volume <= 0.01 {
            item.volume = 0.7
        }
        applyAllAudioStates()
        tickVideoUI()
    }

    @objc private func toggleSelectedVideoSolo() {
        guard let item = selectedVideoItem() else { return }
        if soloVideoItem === item {
            soloVideoItem = nil
        } else {
            soloVideoItem = item
            if item.muted || item.volume <= 0.01 {
                item.muted = false
                item.volume = max(item.volume, 0.7)
            }
        }
        applyAllAudioStates()
        tickVideoUI()
        overlay.needsDisplay = true
    }

    @objc private func selectedVideoVolumeChanged() {
        guard let item = selectedVideoItem() else { return }
        item.volume = Float(max(0, min(1, volumeSlider.doubleValue)))
        item.muted = item.volume <= 0.001
        applyAllAudioStates()
        tickVideoUI()
    }

    private func applyAudioState(for item: CollageItem) {
        item.player?.volume = item.volume
        item.player?.isMuted = item.muted || (soloVideoItem != nil && soloVideoItem !== item)
    }

    private func applyAllAudioStates() {
        for item in items where item.kind == .video {
            applyAudioState(for: item)
        }
    }

    @objc private func speedDownSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: max(0.1, item.speed - 0.05))
    }

    @objc private func speedUpSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: min(8, item.speed + 0.05))
    }

    @objc private func resetSelectedVideoSpeed(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: 1)
    }

    private func setSpeed(for item: CollageItem, speed: Float) {
        item.speed = (speed * 100).rounded() / 100
        if item.isVideoPlaying {
            item.player?.rate = item.speed
        }
        tickVideoUI()
    }

    @objc private func setAForSelectedVideo() {
        guard let item = keyboardVideoTarget() else { return }
        setA(for: item)
    }

    private func setA(for item: CollageItem) {
        suspendABLoop(for: item, seconds: 30)
        item.pendingA = item.currentTimeSeconds
        activatePendingLoopIfReady(for: item)
        selectOnly(item)
    }

    @objc private func setBForSelectedVideo() {
        guard let item = keyboardVideoTarget() else { return }
        setB(for: item)
    }

    private func setB(for item: CollageItem) {
        suspendABLoop(for: item, seconds: 30)
        item.pendingB = item.currentTimeSeconds
        activatePendingLoopIfReady(for: item)
        selectOnly(item)
    }

    @objc private func addABForSelectedVideo() {
        guard let item = selectedVideoItem(), let a = item.pendingA, let b = item.pendingB, abs(a - b) > 0.05 else { return }
        setLoop(for: item, a: a, b: b)
    }

    @objc private func clearABForSelectedVideo() {
        guard let item = keyboardVideoTarget() else { return }
        clearAB(for: item)
    }

    @objc private func restoreABForSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        _ = restoreSavedABHistory(for: item, seekToFirst: true)
    }

    private func clearAB(for item: CollageItem) {
        item.abLoops.removeAll()
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        timelineView.needsDisplay = true
        overlay.needsDisplay = true
        tickVideoUI()
    }

    @discardableResult
    private func restoreSavedABHistory(for item: CollageItem, seekToFirst: Bool, refreshUI: Bool = true) -> Bool {
        ensureFileHash(for: item)
        guard let hash = item.fileHash,
              let loops = ABHistoryStore.latestLoops(forHash: hash) else {
            item.hasSavedABHistory = false
            if refreshUI { tickVideoUI() }
            return false
        }
        item.abLoops = loops
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        item.hasSavedABHistory = true
        if seekToFirst, let first = loops.first {
            resetVideoFrameHistory(for: item)
            item.player?.seek(to: CMTime(seconds: first.a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if refreshUI {
            timelineView.needsDisplay = true
            overlay.needsDisplay = true
            tickVideoUI()
        }
        return true
    }

    func suspendABLoop(for item: CollageItem, seconds: TimeInterval) {
        guard item.kind == .video, !item.abLoops.isEmpty else { return }
        item.abLoopBypassUntil = max(item.abLoopBypassUntil, CACurrentMediaTime() + seconds)
    }

    private func activatePendingLoopIfReady(for item: CollageItem) {
        guard let a = item.pendingA, let b = item.pendingB, abs(a - b) > 0.05 else {
            timelineView.needsDisplay = true
            return
        }
        setLoop(for: item, a: a, b: b)
    }

    private func setLoop(for item: CollageItem, a: Double, b: Double) {
        let duration = item.durationSeconds
        let start = max(0, min(a, b))
        let end = duration > 0 ? min(duration, max(a, b)) : max(a, b)
        guard end - start > 0.05 else {
            timelineView.needsDisplay = true
            return
        }
        item.abLoops.append((start, end))
        item.abLoops.sort { $0.a < $1.a }
        ABHistoryStore.save(loops: item.abLoops, for: item)
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        let wasPlaying = item.isVideoPlaying
        let player = item.player
        let speed = item.speed
        resetVideoFrameHistory(for: item)
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            guard wasPlaying else { return }
            player?.rate = speed
        }
        if wasPlaying {
            player?.rate = speed
            isPaused = false
        }
        tickVideoUI()
    }

    private func tickVideoUI() {
        enforceVideoLoops()
        guard let item = selectedVideoItem() else {
            videoPanel.isHidden = true
            return
        }
        videoPanel.isHidden = false
        timelineView.item = item
        let isPlaying = item.isVideoPlaying
        setVideoButtonAppearance(playButton, accent: true)
        setIcon(
            playButton,
            symbol: isPlaying ? "pause.fill" : "play.fill",
            fallbackTitle: isPlaying ? "Pause" : "Play",
            tooltip: isPlaying ? "Pause video" : "Play video",
            pointSize: 18
        )
        setVideoButtonAppearance(muteButton, accent: item.muted)
        setIcon(
            muteButton,
            symbol: item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            fallbackTitle: item.muted ? "Unmute" : "Mute",
            tooltip: item.muted ? "Unmute this video" : "Mute this video",
            pointSize: 17
        )
        let isSolo = soloVideoItem === item
        setVideoButtonAppearance(soloButton, accent: isSolo)
        setIcon(
            soloButton,
            symbol: isSolo ? "headphones.circle.fill" : "headphones",
            fallbackTitle: "Solo",
            tooltip: isSolo ? "Turn solo off" : "Solo this video's audio",
            pointSize: 17
        )
        volumeSlider.doubleValue = Double(item.volume)
        volumeLabel.stringValue = "Vol \(Int((item.volume * 100).rounded()))%"
        speedLabel.stringValue = String(format: "%.2fx", item.speed)
        timeLabel.stringValue = "\(formatTime(item.currentTimeSeconds)) / \(formatTime(item.durationSeconds))"
        restoreABButton.isHidden = !item.hasSavedABHistory
        restoreABButton.isEnabled = item.hasSavedABHistory
        timelineView.needsDisplay = true
        positionVideoPanel()
    }

    private func enforceVideoLoops() {
        let now = CACurrentMediaTime()
        for item in items where item.kind == .video && !item.abLoops.isEmpty {
            guard item.isVideoPlaying else { continue }
            if item.pendingA != nil || item.pendingB != nil || item.abLoopBypassUntil > now {
                continue
            }
            let t = item.currentTimeSeconds
            let guardBand = max(0.045, Double(max(0.1, item.speed)) * 0.075)
            let loops = item.abLoops.sorted { $0.a < $1.a }
            let targetStart: Double?

            if let index = loops.firstIndex(where: { t >= $0.a - 0.02 && t < $0.b - guardBand }) {
                targetStart = nil
                _ = index
            } else if let index = loops.firstIndex(where: { t >= $0.a && t <= $0.b + guardBand }) {
                targetStart = loops[(index + 1) % loops.count].a
            } else {
                targetStart = (loops.first { $0.a > t } ?? loops[0]).a
            }

            if let targetStart {
                seekLoopingPlayer(item, to: targetStart)
            }
        }
    }

    private func seekLoopingPlayer(_ item: CollageItem, to seconds: Double) {
        guard let player = item.player else { return }
        let speed = item.speed
        resetVideoFrameHistory(for: item)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            player?.rate = speed
        }
        player.rate = speed
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    override func layout() {
        super.layout()
        relayout()
        positionToolPanel()
        positionVideoPanel()
    }

    private func positionVideoPanel() {
        let selectedVideo = selectedVideoItem()
        videoPanel.isHidden = selectedVideo == nil
        timelineView.item = selectedVideo
        guard selectedVideo != nil else { return }
        let size = videoStack.fittingSize
        let width = min(max(size.width + 20, 760), bounds.width - 24)
        let height = max(54, size.height + 18)
        videoPanel.frame = CGRect(x: bounds.midX - width / 2, y: 14, width: width, height: height)
        videoStack.frame = videoPanel.bounds
    }

    func relayout() {
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard !items.isEmpty else {
            visibleSlots.removeAll()
            syncLayerEDRMetadata()
            needsDisplay = true
            overlay.needsDisplay = true
            return
        }

        normalizeFlowSelection()
        let layoutItems = flowVisibleIndexes.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
        guard !layoutItems.isEmpty else {
            visibleSlots.removeAll()
            needsDisplay = true
            overlay.needsDisplay = true
            return
        }

        let candidate = bestLayout(in: bounds.size, items: layoutItems)
        visibleSlots = []
        for item in items {
            item.cellRect = .zero
            item.contentRect = .zero
        }
        for (index, rect) in candidate.rects.enumerated() {
            let item = layoutItems[index]
            let content = contentRect(for: item, cell: rect)
            visibleSlots.append(FlowSlot(item: item, cellRect: rect, contentRect: content))
            if item.cellRect == .zero {
                item.cellRect = rect
                item.contentRect = content
            }
        }
        applyFlowVisibilityPlayback()
        syncLayerEDRMetadata()
        needsDisplay = true
        overlay.needsDisplay = true
        positionToolPanel()
        positionVideoPanel()
    }

    private func applyFlowVisibilityPlayback() {
        let visibleIDs = Set(visibleSlots.map { $0.item.id })
        for item in items where item.kind == .video {
            if visibleIDs.contains(item.id) {
                if item.playWhenVisible && !isPaused && !item.isVideoPlaying {
                    item.player?.rate = item.speed
                }
            } else if item.isVideoPlaying {
                item.player?.pause()
            }
        }
        applyAllAudioStates()
    }

    private func selectedVideoItem() -> CollageItem? {
        items.first { $0.selected && $0.kind == .video }
    }

    private func keyboardVideoTarget() -> CollageItem? {
        if let hoverItem, hoverItem.kind == .video {
            return hoverItem
        }
        if let lastMousePoint, let item = item(at: lastMousePoint), item.kind == .video {
            return item
        }
        return selectedVideoItem()
    }

    private func seekVideo(_ item: CollageItem, delta: Double) {
        guard item.durationSeconds > 0 else { return }
        suspendABLoop(for: item, seconds: 5)
        let target = max(0, min(item.durationSeconds, item.currentTimeSeconds + delta))
        let player = item.player
        let wasPlaying = item.isVideoPlaying
        let speed = item.speed
        resetVideoFrameHistory(for: item)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            guard wasPlaying else { return }
            player?.rate = speed
        }
        if wasPlaying {
            player?.rate = speed
        }
        selectOnly(item)
    }

    func resetVideoFrameHistory(for item: CollageItem) {
        item.resetVideoFrameHistory()
    }

    private func adjustVideoSpeed(_ item: CollageItem, delta: Float) {
        selectOnly(item)
        setSpeed(for: item, speed: max(0.1, min(8, item.speed + delta)))
    }

    func drawRect(for slot: FlowSlot) -> CGRect {
        if slot.item.cropRect != nil || slot.item.zoom > 1.001 {
            return slot.cellRect
        }
        return slot.contentRect
    }

    func drawRect(for item: CollageItem) -> CGRect {
        if let slot = visibleSlots.first(where: { $0.item === item }) {
            return drawRect(for: slot)
        }
        if item.cropRect != nil || item.zoom > 1.001 {
            return item.cellRect
        }
        return item.contentRect
    }

    private func contentRect(for item: CollageItem, cell: CGRect) -> CGRect {
        if item.cropRect != nil || item.zoom > 1.001 { return cell }
        return fitAspect(item.visibleAspect, inside: cell)
    }

    private func fitAspect(_ aspect: CGFloat, inside rect: CGRect) -> CGRect {
        let cellAspect = rect.width / max(1, rect.height)
        if cellAspect > aspect {
            let width = rect.height * aspect
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / aspect
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    private func bestLayout(in size: CGSize, items layoutItems: [CollageItem]) -> (rects: [CGRect], score: CGFloat) {
        var best: (rects: [CGRect], score: CGFloat)?
        for order in layoutOrders(items: layoutItems) {
            var rects = Array(repeating: CGRect.zero, count: layoutItems.count)
            masonry(indices: order, in: bounds, rects: &rects, items: layoutItems)
            let score = layoutScore(rects: rects, items: layoutItems, canvasSize: size)
            if best == nil || score > best!.score {
                best = (rects, score)
            }
        }
        return best ?? (Array(repeating: bounds, count: layoutItems.count), 0)
    }

    private func layoutOrders(items layoutItems: [CollageItem]) -> [[Int]] {
        let base = Array(layoutItems.indices)
        var orders: [[Int]] = [base]
        let byArea = base.sorted { areaWeight(for: layoutItems[$0]) > areaWeight(for: layoutItems[$1]) }
        let byAspectWide = base.sorted { layoutItems[$0].visibleAspect > layoutItems[$1].visibleAspect }
        let byAspectTall = byAspectWide.reversed()
        orders.append(byArea)
        orders.append(Array(byArea.reversed()))
        orders.append(byAspectWide)
        orders.append(Array(byAspectTall))

        let interleavedAspect = interleaveExtremes(byAspectWide)
        orders.append(interleavedAspect)
        orders.append(Array(interleavedAspect.reversed()))

        let interleavedArea = interleaveExtremes(byArea)
        orders.append(interleavedArea)
        orders.append(Array(interleavedArea.reversed()))

        var unique: [[Int]] = []
        var seen = Set<String>()
        for order in orders {
            let key = order.map(String.init).joined(separator: ",")
            if seen.insert(key).inserted { unique.append(order) }
        }
        return unique
    }

    private func interleaveExtremes(_ order: [Int]) -> [Int] {
        var result: [Int] = []
        var left = 0
        var right = order.count - 1
        while left <= right {
            result.append(order[left])
            if left != right { result.append(order[right]) }
            left += 1
            right -= 1
        }
        return result
    }

    private func layoutScore(rects: [CGRect], items layoutItems: [CollageItem], canvasSize: CGSize) -> CGFloat {
        var visibleArea: CGFloat = 0
        var totalArea: CGFloat = 0
        var minSidePenalty: CGFloat = 0
        var shapePenalty: CGFloat = 0
        for index in layoutItems.indices {
            let cell = rects[index]
            let item = layoutItems[index]
            let area = cell.width * cell.height
            totalArea += area
            if item.cropRect != nil || item.zoom > 1.001 {
                visibleArea += area
            } else {
                let cellAspect = cell.width / max(1, cell.height)
                let util = min(cellAspect / item.visibleAspect, item.visibleAspect / cellAspect)
                visibleArea += area * max(0, min(1, util))
                shapePenalty += abs(log(max(0.05, cellAspect / max(0.05, item.visibleAspect)))) * 0.015
            }
            let minSide = min(cell.width, cell.height)
            if minSide < 70 {
                minSidePenalty += (70 - minSide) / 70 * 0.08
            }
        }
        let utilization = visibleArea / max(1, totalArea)
        return utilization - minSidePenalty - shapePenalty
    }

    private func masonry(indices: [Int], in rect: CGRect, rects: inout [CGRect], items layoutItems: [CollageItem]) {
        guard !indices.isEmpty else { return }
        let gap: CGFloat = bounds.width < 720 ? 3 : 6
        if indices.count == 1 {
            rects[indices[0]] = rect.integral
            return
        }

        let totalWeight = indices.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
        var best: (split: Int, vertical: Bool, score: CGFloat)?

        for split in 1..<indices.count {
            let left = Array(indices[..<split])
            let right = Array(indices[split...])
            let leftWeight = left.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
            let fraction = max(0.12, min(0.88, leftWeight / max(0.001, totalWeight)))

            let verticalWidth = rect.width * fraction
            let verticalLeft = CGRect(x: rect.minX, y: rect.minY, width: verticalWidth - gap / 2, height: rect.height)
            let verticalRight = CGRect(x: rect.minX + verticalWidth + gap / 2, y: rect.minY, width: rect.width - verticalWidth - gap / 2, height: rect.height)
            let verticalScore = groupScore(left, in: verticalLeft, items: layoutItems) + groupScore(right, in: verticalRight, items: layoutItems)

            if best == nil || verticalScore < best!.score {
                best = (split, true, verticalScore)
            }

            let horizontalHeight = rect.height * fraction
            let bottom = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: horizontalHeight - gap / 2)
            let top = CGRect(x: rect.minX, y: rect.minY + horizontalHeight + gap / 2, width: rect.width, height: rect.height - horizontalHeight - gap / 2)
            let horizontalScore = groupScore(left, in: bottom, items: layoutItems) + groupScore(right, in: top, items: layoutItems)

            if best == nil || horizontalScore < best!.score {
                best = (split, false, horizontalScore)
            }
        }

        guard let best else { return }
        let left = Array(indices[..<best.split])
        let right = Array(indices[best.split...])
        let leftWeight = left.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
        let fraction = max(0.12, min(0.88, leftWeight / max(0.001, totalWeight)))

        if best.vertical {
            let leftWidth = rect.width * fraction
            masonry(indices: left, in: CGRect(x: rect.minX, y: rect.minY, width: max(1, leftWidth - gap / 2), height: rect.height), rects: &rects, items: layoutItems)
            masonry(indices: right, in: CGRect(x: rect.minX + leftWidth + gap / 2, y: rect.minY, width: max(1, rect.width - leftWidth - gap / 2), height: rect.height), rects: &rects, items: layoutItems)
        } else {
            let bottomHeight = rect.height * fraction
            masonry(indices: left, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, bottomHeight - gap / 2)), rects: &rects, items: layoutItems)
            masonry(indices: right, in: CGRect(x: rect.minX, y: rect.minY + bottomHeight + gap / 2, width: rect.width, height: max(1, rect.height - bottomHeight - gap / 2)), rects: &rects, items: layoutItems)
        }
    }

    private func areaWeight(for item: CollageItem) -> CGFloat {
        max(0.2, min(4, item.weight * sqrt(max(0.2, min(5, item.visibleAspect)))))
    }

    private func groupScore(_ indices: [Int], in rect: CGRect, items layoutItems: [CollageItem]) -> CGFloat {
        guard rect.width > 1, rect.height > 1 else { return 1000 }
        let rectAspect = rect.width / rect.height
        let desired = desiredAspect(for: indices, items: layoutItems)
        let shapePenalty = abs(log(max(0.05, rectAspect / max(0.05, desired))))
        let smallPenalty: CGFloat = min(rect.width, rect.height) < 56 ? 8 : 0
        return shapePenalty + smallPenalty + CGFloat(indices.count) * 0.015
    }

    private func desiredAspect(for indices: [Int], items layoutItems: [CollageItem]) -> CGFloat {
        guard !indices.isEmpty else { return 1 }
        if indices.count == 1 { return layoutItems[indices[0]].visibleAspect }
        let aspects = indices.map { max(0.12, min(10, layoutItems[$0].visibleAspect)) }
        let geometricMean = exp(aspects.map { log($0) }.reduce(0, +) / CGFloat(aspects.count))
        return max(0.2, min(5, geometricMean))
    }

    private func layout(rowCount: Int, size: CGSize) -> (rects: [CGRect], score: CGFloat) {
        let aspects = items.map(\.packingAspect)
        let totalAspect = aspects.reduce(0, +)
        let target = totalAspect / CGFloat(rowCount)
        var rows = Array(repeating: [Int](), count: rowCount)
        var rowSums = Array(repeating: CGFloat(0), count: rowCount)
        var index = 0

        for row in 0..<rowCount {
            let isLast = row == rowCount - 1
            let remainingRows = rowCount - row - 1
            while index < items.count {
                let remainingItems = items.count - index
                if !isLast, remainingItems <= remainingRows, !rows[row].isEmpty { break }
                rows[row].append(index)
                rowSums[row] += aspects[index]
                index += 1
                if !isLast, rowSums[row] >= target, items.count - index >= remainingRows { break }
            }
        }

        let naturalHeights = rowSums.map { size.width / max(0.1, $0) }
        let totalNaturalHeight = naturalHeights.reduce(0, +)
        let scaleY = size.height / max(1, totalNaturalHeight)
        let gap: CGFloat = size.width < 720 ? 3 : 6
        var rects = Array(repeating: CGRect.zero, count: items.count)
        var y: CGFloat = 0
        var visibleArea: CGFloat = 0
        var totalCellArea: CGFloat = 0

        for rowIndex in rows.indices {
            let rowHeight = naturalHeights[rowIndex] * scaleY
            var x: CGFloat = 0
            for itemIndexInRow in rows[rowIndex].indices {
                let itemIndex = rows[rowIndex][itemIndexInRow]
                let naturalWidth = aspects[itemIndex] * naturalHeights[rowIndex]
                let leftGap = itemIndexInRow == 0 ? 0 : gap / 2
                let rightGap = itemIndexInRow == rows[rowIndex].count - 1 ? 0 : gap / 2
                let bottomGap = rowIndex == 0 ? 0 : gap / 2
                let topGap = rowIndex == rows.count - 1 ? 0 : gap / 2
                let cell = CGRect(
                    x: x + leftGap,
                    y: y + bottomGap,
                    width: max(1, naturalWidth - leftGap - rightGap),
                    height: max(1, rowHeight - bottomGap - topGap)
                )
                rects[itemIndex] = cell

                let item = items[itemIndex]
                let util: CGFloat
                if item.cropRect != nil || item.zoom > 1.001 {
                    util = 1
                } else {
                    let cellAspect = cell.width / max(1, cell.height)
                    let contentAspect = item.visibleAspect
                    util = min(cellAspect / contentAspect, contentAspect / cellAspect)
                }
                let area = cell.width * cell.height
                visibleArea += area * max(0, min(1, util))
                totalCellArea += area
                x += naturalWidth
            }
            y += rowHeight
        }

        let utilization = visibleArea / max(1, totalCellArea)
        let scalePenalty = abs(log(max(0.05, scaleY))) * 0.035
        let tinyRowPenalty = rows.reduce(CGFloat(0)) { partial, row in
            guard let first = row.first else { return partial + 1 }
            let ratio = rects[first].height / min(size.width, size.height)
            return partial + (ratio < 0.08 ? (0.08 - ratio) * 2 : 0)
        }
        return (rects, utilization - scalePenalty - tinyRowPenalty)
    }

    func addMediaURLs(_ urls: [URL]) {
        loadMedia(urls: urls)
    }

    private func loadMedia(urls: [URL]) {
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

    private func prepareLoadedItem(_ item: CollageItem, restoreABHistory: Bool) {
        ensureFileHash(for: item)
        _ = QualityProfileStore.applyProfile(for: item)
        if restoreABHistory {
            _ = restoreSavedABHistory(for: item, seekToFirst: false, refreshUI: false)
        }
    }

    private func ensureFileHash(for item: CollageItem) {
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

    private func loadImage(url: URL) -> CollageItem? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        if let ciImage = CIImage(contentsOf: url, options: [
            .applyOrientationProperty: true,
            .colorSpace: mediaWorkingColorSpace
        ]) {
            let extent = ciImage.extent.integral
            if extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite {
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
                if let texture = device?.makeTexture(descriptor: descriptor) {
                    let normalized = ciImage.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    imageContext.render(
                        normalized,
                        to: texture,
                        commandBuffer: nil,
                        bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                        colorSpace: mediaWorkingColorSpace
                    )
                    generateMipmaps(for: texture)
                    let item = CollageItem(url: url, kind: .image, pixelSize: CGSize(width: width, height: height), texture: texture)
                    item.dynamicRange = imageDynamicRange(source: source, ciImage: ciImage)
                    return item
                }
            }
        }

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
            return item
        } catch {
            NSLog("Image texture failed for \(url.path): \(error)")
            return nil
        }
    }

    private func generateMipmaps(for texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1,
              let commandQueue = imageCommandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func imageDynamicRange(source: CGImageSource?, ciImage: CIImage?) -> MediaDynamicRange {
        if #available(macOS 15.0, *), let ciImage, ciImage.contentHeadroom > 1.01 {
            return .pq
        }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .standard }
        let description = properties
            .map { "\(String(describing: $0.key))=\(String(describing: $0.value))" }
            .joined(separator: " ")
            .lowercased()
        if description.contains("hlg") || description.contains("arib") || description.contains("b67") {
            return .hlg
        }
        if description.contains("pq") || description.contains("2084") {
            return .pq
        }
        if description.contains("display p3") || description.contains("display-p3") || description.contains("p3") || description.contains("2020") {
            return .wide
        }
        return .standard
    }

    private func loadVideo(url: URL) -> CollageItem? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let mapping = VideoTextureMapping.make(encodedSize: track.naturalSize, preferredTransform: track.preferredTransform)
        let size = mapping?.displayRect.size ?? track.naturalSize
        let playerItem = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: true,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        output.suppressesPlayerRendering = true
        playerItem.add(output)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = false
        player.volume = 1
        player.actionAtItemEnd = .none
        let item = CollageItem(url: url, kind: .video, pixelSize: size.width > 0 ? size : CGSize(width: 16, height: 9), texture: nil)
        item.player = player
        item.videoOutput = output
        item.videoTextureMapping = mapping
        item.dynamicRange = videoDynamicRange(for: track)
        item.muted = false
        item.volume = 1
        item.speed = 1
        if track.nominalFrameRate > 0 {
            item.videoNominalFrameDuration = 1.0 / TimeInterval(track.nominalFrameRate)
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

    private func videoDynamicRange(for track: AVAssetTrack) -> MediaDynamicRange {
        var fallback: MediaDynamicRange = .standard
        for formatDescription in track.formatDescriptions {
            let format = formatDescription as! CMFormatDescription
            guard let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] else { continue }
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

    @objc private func videoItemDidPlayToEnd(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let item = items.first(where: { $0.player?.currentItem === playerItem }) else { return }
        resetVideoFrameHistory(for: item)
        item.player?.seek(to: .zero)
        if item.playWhenVisible {
            item.player?.rate = item.speed
        }
    }

    private func item(at point: CGPoint) -> CollageItem? {
        visibleSlots.reversed().first { $0.cellRect.contains(point) }?.item
    }

    private func updateHover(at point: CGPoint) {
        let next = item(at: point)
        if hoverItem !== next {
            hoverItem = next
            positionToolPanel()
        }
    }

    private func positionToolPanel() {
        guard hoverToolPanelEnabled else {
            toolPanel.isHidden = true
            return
        }
        guard let item = hoverItem else {
            toolPanel.isHidden = true
            return
        }
        let cellRect = visibleSlots.first(where: { $0.item === item })?.cellRect ?? item.cellRect
        let size = toolStack.fittingSize
        let panelSize = CGSize(width: size.width + 10, height: size.height + 10)
        toolPanel.frame = CGRect(
            x: min(bounds.maxX - panelSize.width - 8, cellRect.maxX - panelSize.width - 8),
            y: max(bounds.minY + 8, cellRect.maxY - panelSize.height - 8),
            width: panelSize.width,
            height: panelSize.height
        )
        toolStack.frame = toolPanel.bounds
        toolPanel.isHidden = false
    }

    @objc private func enlargeHoveredItem() {
        guard let hoverItem else { return }
        resize(item: hoverItem, factor: 1.16)
    }

    @objc private func reduceHoveredItem() {
        guard let hoverItem else { return }
        resize(item: hoverItem, factor: 1 / 1.16)
    }

    private func keyboardTargetItem() -> CollageItem? {
        if let selected = items.first(where: \.selected) { return selected }
        if let hoverItem { return hoverItem }
        if let lastMousePoint, let item = item(at: lastMousePoint) { return item }
        return items.last
    }

    private func resize(item: CollageItem, factor: CGFloat) {
        item.weight = max(0.55, min(2.6, item.weight * factor))
        selectOnly(item)
        relayout()
    }

    @objc func enlargeFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        resize(item: item, factor: 1.16)
    }

    @objc func reduceFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        resize(item: item, factor: 1 / 1.16)
    }

    @objc func zoomInFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        setZoom(for: item, zoom: item.zoom * 1.16, anchor: lastMousePoint)
        selectOnly(item)
    }

    @objc func zoomOutFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        setZoom(for: item, zoom: item.zoom / 1.16, anchor: lastMousePoint)
        selectOnly(item)
    }

    @objc func togglePanForFocusedItem() {
        guard let item = keyboardTargetItem(), item.canPan else { return }
        selectOnly(item)
        panItem = panItem === item ? nil : item
        overlay.needsDisplay = true
    }

    @objc private func zoomInHoveredItem() {
        guard let hoverItem else { return }
        setZoom(for: hoverItem, zoom: hoverItem.zoom * 1.16, anchor: lastMousePoint)
    }

    @objc private func zoomOutHoveredItem() {
        guard let hoverItem else { return }
        setZoom(for: hoverItem, zoom: hoverItem.zoom / 1.16, anchor: lastMousePoint)
    }

    @objc private func panHoveredItem() {
        guard let hoverItem, hoverItem.canPan else { return }
        panItem = panItem === hoverItem ? nil : hoverItem
        overlay.needsDisplay = true
    }

    private func setZoom(for item: CollageItem, zoom requestedZoom: CGFloat, anchor: CGPoint? = nil) {
        let oldZoom = item.zoom
        let targetRect = drawRect(for: item)
        let anchorPoint = anchor.map { clamp($0, to: targetRect) } ?? CGPoint(x: targetRect.midX, y: targetRect.midY)
        let localX = max(0, min(1, (anchorPoint.x - targetRect.minX) / max(1, targetRect.width)))
        let localY = max(0, min(1, (anchorPoint.y - targetRect.minY) / max(1, targetRect.height)))
        let before = normalizedSourceRect(for: item, targetAspect: targetRect.width / max(1, targetRect.height))
        let anchorSourceX = before.minX + localX * before.width
        let anchorSourceY = before.minY + (1 - localY) * before.height

        if requestedZoom < 1, item.zoom <= 1.001, item.cropRect != nil {
            expandCrop(for: item, factor: min(1.4, 1 / max(0.3, requestedZoom)), anchorSource: CGPoint(x: anchorSourceX, y: anchorSourceY), local: CGPoint(x: localX, y: localY))
            return
        }

        item.zoom = max(1, min(6, requestedZoom))
        let after = normalizedSourceRect(for: item, targetAspect: targetRect.width / max(1, targetRect.height), zoom: item.zoom, pan: .zero)
        let base = item.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let desiredCenterX = anchorSourceX - (localX - 0.5) * after.width
        let desiredCenterY = anchorSourceY + (localY - 0.5) * after.height
        let maxOffsetX = max(0, (base.width - after.width) / 2)
        let maxOffsetY = max(0, (base.height - after.height) / 2)

        if maxOffsetX > 0.0001 {
            item.pan.x = max(-1, min(1, (desiredCenterX - base.midX) / maxOffsetX))
        } else {
            item.pan.x = 0
        }
        if maxOffsetY > 0.0001 {
            item.pan.y = max(-1, min(1, (desiredCenterY - base.midY) / maxOffsetY))
        } else {
            item.pan.y = 0
        }

        if item.zoom <= 1.001 {
            item.zoom = 1
            item.pan = .zero
        }
        item.contentRect = contentRect(for: item, cell: item.cellRect)
        if (oldZoom <= 1.001) != (item.zoom <= 1.001) {
            relayout()
        } else {
            needsDisplay = true
        }
        overlay.needsDisplay = true
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(rect.maxX, point.x)), y: max(rect.minY, min(rect.maxY, point.y)))
    }

    private func normalizedSourceRect(for item: CollageItem, targetAspect: CGFloat, zoom: CGFloat? = nil, pan: CGPoint? = nil) -> CGRect {
        let base = item.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let sourceAspect = (base.width * item.pixelSize.width) / max(1, base.height * item.pixelSize.height)
        var width = base.width
        var height = base.height

        if sourceAspect > targetAspect {
            width = base.height * targetAspect * item.pixelSize.height / max(1, item.pixelSize.width)
        } else {
            height = base.width * item.pixelSize.width / max(1, targetAspect * item.pixelSize.height)
        }

        let z = max(1, min(6, zoom ?? item.zoom))
        width /= z
        height /= z

        let p = pan ?? item.pan
        let maxOffsetX = max(0, (base.width - width) / 2)
        let maxOffsetY = max(0, (base.height - height) / 2)
        let centerX = min(base.maxX - width / 2, max(base.minX + width / 2, base.midX + p.x * maxOffsetX))
        let centerY = min(base.maxY - height / 2, max(base.minY + height / 2, base.midY + p.y * maxOffsetY))

        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    private func expandCrop(for item: CollageItem, factor: CGFloat, anchorSource: CGPoint, local: CGPoint) {
        guard let crop = item.cropRect else { return }
        let width = min(1, crop.width * factor)
        let height = min(1, crop.height * factor)
        var x = anchorSource.x - local.x * width
        var y = anchorSource.y - (1 - local.y) * height
        x = max(0, min(1 - width, x))
        y = max(0, min(1 - height, y))
        if width >= 0.995, height >= 0.995 {
            item.cropRect = nil
        } else {
            item.cropRect = CGRect(x: x, y: y, width: width, height: height)
        }
        item.zoom = 1
        item.pan = .zero
        relayout()
    }

    private func applyCrop(rect rawRect: CGRect, to item: CollageItem) {
        let rect = rawRect.standardized.intersection(item.contentRect)
        guard rect.width >= 12, rect.height >= 12 else { return }
        let content = item.contentRect
        let u0 = (rect.minX - content.minX) / max(1, content.width)
        let u1 = (rect.maxX - content.minX) / max(1, content.width)
        let v0 = (content.maxY - rect.maxY) / max(1, content.height)
        let v1 = (content.maxY - rect.minY) / max(1, content.height)
        item.cropRect = CGRect(
            x: max(0, min(1, u0)),
            y: max(0, min(1, v0)),
            width: max(0.01, min(1, u1) - max(0, u0)),
            height: max(0.01, min(1, v1) - max(0, v0))
        )
        item.zoom = 1
        item.pan = .zero
        selectOnly(item)
        relayout()
    }

    private func selectOnly(_ item: CollageItem?) {
        items.forEach { $0.selected = $0 === item }
        overlay.needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        positionVideoPanel()
        tickVideoUI()
    }

    private func clearSelection() {
        items.forEach { $0.selected = false }
        panItem = nil
        temporaryPanItem = nil
        pendingSelectionToggleItem = nil
        didPanDragItem = false
        cropMode = false
        activeCropRect = nil
        overlay.needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        positionVideoPanel()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !draggedFileURLs(from: sender).isEmpty
        isDraggingMedia = accepts
        overlay.needsDisplay = true
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !draggedFileURLs(from: sender).isEmpty
        if isDraggingMedia != accepts {
            isDraggingMedia = accepts
            overlay.needsDisplay = true
        }
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDraggingMedia = false
        overlay.needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(from: sender)
        isDraggingMedia = false
        overlay.needsDisplay = true
        guard !urls.isEmpty else {
            return false
        }
        loadMedia(urls: urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDraggingMedia = false
        overlay.needsDisplay = true
    }

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoverItem = nil
        positionToolPanel()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        guard let item = item(at: point) else { return }
        let direction: CGFloat = event.scrollingDeltaY > 0 ? 1.12 : 1 / 1.12
        setZoom(for: item, zoom: item.zoom * direction, anchor: point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        updateHover(at: point)
        pendingSelectionToggleItem = nil
        didPanDragItem = false

        if event.clickCount >= 2, items.isEmpty {
            clearSelection()
            addFilesFromPanel()
            return
        }

        if cropMode || event.modifierFlags.contains(.option) {
            guard let target = item(at: point) else { return }
            cropTarget = target
            cropStart = point
            activeCropRect = CGRect(origin: point, size: .zero)
            selectOnly(target)
            overlay.needsDisplay = true
            return
        }

        guard let hit = item(at: point) else {
            clearSelection()
            return
        }

        if hit.selected && !event.modifierFlags.contains(.shift) {
            pendingSelectionToggleItem = hit
        }
        selectOnly(hit)

        if event.modifierFlags.contains(.shift) {
            dragItem = hit
            dragStart = point
            didDragItem = false
            overlay.needsDisplay = true
            return
        }

        if hit.canPan {
            if panItem !== hit {
                panItem = hit
                temporaryPanItem = hit
            }
            panDrag = (hit, point, hit.pan)
        }
        overlay.needsDisplay = true
        positionVideoPanel()
        tickVideoUI()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cropStart, cropTarget != nil {
            activeCropRect = CGRect(
                x: min(cropStart.x, point.x),
                y: min(cropStart.y, point.y),
                width: abs(point.x - cropStart.x),
                height: abs(point.y - cropStart.y)
            )
            overlay.needsDisplay = true
            return
        }

        if let panDrag {
            let dragDistance = hypot(point.x - panDrag.start.x, point.y - panDrag.start.y)
            if !didPanDragItem && dragDistance <= 3 {
                return
            }
            didPanDragItem = true
            let rect = panDrag.item.cellRect
            var next = panDrag.pan
            next.x -= (point.x - panDrag.start.x) / max(1, rect.width) * 2.2
            next.y += (point.y - panDrag.start.y) / max(1, rect.height) * 2.2
            next.x = max(-1, min(1, next.x))
            next.y = max(-1, min(1, next.y))
            panDrag.item.pan = next
            needsDisplay = true
            return
        }

        if let dragStart {
            didDragItem = didDragItem || hypot(point.x - dragStart.x, point.y - dragStart.y) > 5
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let cropTarget, let activeCropRect {
            applyCrop(rect: activeCropRect, to: cropTarget)
            self.cropTarget = nil
            cropStart = nil
            self.activeCropRect = nil
            cropMode = false
            overlay.needsDisplay = true
            return
        }

        if panDrag != nil {
            let shouldToggleSelection = !didPanDragItem
                && pendingSelectionToggleItem != nil
                && item(at: point) === pendingSelectionToggleItem
            panDrag = nil
            if temporaryPanItem != nil {
                panItem = nil
                temporaryPanItem = nil
            }
            didPanDragItem = false
            pendingSelectionToggleItem = nil
            if shouldToggleSelection {
                clearSelection()
                return
            }
            overlay.needsDisplay = true
            return
        }

        defer {
            pendingSelectionToggleItem = nil
            dragItem = nil
            dragStart = nil
            didDragItem = false
            overlay.needsDisplay = true
        }

        if let pendingSelectionToggleItem, !didDragItem, item(at: point) === pendingSelectionToggleItem {
            clearSelection()
            return
        }

        guard didDragItem, let dragItem, let target = item(at: point), target !== dragItem else { return }
        let moving = [dragItem]
        items.removeAll { $0 === dragItem }
        if let targetIndex = items.firstIndex(of: target) {
            items.insert(contentsOf: moving, at: targetIndex)
        } else {
            items.append(contentsOf: moving)
        }
        resetFlowSelection()
    }

    override func keyDown(with event: NSEvent) {
        if handleShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        let commandDown = event.modifierFlags.contains(.command)
        if event.keyCode == 53 {
            if restoreWindowIfExpanded() {
                return true
            }
            clearSelection()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            let selected = items.filter(\.selected)
            if let soloVideoItem, selected.contains(where: { $0 === soloVideoItem }) {
                self.soloVideoItem = nil
            }
            selected.forEach { item in
                if item.abLoops.isEmpty {
                    ABHistoryStore.clearHistory(for: item)
                }
                item.player?.pause()
                items.removeAll { $0 === item }
            }
            resetFlowSelection()
            applyAllAudioStates()
            tickVideoUI()
            return true
        }
        if commandDown {
            switch event.keyCode {
            case 31:
                addFilesFromPanel()
                return true
            case 1:
                savePlaybackFromPanel()
                return true
            case 37:
                loadPlaybackFromPanel()
                return true
            case 3:
                window?.toggleFullScreen(nil)
                return true
            default:
                break
            }
        }
        if !commandDown, event.keyCode == 12 {
            NSApp.terminate(nil)
            return true
        }
        if !commandDown, event.keyCode == 46 {
            cycleMetalQualityMode()
            return true
        }
        if !commandDown, let video = keyboardVideoTarget() {
            switch event.keyCode {
            case 123:
                seekVideo(video, delta: event.isARepeat ? -30 : -10)
                return true
            case 124:
                seekVideo(video, delta: event.isARepeat ? 30 : 10)
                return true
            case 125:
                adjustVideoSpeed(video, delta: event.isARepeat ? -0.15 : -0.05)
                return true
            case 126:
                adjustVideoSpeed(video, delta: event.isARepeat ? 0.15 : 0.05)
                return true
            case 18, 83:
                setA(for: video)
                return true
            case 19, 84:
                setB(for: video)
                return true
            case 29, 82:
                clearAB(for: video)
                return true
            default:
                break
            }
        }
        if !commandDown, event.keyCode == 24 || event.keyCode == 69 {
            enlargeFocusedItem()
            return true
        }
        if !commandDown, event.keyCode == 27 || event.keyCode == 78 {
            reduceFocusedItem()
            return true
        }
        if !commandDown, event.keyCode == 6 {
            cropMode.toggle()
            activeCropRect = nil
            overlay.needsDisplay = true
            return true
        }
        if !commandDown, event.keyCode == 35 {
            togglePanForFocusedItem()
            return true
        }
        if !commandDown, event.keyCode == 49 {
            let shouldPause = items.contains { $0.isVideoPlaying }
            let visibleIDs = Set(visibleSlots.map { $0.item.id })
            items.filter { $0.kind == .video }.forEach { item in
                if shouldPause {
                    item.frozenPlayWhenVisible = item.playWhenVisible
                    item.playWhenVisible = false
                    item.player?.pause()
                } else {
                    item.playWhenVisible = item.frozenPlayWhenVisible ?? true
                    item.frozenPlayWhenVisible = nil
                    if item.playWhenVisible && visibleIDs.contains(item.id) {
                        item.player?.rate = item.speed
                    }
                }
            }
            isPaused = shouldPause || !items.contains { $0.kind == .video }
            return true
        }
        return false
    }

    private func restoreWindowIfExpanded() -> Bool {
        guard let window else { return false }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return true
        }
        if window.isZoomed {
            window.zoom(nil)
            return true
        }
        guard let screen = window.screen else { return false }
        let visible = screen.visibleFrame
        let frame = window.frame
        let coversScreen = frame.width >= visible.width - 8 && frame.height >= visible.height - 8
        guard coversScreen else { return false }

        let width = min(1280, visible.width * 0.82)
        let height = min(820, visible.height * 0.82)
        let restored = CGRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(restored, display: true, animate: true)
        return true
    }
}

@MainActor private final class FlowThumbnailCache {
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

private enum FlowLibraryStyle {
    static let accent = NSColor(calibratedRed: 0.16, green: 0.92, blue: 0.72, alpha: 1)
    static let accentBlue = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.88, alpha: 1)
    static let backgroundTop = NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.14, alpha: 1)
    static let backgroundBottom = NSColor(calibratedRed: 0.18, green: 0.09, blue: 0.05, alpha: 1)
    static let cardFill = NSColor(calibratedRed: 0.27, green: 0.18, blue: 0.14, alpha: 0.78)
    static let controlPanelFill = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 0.94)
    static let controlFill = NSColor(calibratedRed: 0.34, green: 0.26, blue: 0.22, alpha: 0.86)
    static let controlStroke = NSColor.white.withAlphaComponent(0.10)
    static let primaryText = NSColor.white.withAlphaComponent(0.92)
    static let secondaryText = NSColor.white.withAlphaComponent(0.52)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.34)

    static let tilePalettes: [[NSColor]] = [
        [NSColor(calibratedRed: 0.02, green: 0.38, blue: 0.49, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.13, alpha: 1)],
        [NSColor(calibratedRed: 0.66, green: 0.37, blue: 0.12, alpha: 1), NSColor(calibratedRed: 0.31, green: 0.16, blue: 0.06, alpha: 1)],
        [NSColor(calibratedRed: 0.48, green: 0.13, blue: 0.58, alpha: 1), NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.23, alpha: 1)],
        [NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.26, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.14, blue: 0.18, alpha: 1)],
        [NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.23, alpha: 1), NSColor(calibratedRed: 0.14, green: 0.06, blue: 0.08, alpha: 1)],
        [NSColor(calibratedRed: 0.04, green: 0.46, blue: 0.38, alpha: 1), NSColor(calibratedRed: 0.11, green: 0.18, blue: 0.43, alpha: 1)],
        [NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.44, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)],
        [NSColor(calibratedRed: 0.68, green: 0.36, blue: 0.18, alpha: 1), NSColor(calibratedRed: 0.28, green: 0.08, blue: 0.12, alpha: 1)]
    ]

    @MainActor static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: secondaryText,
            .kern: 1.2
        ]))
        return label
    }

    @MainActor static func primaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = primaryText
        return label
    }

    @MainActor static func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = secondaryText
        return label
    }

    static func drawRoundedGradient(in rect: CGRect, colors: [NSColor], radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        NSGradient(colors: colors)?.draw(in: rect, angle: 135)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class FlowPanelBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [FlowLibraryStyle.backgroundTop, FlowLibraryStyle.backgroundBottom])?.draw(in: bounds, angle: 100)

        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        let warmGlow = CGRect(x: bounds.minX - 80, y: bounds.minY + 60, width: bounds.width * 1.45, height: bounds.height * 0.58)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.08, alpha: 0.36),
            NSColor(calibratedRed: 0.18, green: 0.06, blue: 0.04, alpha: 0.02)
        ])?.draw(in: warmGlow, relativeCenterPosition: CGPoint(x: -0.25, y: -0.18))

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        "Flow Library".draw(in: CGRect(x: 0, y: 8, width: bounds.width, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: FlowLibraryStyle.primaryText.withAlphaComponent(0.74),
            .paragraphStyle: titleParagraph
        ])
    }
}

private final class FlowHeaderCardView: NSView {
    weak var canvas: MetalCollageView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.cardFill.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        let loaded = canvas?.items.count ?? 0
        let visible = canvas?.visibleSlots.count ?? 0
        let circle = CGRect(x: 13, y: 12, width: 32, height: 32)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: circle).fill()
        FlowLibraryStyle.accent.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2.5
        ring.stroke()

        let number = "\(max(visible, 0))"
        let numberParagraph = NSMutableParagraphStyle()
        numberParagraph.alignment = .center
        number.draw(in: circle.insetBy(dx: 2, dy: 7), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText,
            .paragraphStyle: numberParagraph
        ])

        let title = "\(visible) on screen - \(loaded) loaded"
        title.draw(in: CGRect(x: 56, y: 13, width: bounds.width - 68, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText
        ])

        let mode = canvas?.flowRotationMode.displayName ?? "Round Robin"
        let interval = Int((canvas?.flowRotationInterval ?? 20).rounded())
        let subtitle = canvas?.flowAutoRotateEnabled == true ? "\(mode) - rotates every \(interval)s" : "\(mode) - manual advance"
        subtitle.draw(in: CGRect(x: 56, y: 31, width: bounds.width - 68, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: FlowLibraryStyle.secondaryText
        ])
    }
}

private final class FlowSwitchControl: NSControl {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let trackColors = isOn && isEnabled
            ? [FlowLibraryStyle.accent, FlowLibraryStyle.accentBlue]
            : [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.10)]
        FlowLibraryStyle.drawRoundedGradient(in: rect, colors: trackColors, radius: rect.height / 2)
        let knobDiameter = rect.height - 4
        let knobX = isOn ? rect.maxX - knobDiameter - 2 : rect.minX + 2
        NSColor.white.withAlphaComponent(isEnabled ? 0.96 : 0.45).setFill()
        NSBezierPath(ovalIn: CGRect(x: knobX, y: rect.minY + 2, width: knobDiameter, height: knobDiameter)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }
}

private final class FlowSegmentedControl: NSControl {
    var segments: [String] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()

        guard !segments.isEmpty else { return }
        let segmentWidth = rect.width / CGFloat(segments.count)
        for index in segments.indices {
            let segmentRect = CGRect(x: rect.minX + CGFloat(index) * segmentWidth, y: rect.minY, width: segmentWidth, height: rect.height)
            if index == selectedIndex {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: segmentRect.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
            }
            if index > 0 {
                NSColor.white.withAlphaComponent(0.08).setStroke()
                let divider = NSBezierPath()
                divider.move(to: CGPoint(x: segmentRect.minX, y: rect.minY + 6))
                divider.line(to: CGPoint(x: segmentRect.minX, y: rect.maxY - 6))
                divider.lineWidth = 1
                divider.stroke()
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            segments[index].draw(in: segmentRect.insetBy(dx: 3, dy: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .medium),
                .foregroundColor: index == selectedIndex ? FlowLibraryStyle.primaryText : FlowLibraryStyle.secondaryText,
                .paragraphStyle: paragraph
            ])
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !segments.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = min(segments.count - 1, max(0, Int(point.x / max(1, bounds.width) * CGFloat(segments.count))))
        guard index != selectedIndex else { return }
        selectedIndex = index
        sendAction(action, to: target)
    }
}

private final class FlowNumberStepper: NSControl {
    var minimumValue: Double = 0
    var maximumValue: Double = 100
    var stepValue: Double = 1
    var suffix = ""
    private var value: Double = 0

    override var doubleValue: Double {
        get { value }
        set { setDoubleValue(newValue, notify: false) }
    }

    override var integerValue: Int {
        get { Int(value.rounded()) }
        set { setDoubleValue(Double(newValue), notify: false) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: 30)
    }

    func setDoubleValue(_ newValue: Double, notify: Bool) {
        value = max(minimumValue, min(maximumValue, newValue))
        needsDisplay = true
        if notify {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()

        let valueRect = CGRect(x: rect.minX + 8, y: rect.minY + 7, width: rect.width - 28, height: 16)
        let valueText = "\(Int(value.rounded()))\(suffix)"
        valueText.draw(in: valueRect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText
        ])

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: rect.maxX - 21, y: rect.minY + 5))
        divider.line(to: CGPoint(x: rect.maxX - 21, y: rect.maxY - 5))
        divider.stroke()

        drawChevron(up: true, in: CGRect(x: rect.maxX - 18, y: rect.minY + 5, width: 14, height: 8))
        drawChevron(up: false, in: CGRect(x: rect.maxX - 18, y: rect.midY + 2, width: 14, height: 8))
    }

    private func drawChevron(up: Bool, in rect: CGRect) {
        let path = NSBezierPath()
        if up {
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 2))
            path.line(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 2))
        } else {
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 2))
            path.line(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 2))
        }
        path.lineWidth = 1.2
        FlowLibraryStyle.secondaryText.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.y > bounds.midY ? stepValue : -stepValue
        setDoubleValue(value + delta, notify: true)
    }
}

private final class FlowActionButton: NSControl {
    var title: String
    var symbolName: String?
    var isAccent: Bool

    init(title: String, symbolName: String?, isAccent: Bool) {
        self.title = title
        self.symbolName = symbolName
        self.isAccent = isAccent
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isAccent && isEnabled {
            FlowLibraryStyle.drawRoundedGradient(in: rect, colors: [FlowLibraryStyle.accent, FlowLibraryStyle.accentBlue], radius: 7)
        } else {
            FlowLibraryStyle.controlFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            FlowLibraryStyle.controlStroke.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            border.lineWidth = 1
            border.stroke()
        }

        let textColor = isAccent && isEnabled ? NSColor.black.withAlphaComponent(0.86) : FlowLibraryStyle.primaryText
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var textRect = rect.insetBy(dx: 8, dy: 8)
        if let symbolName {
            let textSize = (title as NSString).size(withAttributes: [.font: font])
            let totalWidth = min(rect.width - 12, 16 + 6 + textSize.width)
            let iconRect = CGRect(x: rect.midX - totalWidth / 2, y: rect.midY - 7, width: 14, height: 14)
            drawSymbol(named: symbolName, in: iconRect, color: isEnabled ? textColor : FlowLibraryStyle.tertiaryText)
            textRect = CGRect(x: iconRect.maxX + 6, y: rect.minY + 8, width: textSize.width + 2, height: 16)
            paragraph.alignment = .left
        }
        title.draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: isEnabled ? textColor : FlowLibraryStyle.tertiaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawSymbol(named symbolName: String, in rect: CGRect, color: NSColor) {
        color.setStroke()
        color.setFill()

        switch symbolName {
        case "shuffle":
            let top = NSBezierPath()
            top.move(to: CGPoint(x: rect.minX + 1.5, y: rect.minY + 4))
            top.curve(
                to: CGPoint(x: rect.maxX - 3.5, y: rect.maxY - 4),
                controlPoint1: CGPoint(x: rect.midX - 1, y: rect.minY + 4),
                controlPoint2: CGPoint(x: rect.midX + 1, y: rect.maxY - 4)
            )
            top.lineWidth = 1.5
            top.lineCapStyle = .round
            top.stroke()

            let bottom = NSBezierPath()
            bottom.move(to: CGPoint(x: rect.minX + 1.5, y: rect.maxY - 4))
            bottom.curve(
                to: CGPoint(x: rect.maxX - 3.5, y: rect.minY + 4),
                controlPoint1: CGPoint(x: rect.midX - 1, y: rect.maxY - 4),
                controlPoint2: CGPoint(x: rect.midX + 1, y: rect.minY + 4)
            )
            bottom.lineWidth = 1.5
            bottom.lineCapStyle = .round
            bottom.stroke()

            drawArrowHead(tip: CGPoint(x: rect.maxX - 1.5, y: rect.maxY - 4), up: true)
            drawArrowHead(tip: CGPoint(x: rect.maxX - 1.5, y: rect.minY + 4), up: false)
        case "forward.end.fill":
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2.5))
            triangle.line(to: CGPoint(x: rect.maxX - 4.5, y: rect.midY))
            triangle.line(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2.5))
            triangle.close()
            triangle.fill()

            let bar = NSBezierPath(roundedRect: CGRect(x: rect.maxX - 3, y: rect.minY + 2.5, width: 1.8, height: rect.height - 5), xRadius: 0.9, yRadius: 0.9)
            bar.fill()
        default:
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            dot.fill()
        }
    }

    private func drawArrowHead(tip: CGPoint, up: Bool) {
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - 4, y: tip.y + (up ? -3 : 3)))
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - 4, y: tip.y + (up ? 3 : -3)))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

private final class FlowLibraryGridView: NSView {
    weak var canvas: MetalCollageView?
    private let thumbnailCache = FlowThumbnailCache()
    private let tileSize = CGSize(width: 146, height: 100)
    private let gap: CGFloat = 8

    override var isFlipped: Bool { true }

    func reloadData() {
        let width = max(300, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        let columns = max(1, Int((width + gap) / (tileSize.width + gap)))
        let count = max(1, canvas?.items.count ?? 0)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * gap + 4
        setFrameSize(CGSize(width: width, height: max(height, enclosingScrollView?.contentView.bounds.height ?? height)))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reloadData()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let canvas, !canvas.items.isEmpty else {
            drawEmptyState()
            return
        }

        let activeCounts = canvas.visibleIndexCounts()
        let selectedIndex = canvas.selectedLibraryIndex()
        for index in canvas.items.indices {
            let rect = tileRect(for: index)
            guard rect.intersects(dirtyRect) else { continue }
            drawTile(item: canvas.items[index], index: index, rect: rect, activeCount: activeCounts[index] ?? 0, selected: selectedIndex == index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = itemIndex(at: point), canvas.items.indices.contains(index) else { return }
        if event.clickCount >= 2 {
            canvas.revealLibraryItem(at: index)
        } else {
            canvas.selectLibraryItem(at: index)
        }
        needsDisplay = true
    }

    private func drawEmptyState() {
        let text = "No media loaded"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: bounds.insetBy(dx: 18, dy: max(18, bounds.height / 2 - 10)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: FlowLibraryStyle.secondaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawTile(item: CollageItem, index: Int, rect: CGRect, activeCount: Int, selected: Bool) {
        let tile = rect.integral.insetBy(dx: 0.5, dy: 0.5)
        drawPlaceholder(for: item, in: tile, index: index)
        if let image = thumbnailCache.thumbnail(for: item, redraw: { [weak self] in self?.needsDisplay = true }) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).setClip()
            drawAspectFill(image, in: tile)
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.08),
                NSColor.black.withAlphaComponent(0.62)
            ])?.draw(in: tile, angle: 270)
            NSGraphicsContext.restoreGraphicsState()
        }

        let strokeColor = activeCount > 0 || selected ? FlowLibraryStyle.accent : NSColor.white.withAlphaComponent(0.09)
        strokeColor.setStroke()
        let border = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
        border.lineWidth = activeCount > 0 || selected ? 1.8 : 1
        border.stroke()

        drawBadge(item.kind == .video ? "VIDEO" : "IMAGE", in: CGRect(x: tile.minX + 7, y: tile.minY + 7, width: item.kind == .video ? 52 : 54, height: 17))
        drawActiveBadge(activeCount: activeCount, selected: selected, in: CGRect(x: tile.maxX - 25, y: tile.minY + 7, width: 18, height: 18))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingMiddle
        item.name.draw(in: CGRect(x: tile.minX + 8, y: tile.maxY - 22, width: tile.width - 16, height: 14), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: FlowLibraryStyle.primaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : rect.size
        let imageAspect = imageSize.width / max(1, imageSize.height)
        let rectAspect = rect.width / max(1, rect.height)
        var source = CGRect(origin: .zero, size: imageSize)
        if imageAspect > rectAspect {
            let width = imageSize.height * rectAspect
            source.origin.x = (imageSize.width - width) / 2
            source.size.width = width
        } else {
            let height = imageSize.width / rectAspect
            source.origin.y = (imageSize.height - height) / 2
            source.size.height = height
        }
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawPlaceholder(for item: CollageItem, in rect: CGRect, index: Int) {
        let colors = FlowLibraryStyle.tilePalettes[index % FlowLibraryStyle.tilePalettes.count]
        FlowLibraryStyle.drawRoundedGradient(in: rect, colors: colors, radius: 8)

        let highlight = CGRect(x: rect.minX - rect.width * 0.18, y: rect.minY - rect.height * 0.15, width: rect.width * 1.2, height: rect.height * 0.9)
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.00)
        ])?.draw(in: highlight, relativeCenterPosition: CGPoint(x: -0.15, y: -0.20))

        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    private func drawBadge(_ text: String, in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.44).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 4, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ])
    }

    private func drawActiveBadge(activeCount: Int, selected: Bool, in rect: CGRect) {
        guard activeCount > 0 || selected else { return }
        FlowLibraryStyle.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let text = activeCount > 1 ? "\(activeCount)" : "✓"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 1, dy: activeCount > 1 ? 2 : 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: activeCount > 1 ? 10 : 12, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
            .paragraphStyle: paragraph
        ])
    }

    private func itemIndex(at point: CGPoint) -> Int? {
        guard let canvas else { return nil }
        for index in canvas.items.indices where tileRect(for: index).contains(point) {
            return index
        }
        return nil
    }

    private func tileRect(for index: Int) -> CGRect {
        let columns = max(1, Int((max(1, bounds.width) + gap) / (tileSize.width + gap)))
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: CGFloat(column) * (tileSize.width + gap),
            y: CGFloat(row) * (tileSize.height + gap),
            width: tileSize.width,
            height: tileSize.height
        )
    }
}

private final class PhotosImportGridView: NSView {
    var assets: [PHAsset] = [] {
        didSet {
            selectedAssetIDs.removeAll()
            thumbnails.removeAll()
            requestedThumbnails.removeAll()
            reloadData()
        }
    }
    var selectionChanged: (() -> Void)?

    private var selectedAssetIDs = Set<String>()
    private var thumbnails: [String: NSImage] = [:]
    private var requestedThumbnails = Set<String>()
    private let imageManager = PHCachingImageManager()
    private let tileSize = CGSize(width: 104, height: 124)
    private let gap: CGFloat = 10

    override var isFlipped: Bool { true }

    var selectedAssets: [PHAsset] {
        assets.filter { selectedAssetIDs.contains($0.localIdentifier) }
    }

    func clearSelection(notify: Bool = true) {
        selectedAssetIDs.removeAll()
        needsDisplay = true
        if notify {
            selectionChanged?()
        }
    }

    func reloadData() {
        let width = max(260, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        let columns = max(1, Int((width + gap) / (tileSize.width + gap)))
        let count = max(1, assets.count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * gap + 12
        setFrameSize(CGSize(width: width, height: max(height, enclosingScrollView?.contentView.bounds.height ?? height)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard !assets.isEmpty else {
            drawCentered("No local Photos assets available", in: bounds)
            return
        }

        for index in assets.indices {
            let rect = tileRect(for: index)
            guard rect.intersects(dirtyRect) else { continue }
            let asset = assets[index]
            drawAsset(asset, rect: rect, selected: selectedAssetIDs.contains(asset.localIdentifier))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = assetIndex(at: point), assets.indices.contains(index) else { return }
        let id = assets[index].localIdentifier
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
        needsDisplay = true
        selectionChanged?()
    }

    private func drawAsset(_ asset: PHAsset, rect: CGRect, selected: Bool) {
        let background = selected ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.white.withAlphaComponent(0.055)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.14)).setStroke()
        border.lineWidth = selected ? 2 : 1
        border.stroke()

        let imageRect = CGRect(x: rect.minX + 7, y: rect.minY + 7, width: rect.width - 14, height: 86)
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).fill()
        if let image = thumbnails[asset.localIdentifier] {
            drawAspectFill(image, in: imageRect)
        } else {
            requestThumbnail(for: asset, targetSize: imageRect.size)
            drawCentered(asset.mediaType == .video ? "VIDEO" : "PHOTO", in: imageRect)
        }

        if asset.mediaType == .video {
            drawBadge("VIDEO", in: CGRect(x: imageRect.minX + 6, y: imageRect.minY + 6, width: 42, height: 16), color: .systemOrange)
        }
        if selected {
            drawBadge("ADD", in: CGRect(x: imageRect.maxX - 40, y: imageRect.minY + 6, width: 34, height: 16), color: .controlAccentColor)
        }

        let title = asset.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "Photo"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: CGRect(x: rect.minX + 6, y: imageRect.maxY + 8, width: rect.width - 12, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.86),
            .paragraphStyle: paragraph
        ])
    }

    private func requestThumbnail(for asset: PHAsset, targetSize: CGSize) {
        let id = asset.localIdentifier
        guard requestedThumbnails.insert(id).inserted else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: targetSize.width * 2, height: targetSize.height * 2),
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else { return }
            DispatchQueue.main.async { [weak self] in
                self?.thumbnails[id] = image
                self?.needsDisplay = true
            }
        }
    }

    private func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : rect.size
        let imageAspect = imageSize.width / max(1, imageSize.height)
        let rectAspect = rect.width / max(1, rect.height)
        var source = CGRect(origin: .zero, size: imageSize)
        if imageAspect > rectAspect {
            let width = imageSize.height * rectAspect
            source.origin.x = (imageSize.width - width) / 2
            source.size.width = width
        } else {
            let height = imageSize.width / rectAspect
            source.origin.y = (imageSize.height - height) / 2
            source.size.height = height
        }
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawBadge(_ text: String, in rect: CGRect, color: NSColor) {
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        color.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 0.8
        border.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 2, dy: 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph
        ])
    }

    private func drawCentered(_ text: String, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.draw(in: rect.insetBy(dx: 6, dy: max(4, rect.height / 2 - 9)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
    }

    private func assetIndex(at point: CGPoint) -> Int? {
        for index in assets.indices where tileRect(for: index).contains(point) {
            return index
        }
        return nil
    }

    private func tileRect(for index: Int) -> CGRect {
        let columns = max(1, Int((max(1, bounds.width) + gap) / (tileSize.width + gap)))
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: CGFloat(column) * (tileSize.width + gap) + 6,
            y: CGFloat(row) * (tileSize.height + gap) + 6,
            width: tileSize.width,
            height: tileSize.height
        )
    }
}

private enum PhotosImportStore {
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
                    let presets = AVAssetExportSession.exportPresets(compatibleWith: assetBox.value)
                    let preset = presets.contains(AVAssetExportPresetPassthrough)
                        ? AVAssetExportPresetPassthrough
                        : AVAssetExportPresetHighestQuality
                    guard let export = AVAssetExportSession(asset: assetBox.value, presetName: preset) else {
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

private struct MediaFlowUpdateInfo: Sendable {
    let version: String
    let buildNumber: Int?
    let title: String
    let releaseNotes: String
    let downloadURL: URL?
    let pageURL: URL

    var displayVersion: String {
        guard let buildNumber else { return version }
        return "\(version) (\(buildNumber))"
    }
}

private enum MediaFlowUpdatePhase: Sendable {
    case preparing
    case downloading
    case extracting
    case installing
    case relaunching
}

@MainActor
private final class MediaFlowUpdateService {
    private(set) var isChecking = false
    private(set) var isInstalling = false

    var onCheckingStateChanged: ((Bool) -> Void)?
    var onUpdateAvailable: ((MediaFlowUpdateInfo) -> Void)?
    var onUpToDate: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onInstallStatus: ((MediaFlowUpdatePhase, String) -> Void)?

    private var periodicTimer: Timer?
    private var hasScheduledChecks = false
    private var installerTask: Task<Void, Never>?

    deinit {
        MainActor.assumeIsolated {
            periodicTimer?.invalidate()
            installerTask?.cancel()
        }
    }

    func startAutomaticChecks() {
        guard !hasScheduledChecks else { return }
        hasScheduledChecks = true
        checkForUpdates(userInitiated: false, ignoreThrottle: true)
        schedulePeriodicChecks()
    }

    func userInitiatedCheck() {
        checkForUpdates(userInitiated: true, ignoreThrottle: true)
    }

    func installLatestUpdate(_ info: MediaFlowUpdateInfo) {
        guard installerTask == nil else { return }
        isInstalling = true
        installerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.performInstallation(info: info) { [weak self] phase, message in
                    await MainActor.run {
                        self?.onInstallStatus?(phase, message)
                    }
                }
                await MainActor.run {
                    self.onInstallStatus?(.relaunching, "Relaunching \(AppMetadata.name)...")
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.installerTask = nil
                    self.onFailure?("Installation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func checkForUpdates(userInitiated: Bool, ignoreThrottle: Bool) {
        guard !isChecking else { return }
        if !ignoreThrottle && !userInitiated && !shouldPerformAutomaticCheck {
            return
        }

        isChecking = true
        onCheckingStateChanged?(true)

        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatestRelease()
                await MainActor.run {
                    self.handleRelease(release, userInitiated: userInitiated)
                    self.finishChecking()
                }
            } catch {
                await MainActor.run {
                    self.finishChecking()
                    if userInitiated {
                        self.onFailure?(Self.errorMessage(for: error))
                    }
                }
            }
        }
    }

    private var shouldPerformAutomaticCheck: Bool {
        guard let lastCheck = UserDefaults.standard.object(forKey: AppMetadata.lastUpdateCheckDefaultsKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) > 60 * 60 * 24
    }

    private func finishChecking() {
        isChecking = false
        onCheckingStateChanged?(false)
    }

    private func handleRelease(_ release: GitHubRelease, userInitiated: Bool) {
        UserDefaults.standard.set(Date(), forKey: AppMetadata.lastUpdateCheckDefaultsKey)

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let releaseIdentity = Self.parseReleaseIdentity(from: release)
        let comparison = Self.compareRelease(
            lhsVersion: releaseIdentity.version,
            lhsBuild: releaseIdentity.buildNumber,
            rhsVersion: currentVersion,
            rhsBuild: currentBuild
        )

        if comparison == .orderedDescending {
            let title = release.name.isEmpty
                ? "\(AppMetadata.name) \(Self.displayVersion(version: releaseIdentity.version, buildNumber: releaseIdentity.buildNumber))"
                : release.name
            let info = MediaFlowUpdateInfo(
                version: releaseIdentity.version,
                buildNumber: releaseIdentity.buildNumber,
                title: title,
                releaseNotes: release.notesPreview,
                downloadURL: Self.preferredDownloadURL(from: release.assets),
                pageURL: release.htmlURL
            )
            onUpdateAvailable?(info)
        } else if userInitiated {
            onUpToDate?(Self.displayVersion(version: currentVersion, buildNumber: currentBuild))
        }
    }

    private func schedulePeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdates(userInitiated: false, ignoreThrottle: false)
            }
        }
    }

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(AppMetadata.repositoryOwner)/\(AppMetadata.repositoryName)/releases/latest") else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = ProcessInfo.processInfo.environment["MEDIAFLOW_GITHUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateError.badStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func preferredDownloadURL(from assets: [GitHubRelease.Asset]) -> URL? {
        let appName = AppMetadata.name.lowercased()
        let dmg = assets.first {
            $0.browserDownloadURL.pathExtension.lowercased() == "dmg"
                && $0.name.lowercased().contains(appName)
        } ?? assets.first { $0.browserDownloadURL.pathExtension.lowercased() == "dmg" }
        if let dmgURL = dmg?.browserDownloadURL { return dmgURL }

        let zip = assets.first {
            $0.browserDownloadURL.pathExtension.lowercased() == "zip"
                && $0.name.lowercased().contains(appName)
        } ?? assets.first { $0.browserDownloadURL.pathExtension.lowercased() == "zip" }
        if let zipURL = zip?.browserDownloadURL { return zipURL }

        return assets.first?.browserDownloadURL
    }

    private static func performInstallation(
        info: MediaFlowUpdateInfo,
        status: @escaping @Sendable (MediaFlowUpdatePhase, String) async -> Void
    ) async throws {
        guard let downloadURL = info.downloadURL else {
            await MainActor.run {
                _ = NSWorkspace.shared.open(info.pageURL)
            }
            return
        }

        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(AppMetadata.name)Update-\(UUID().uuidString)", isDirectory: true)
        let downloadTarget = tempDir.appendingPathComponent(downloadURL.lastPathComponent)
        var shouldCleanupTempDir = true

        defer {
            if shouldCleanupTempDir {
                try? fileManager.removeItem(at: tempDir)
            }
        }

        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        await status(.preparing, "Preparing update...")
        await status(.downloading, "Downloading \(AppMetadata.name) \(info.displayVersion)...")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 15
        let session = URLSession(configuration: configuration)
        let (downloadedURL, response) = try await session.download(from: downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw UpdateError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if fileManager.fileExists(atPath: downloadTarget.path) {
            try fileManager.removeItem(at: downloadTarget)
        }
        try fileManager.moveItem(at: downloadedURL, to: downloadTarget)

        await status(.extracting, "Extracting update...")
        let extractedApp = try extractApplication(from: downloadTarget, workingDirectory: tempDir)

        await status(.installing, "Installing update...")
        try installAndPrepareRelaunch(using: extractedApp, tempDir: tempDir)
        shouldCleanupTempDir = false
    }

    private static func extractApplication(from archiveURL: URL, workingDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let ext = archiveURL.pathExtension.lowercased()

        if ext == "dmg" {
            return try extractFromDMG(archiveURL, workingDirectory: workingDirectory)
        }
        if ext == "zip" {
            try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, workingDirectory.path])
        } else if ext == "app" {
            let destination = workingDirectory.appendingPathComponent(archiveURL.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: archiveURL, to: destination)
            return destination
        }

        if let appURL = try findAppBundle(in: workingDirectory) {
            return appURL
        }
        throw InstallationError.missingAppBundle
    }

    private static func extractFromDMG(_ dmgURL: URL, workingDirectory: URL) throws -> URL {
        let mountPoint = "/Volumes/\(AppMetadata.name)Update-\(UUID().uuidString)"
        try runProcess("/usr/bin/hdiutil", arguments: [
            "attach",
            dmgURL.path,
            "-mountpoint", mountPoint,
            "-nobrowse",
            "-quiet"
        ])

        defer {
            _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-force"])
        }

        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let appURL = contents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw InstallationError.missingAppBundle
        }

        let destination = workingDirectory.appendingPathComponent(appURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: appURL, to: destination)
        return destination
    }

    private static func installAndPrepareRelaunch(using appURL: URL, tempDir: URL) throws {
        let fileManager = FileManager.default
        let destinationApp = try resolvedDestinationAppURL()
        let destinationDir = destinationApp.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: destinationDir.path) {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        let stagedApp = destinationDir.appendingPathComponent(".\(AppMetadata.name)Update-\(UUID().uuidString).app")
        if fileManager.fileExists(atPath: stagedApp.path) {
            try fileManager.removeItem(at: stagedApp)
        }
        try fileManager.copyItem(at: appURL, to: stagedApp)

        let scriptURL = tempDir.appendingPathComponent("install.sh")
        let script = """
#!/bin/bash
set -euo pipefail
TEMP_APP="$1"
DEST_APP="$2"
PROCESS_NAME="$3"
TEMP_DIR="$4"

TRIES=0
while pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; do
  sleep 0.5
  TRIES=$((TRIES + 1))
  if [ "$TRIES" -ge 60 ]; then
    exit 1
  fi
done

sleep 1
rm -rf "$DEST_APP"
mv "$TEMP_APP" "$DEST_APP"
open "$DEST_APP"
sleep 1
rm -rf "$TEMP_DIR"
"""
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try runProcess("/bin/chmod", arguments: ["+x", scriptURL.path])

        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = [
            scriptURL.path,
            stagedApp.path,
            destinationApp.path,
            ProcessInfo.processInfo.processName,
            tempDir.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    private static func resolvedDestinationAppURL() throws -> URL {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let bundleParent = bundleURL.deletingLastPathComponent()

        if fileManager.isWritableFile(atPath: bundleParent.path) {
            return bundleURL
        }

        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fileManager.isWritableFile(atPath: systemApplications.path) {
            return systemApplications.appendingPathComponent("\(AppMetadata.name).app", isDirectory: true)
        }

        let userApplications = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        if !fileManager.fileExists(atPath: userApplications.path) {
            try fileManager.createDirectory(at: userApplications, withIntermediateDirectories: true)
        }
        return userApplications.appendingPathComponent("\(AppMetadata.name).app", isDirectory: true)
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let directMatch = contents.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return directMatch
        }
        for entry in contents {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true, let nested = try findAppBundle(in: entry) {
                return nested
            }
        }
        return nil
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw InstallationError.processFailure(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func compareRelease(lhsVersion: String, lhsBuild: Int?, rhsVersion: String, rhsBuild: Int?) -> ComparisonResult {
        let versionComparison = compareVersion(lhs: lhsVersion, rhs: rhsVersion)
        if versionComparison != .orderedSame {
            return versionComparison
        }

        guard let leftBuild = lhsBuild, let rightBuild = rhsBuild else {
            return .orderedSame
        }
        if leftBuild < rightBuild { return .orderedAscending }
        if leftBuild > rightBuild { return .orderedDescending }
        return .orderedSame
    }

    private static func compareVersion(lhs: String, rhs: String) -> ComparisonResult {
        let lhsComponents = versionComponents(lhs)
        let rhsComponents = versionComponents(rhs)
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let left = index < lhsComponents.count ? lhsComponents[index] : 0
            let right = index < rhsComponents.count ? rhsComponents[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    private static func parseReleaseIdentity(from release: GitHubRelease) -> (version: String, buildNumber: Int?) {
        let normalizedTag = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        if let buildNumber = extractBuildNumber(from: release.name) ?? extractBuildNumber(from: release.body ?? "") {
            return (version: normalizedTag, buildNumber: buildNumber)
        }
        return (version: normalizedTag, buildNumber: nil)
    }

    private static func extractBuildNumber(from text: String) -> Int? {
        let pattern = #"(?i)\bbuild[\s#:()_-]*([0-9]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[captureRange])
    }

    private static func displayVersion(version: String, buildNumber: Int?) -> String {
        guard let buildNumber else { return version }
        return "\(version) (\(buildNumber))"
    }

    private static func errorMessage(for error: Error) -> String {
        if let updateError = error as? UpdateError {
            return updateError.localizedDescription
        }
        return error.localizedDescription
    }

    private struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let name: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        var notesPreview: String {
            let trimmed = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return lines.prefix(10).joined(separator: "\n")
        }

        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidURL
        case invalidResponse
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Failed to build the update URL."
            case .invalidResponse:
                return "GitHub returned an invalid response."
            case .badStatus(let code):
                if code == 404 {
                    return "No public GitHub release is available yet, or the repository is private."
                }
                return "GitHub update check failed with status code \(code)."
            }
        }
    }

    private enum InstallationError: LocalizedError {
        case missingAppBundle
        case processFailure(String)

        var errorDescription: String? {
            switch self {
            case .missingAppBundle:
                return "Downloaded archive did not contain a \(AppMetadata.name) app."
            case .processFailure(let output):
                return output.isEmpty ? "A helper command failed while installing the update." : output
            }
        }
    }
}

@MainActor
private final class MediaFlowChangelogService {
    static let shared = MediaFlowChangelogService()

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    func loadBundledOrCachedMarkdown() -> String {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let markdown = try? String(contentsOf: url, encoding: .utf8) {
            return markdown
        }
        if let cached = UserDefaults.standard.string(forKey: AppMetadata.changelogCacheDefaultsKey) {
            return cached
        }
        if let projectURL = URL(string: "\(AppMetadata.repositoryURL.absoluteString)/blob/main/CHANGELOG.md") {
            return "# Changelog\n\nNo bundled changelog was found.\n\nOpen \(projectURL.absoluteString) for the latest notes."
        }
        return "# Changelog\n\nNo bundled changelog was found."
    }

    func fetchRemoteMarkdown() async -> String? {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(AppMetadata.repositoryOwner)/\(AppMetadata.repositoryName)/main/CHANGELOG.md") else {
            return nil
        }
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let markdown = String(data: data, encoding: .utf8) else {
                return nil
            }
            UserDefaults.standard.set(markdown, forKey: AppMetadata.changelogCacheDefaultsKey)
            return markdown
        } catch {
            return nil
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var window: NSWindow?
    private weak var canvas: MetalCollageView?
    private var pendingExternalOpenURLs: [URL] = []
    private var qualityPanel: NSPanel?
    private var qualityPanelTargetLabel: NSTextField?
    private var qualityPanelDefaultsButton: NSButton?
    private var qualityPanelModePopup: NSPopUpButton?
    private var qualityPanelFrameInterpolationButton: NSButton?
    private var qualityPanelDenoiseButton: NSButton?
    private var qualityPanelDenoiseSlider: NSSlider?
    private var qualityPanelDenoiseValue: NSTextField?
    private var qualityPanelToneButton: NSButton?
    private var qualityPanelToneSlider: NSSlider?
    private var qualityPanelToneValue: NSTextField?
    private var qualityPanelMagicButton: NSButton?
    private var qualityPanelMagicSlider: NSSlider?
    private var qualityPanelMagicValue: NSTextField?
    private var qualityPanelSplitButton: NSButton?
    private var qualityPanelSplitReverseButton: NSButton?
    private var flowPanel: NSPanel?
    private var flowGridView: FlowLibraryGridView?
    private var flowHeaderView: FlowHeaderCardView?
    private var flowPoolCountLabel: NSTextField?
    private var flowMaxStepper: FlowNumberStepper?
    private var flowModeControl: FlowSegmentedControl?
    private var flowAutoRotateButton: FlowSwitchControl?
    private var flowIntervalStepper: FlowNumberStepper?
    private var flowDuplicateButton: FlowSwitchControl?
    private var photosPanel: NSPanel?
    private var photosGridView: PhotosImportGridView?
    private var photosImportButton: NSButton?
    private var photosStatusLabel: NSTextField?
    private let updateService = MediaFlowUpdateService()
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var aboutWindow: NSWindow?
    private var changelogWindow: NSWindow?
    private var changelogTextView: NSTextView?
    private var installStatusPanel: NSPanel?
    private var installStatusLabel: NSTextField?
    private let recentMenu = NSMenu(title: "Recent Playbacks")
    private let qualityMenu = NSMenu(title: "Metal Quality")
    private var frameInterpolationMenuItem: NSMenuItem?
    private var naturalDenoiseMenuItem: NSMenuItem?
    private var magicRescueMenuItem: NSMenuItem?
    private var hoverToolsMenuItem: NSMenuItem?
    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSAlert(error: NSError(domain: "MediaFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Metal is not available on this Mac."
            ])).runModal()
            NSApp.terminate(nil)
            return
        }

        let canvas = MetalCollageView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), device: device)
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppMetadata.name
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        if !WindowFrameStore.restore(window) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.canvas = canvas
        NSApp.mainMenu = makeMainMenu()
        configureUpdateService()
        rebuildRecentMenu()
        rebuildQualityMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildRecentMenu), name: .recentPlaybacksChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildQualityMenu), name: .metalQualityModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncQualityControls), name: .qualitySettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncFlowControls), name: .flowLibraryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncFlowControls), name: .flowSettingsChanged, object: nil)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  NSApp.keyWindow === window,
                  let canvas = self.canvas else { return event }
            return canvas.handleShortcut(event) ? nil : event
        }
        openPendingExternalURLsIfNeeded()
        updateService.startAutomaticChecks()

        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        MainActor.assumeIsolated {
            if let shortcutMonitor {
                NSEvent.removeMonitor(shortcutMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowFrameStore.save(window)
        canvas?.saveLastPlayback()
        canvas?.clearABHistoryForClosingItems()
    }

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        openExternalMediaURLs(urls)
    }

    @MainActor func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openExternalMediaURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    @MainActor func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openExternalMediaURLs([URL(fileURLWithPath: filename)])
        return true
    }

    @MainActor private func openPendingExternalURLsIfNeeded() {
        guard !pendingExternalOpenURLs.isEmpty else { return }
        let urls = pendingExternalOpenURLs
        pendingExternalOpenURLs.removeAll()
        openExternalMediaURLs(urls)
    }

    @MainActor private func openExternalMediaURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let canvas else {
            pendingExternalOpenURLs.append(contentsOf: urls)
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        canvas.replacePlayback(withMediaURLs: urls)
    }

    @MainActor private func configureUpdateService() {
        updateService.onCheckingStateChanged = { [weak self] isChecking in
            self?.checkForUpdatesMenuItem?.title = isChecking ? "Checking for Updates..." : "Check for Updates..."
            self?.checkForUpdatesMenuItem?.isEnabled = !isChecking
        }
        updateService.onUpdateAvailable = { [weak self] info in
            self?.showUpdateAvailableDialog(info)
        }
        updateService.onUpToDate = { [weak self] version in
            self?.showSimpleAlert(
                title: "You're Up to Date",
                message: "You're already running \(AppMetadata.name) \(version).",
                style: .informational
            )
        }
        updateService.onFailure = { [weak self] message in
            self?.hideInstallStatusPanel()
            self?.showSimpleAlert(
                title: "Update Check Failed",
                message: message,
                style: .warning
            )
        }
        updateService.onInstallStatus = { [weak self] _, message in
            self?.showInstallStatus(message)
        }
    }

    @MainActor private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "About \(AppMetadata.name)", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        let checkItem = appMenu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        checkItem.target = self
        checkForUpdatesMenuItem = checkItem
        let whatsNewItem = appMenu.addItem(withTitle: "What's New...", action: #selector(showChangelogWindow), keyEquivalent: "")
        whatsNewItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppMetadata.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Files...", action: #selector(MetalCollageView.addFilesFromPanel), keyEquivalent: "o")
        let photosItem = fileMenu.addItem(withTitle: "Add From Photos...", action: #selector(addFromPhotos), keyEquivalent: "")
        photosItem.target = self
        fileMenu.addItem(withTitle: "Save Playback...", action: #selector(MetalCollageView.savePlaybackFromPanel), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Load Playback...", action: #selector(MetalCollageView.loadPlaybackFromPanel), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Open Last Closed Session", action: #selector(MetalCollageView.openLastClosedSessionFromMenu), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Forget Last Closed Session", action: #selector(MetalCollageView.forgetLastClosedSessionFromMenu), keyEquivalent: "")
        let recentItem = NSMenuItem(title: "Recent Playbacks", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Clear All", action: #selector(MetalCollageView.clearAllFromPanel), keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let cropItem = viewMenu.addItem(withTitle: "Toggle Crop", action: #selector(MetalCollageView.toggleCropFromPanel), keyEquivalent: "z")
        cropItem.keyEquivalentModifierMask = []
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        let flowLibrary = viewMenu.addItem(withTitle: "Flow Library...", action: #selector(showFlowPanel), keyEquivalent: "y")
        flowLibrary.target = self
        let qualityControls = viewMenu.addItem(withTitle: "Quality Controls...", action: #selector(showQualityPanel), keyEquivalent: "k")
        qualityControls.target = self
        viewMenu.addItem(.separator())
        let qualityItem = NSMenuItem(title: "Metal Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        viewMenu.addItem(qualityItem)
        let cycleQuality = viewMenu.addItem(withTitle: "Cycle Metal Quality", action: #selector(MetalCollageView.cycleMetalQualityMode), keyEquivalent: "m")
        cycleQuality.keyEquivalentModifierMask = []
        let frameInterpolation = viewMenu.addItem(withTitle: "Frame Interpolation for Speed", action: #selector(toggleFrameInterpolation(_:)), keyEquivalent: "")
        frameInterpolation.target = self
        frameInterpolation.state = canvas?.activeFrameInterpolationEnabled() == true ? .on : .off
        frameInterpolationMenuItem = frameInterpolation
        let naturalDenoise = viewMenu.addItem(withTitle: "Natural Denoise + Detail", action: #selector(toggleNaturalDenoise(_:)), keyEquivalent: "")
        naturalDenoise.target = self
        naturalDenoise.state = canvas?.activeNaturalDenoiseEnabled() == true ? .on : .off
        naturalDenoise.toolTip = "Edge-aware Metal noise reduction with detail and contrast restoration"
        naturalDenoiseMenuItem = naturalDenoise
        let magicRescue = viewMenu.addItem(withTitle: "Magic Rescue", action: #selector(toggleMagicRescue(_:)), keyEquivalent: "")
        magicRescue.target = self
        magicRescue.state = canvas?.activeMagicRescueEnabled() == true ? .on : .off
        magicRescue.toolTip = "Aggressive Metal enhancement for noisy dark or blown-out material"
        magicRescueMenuItem = magicRescue
        let hoverTools = viewMenu.addItem(withTitle: "Show Hover Item Tools", action: #selector(toggleHoverTools(_:)), keyEquivalent: "")
        hoverTools.target = self
        hoverTools.state = .off
        hoverToolsMenuItem = hoverTools
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let itemMenuItem = NSMenuItem()
        let itemMenu = NSMenu(title: "Item")
        let enlargeItem = itemMenu.addItem(withTitle: "Enlarge", action: #selector(MetalCollageView.enlargeFocusedItem), keyEquivalent: "=")
        enlargeItem.keyEquivalentModifierMask = []
        let reduceItem = itemMenu.addItem(withTitle: "Reduce", action: #selector(MetalCollageView.reduceFocusedItem), keyEquivalent: "-")
        reduceItem.keyEquivalentModifierMask = []
        itemMenu.addItem(.separator())
        itemMenu.addItem(withTitle: "Zoom In", action: #selector(MetalCollageView.zoomInFocusedItem), keyEquivalent: "")
        itemMenu.addItem(withTitle: "Zoom Out", action: #selector(MetalCollageView.zoomOutFocusedItem), keyEquivalent: "")
        let panItem = itemMenu.addItem(withTitle: "Toggle Pan", action: #selector(MetalCollageView.togglePanForFocusedItem), keyEquivalent: "p")
        panItem.keyEquivalentModifierMask = []
        itemMenuItem.submenu = itemMenu
        main.addItem(itemMenuItem)

        return main
    }

    @MainActor @objc private func checkForUpdatesFromMenu() {
        updateService.userInitiatedCheck()
    }

    @MainActor @objc private func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = makeAboutWindow()
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func makeAboutWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "About \(AppMetadata.name)"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 86),
            icon.heightAnchor.constraint(equalToConstant: 86)
        ])
        stack.addArrangedSubview(icon)

        stack.addArrangedSubview(makeDialogLabel(AppMetadata.name, size: 24, weight: .semibold, color: .labelColor))
        let tagline = makeDialogLabel(AppMetadata.tagline, size: 13, weight: .regular, color: .secondaryLabelColor)
        tagline.maximumNumberOfLines = 2
        tagline.alignment = .center
        stack.addArrangedSubview(tagline)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = makeDialogLabel("Version \(version) (\(build))", size: 12, weight: .regular, color: .tertiaryLabelColor)
        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(versionLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let author = makeDialogLabel("by \(AppMetadata.authorName)", size: 13, weight: .medium, color: .secondaryLabelColor)
        stack.addArrangedSubview(author)

        let links = NSStackView()
        links.orientation = .vertical
        links.spacing = 8
        links.alignment = .width
        links.translatesAutoresizingMaskIntoConstraints = false
        links.addArrangedSubview(makeLinkButton(title: "Project on GitHub", url: AppMetadata.repositoryURL))
        links.addArrangedSubview(makeLinkButton(title: "Author Profile", url: AppMetadata.authorURL))
        links.addArrangedSubview(makeLinkButton(
            title: AppMetadata.licenseName,
            url: URL(string: "\(AppMetadata.repositoryURL.absoluteString)/blob/main/LICENSE") ?? AppMetadata.repositoryURL
        ))
        stack.addArrangedSubview(links)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 34)
        ])

        return panel
    }

    @MainActor @objc private func showChangelogWindow() {
        if changelogWindow == nil {
            changelogWindow = makeChangelogWindow()
        }
        changelogTextView?.string = MediaFlowChangelogService.shared.loadBundledOrCachedMarkdown()
        changelogWindow?.center()
        changelogWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { [weak self] in
            guard let markdown = await MediaFlowChangelogService.shared.fetchRemoteMarkdown() else { return }
            await MainActor.run {
                self?.changelogTextView?.string = markdown
            }
        }
    }

    @MainActor private func makeChangelogWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "What's New"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = content

        let title = makeDialogLabel("What's New in \(AppMetadata.name)", size: 18, weight: .semibold, color: .labelColor)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.string = MediaFlowChangelogService.shared.loadBundledOrCachedMarkdown()
        changelogTextView = textView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        let openGitHub = NSButton(title: "Open on GitHub", target: self, action: #selector(openButtonURL(_:)))
        let changelogURL = URL(string: "\(AppMetadata.repositoryURL.absoluteString)/blob/main/CHANGELOG.md") ?? AppMetadata.repositoryURL
        openGitHub.identifier = NSUserInterfaceItemIdentifier(changelogURL.absoluteString)
        openGitHub.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(openGitHub)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            openGitHub.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            openGitHub.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        return panel
    }

    @MainActor private func showUpdateAvailableDialog(_ info: MediaFlowUpdateInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = "\(AppMetadata.name) \(info.displayVersion) is ready.\n\n\(info.title)"
        alert.icon = NSImage(named: NSImage.applicationIconName)
        if !info.releaseNotes.isEmpty {
            alert.accessoryView = makeReleaseNotesAccessory(info.releaseNotes)
        }

        if info.downloadURL != nil {
            alert.addButton(withTitle: "Install Update")
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                updateService.installLatestUpdate(info)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(info.pageURL)
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(info.pageURL)
            }
        }
    }

    @MainActor private func showSimpleAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor private func makeReleaseNotesAccessory(_ notes: String) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.string = notes
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return scrollView
    }

    @MainActor private func showInstallStatus(_ message: String) {
        if installStatusPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "Installing Update"
            panel.isReleasedWhenClosed = false

            let content = NSView()
            panel.contentView = content

            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.startAnimation(nil)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(indicator)

            let label = makeDialogLabel(message, size: 13, weight: .regular, color: .labelColor)
            label.maximumNumberOfLines = 2
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            installStatusLabel = label

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 14)
            ])

            installStatusPanel = panel
        }

        installStatusLabel?.stringValue = message
        installStatusPanel?.center()
        installStatusPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func hideInstallStatusPanel() {
        installStatusPanel?.orderOut(nil)
    }

    @MainActor private func makeDialogLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        return label
    }

    @MainActor private func makeLinkButton(title: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openButtonURL(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return button
    }

    @MainActor @objc private func openButtonURL(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor @objc private func addFromPhotos() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            showPhotosImportPanel()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if newStatus == .authorized || newStatus == .limited {
                        self.showPhotosImportPanel()
                    } else {
                        self.showPhotosAccessAlert()
                    }
                }
            }
        default:
            showPhotosAccessAlert()
        }
    }

    @MainActor private func showPhotosImportPanel() {
        if photosPanel == nil {
            photosPanel = makePhotosPanel()
        }
        let assets = fetchRecentPhotosAssets()
        photosGridView?.assets = assets
        syncPhotosImportControls()
        if let window, let photosPanel, !photosPanel.isVisible {
            let x = min(window.frame.maxX - photosPanel.frame.width - 22, max(window.frame.minX + 22, window.frame.midX - photosPanel.frame.width / 2))
            let y = min(window.frame.maxY - photosPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - photosPanel.frame.height / 2))
            photosPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        photosPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func makePhotosPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add From Photos"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 520, height: 600))
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView(frame: content.bounds.insetBy(dx: 16, dy: 14))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalToConstant: 488).isActive = true
        photosStatusLabel = status
        stack.addArrangedSubview(status)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(equalToConstant: 488).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 470).isActive = true
        let grid = PhotosImportGridView(frame: NSRect(x: 0, y: 0, width: 488, height: 470))
        grid.selectionChanged = { [weak self] in
            self?.syncPhotosImportControls()
        }
        photosGridView = grid
        scroll.documentView = grid
        stack.addArrangedSubview(scroll)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        let importButton = NSButton(title: "Import Selected", target: self, action: #selector(importSelectedPhotos))
        importButton.bezelStyle = .rounded
        importButton.isEnabled = false
        photosImportButton = importButton
        buttonRow.addArrangedSubview(importButton)
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPhotosPanel))
        refreshButton.bezelStyle = .rounded
        buttonRow.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(buttonRow)

        panel.contentView = content
        return panel
    }

    @MainActor private func fetchRecentPhotosAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.fetchLimit = 300
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    @MainActor @objc private func refreshPhotosPanel() {
        photosGridView?.assets = fetchRecentPhotosAssets()
        syncPhotosImportControls()
    }

    @MainActor @objc private func importSelectedPhotos() {
        guard let selectedAssets = photosGridView?.selectedAssets, !selectedAssets.isEmpty else { return }
        photosImportButton?.isEnabled = false
        photosStatusLabel?.stringValue = "Importing \(selectedAssets.count) from Photos..."
        PhotosImportStore.importAssets(selectedAssets) { [weak self] urls in
            guard let self else { return }
            if urls.isEmpty {
                self.syncPhotosImportControls(statusMessage: "No Photos assets were imported.")
                NSSound.beep()
            } else {
                self.canvas?.addMediaURLs(urls)
                self.photosGridView?.clearSelection(notify: false)
                self.syncPhotosImportControls(statusMessage: "Imported \(urls.count) into MediaFlow.")
            }
        }
    }

    @MainActor private func syncPhotosImportControls(statusMessage: String? = nil) {
        let assetCount = photosGridView?.assets.count ?? 0
        let selectedCount = photosGridView?.selectedAssets.count ?? 0
        if let statusMessage {
            photosStatusLabel?.stringValue = statusMessage
        } else {
            photosStatusLabel?.stringValue = selectedCount > 0
                ? "\(selectedCount) selected from \(assetCount) recent Photos assets"
                : "\(assetCount) recent Photos assets"
        }
        photosImportButton?.title = selectedCount > 0 ? "Import \(selectedCount) Selected" : "Import Selected"
        photosImportButton?.isEnabled = selectedCount > 0
    }

    @MainActor private func showPhotosAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Photos access is not available."
        alert.informativeText = "Allow MediaFlow to read your Photos library in System Settings, then try Add From Photos again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor @objc private func showFlowPanel() {
        if flowPanel == nil {
            flowPanel = makeFlowPanel()
        }
        syncFlowControls()
        if let window, let flowPanel, !flowPanel.isVisible {
            let x = min(window.frame.maxX - flowPanel.frame.width - 18, max(window.frame.minX + 18, window.frame.minX + 28))
            let y = min(window.frame.maxY - flowPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - flowPanel.frame.height / 2))
            flowPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        flowPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func makeFlowPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 734),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Flow Library"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 340, height: 560)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 340, height: 734))
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView(frame: NSRect(x: 15, y: 38, width: content.bounds.width - 30, height: content.bounds.height - 52))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)

        let header = FlowHeaderCardView()
        header.canvas = canvas
        header.widthAnchor.constraint(equalToConstant: 300).isActive = true
        header.heightAnchor.constraint(equalToConstant: 56).isActive = true
        flowHeaderView = header
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(FlowLibraryStyle.sectionLabel("Layout"))

        let maxStepper = FlowNumberStepper()
        maxStepper.minimumValue = 1
        maxStepper.maximumValue = 64
        maxStepper.stepValue = 1
        maxStepper.target = self
        maxStepper.action = #selector(flowMaxVisibleChanged(_:))
        flowMaxStepper = maxStepper
        stack.addArrangedSubview(flowSettingRow(title: "Max on Screen", subtitle: "Tiles shown at once", trailing: maxStepper))

        stack.addArrangedSubview(flowSeparator())
        stack.addArrangedSubview(FlowLibraryStyle.sectionLabel("Rotation"))

        let modeControl = FlowSegmentedControl()
        modeControl.segments = FlowRotationMode.allCases.map(\.displayName)
        modeControl.target = self
        modeControl.action = #selector(flowModeChanged(_:))
        modeControl.widthAnchor.constraint(equalToConstant: 300).isActive = true
        modeControl.heightAnchor.constraint(equalToConstant: 30).isActive = true
        flowModeControl = modeControl
        stack.addArrangedSubview(modeControl)

        let autoRotate = FlowSwitchControl()
        autoRotate.target = self
        autoRotate.action = #selector(flowAutoRotateChanged(_:))
        flowAutoRotateButton = autoRotate
        stack.addArrangedSubview(flowSettingRow(title: "Auto-Rotate", subtitle: "Cycle slots on a timer", trailing: autoRotate))

        let intervalStepper = FlowNumberStepper()
        intervalStepper.minimumValue = 4
        intervalStepper.maximumValue = 600
        intervalStepper.stepValue = 5
        intervalStepper.suffix = "s"
        intervalStepper.target = self
        intervalStepper.action = #selector(flowIntervalChanged(_:))
        flowIntervalStepper = intervalStepper
        stack.addArrangedSubview(flowSettingRow(title: "Change Every", subtitle: nil, trailing: intervalStepper))

        let duplicates = FlowSwitchControl()
        duplicates.target = self
        duplicates.action = #selector(flowDuplicateChanged(_:))
        duplicates.toolTip = "Random rotation can fill multiple preview slots with the same source item."
        flowDuplicateButton = duplicates
        stack.addArrangedSubview(flowSettingRow(title: "Allow Duplicate Slots", subtitle: "Same clip in multiple tiles", trailing: duplicates))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let shuffleButton = FlowActionButton(title: "Shuffle", symbolName: "shuffle", isAccent: false)
        shuffleButton.target = canvas
        shuffleButton.action = #selector(MetalCollageView.shuffleFlowFromMenu)
        shuffleButton.toolTip = "Shuffle the visible flow set now"
        shuffleButton.widthAnchor.constraint(equalToConstant: 146).isActive = true
        shuffleButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(shuffleButton)
        let nextButton = FlowActionButton(title: "Advance", symbolName: "forward.end.fill", isAccent: true)
        nextButton.target = canvas
        nextButton.action = #selector(MetalCollageView.advanceFlowFromMenu)
        nextButton.toolTip = "Advance to the next flow page now"
        nextButton.widthAnchor.constraint(equalToConstant: 146).isActive = true
        nextButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(nextButton)
        stack.addArrangedSubview(buttonRow)

        stack.addArrangedSubview(flowSeparator())
        let poolHeader = NSStackView()
        poolHeader.orientation = .horizontal
        poolHeader.alignment = .centerY
        poolHeader.spacing = 8
        poolHeader.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let poolLabel = FlowLibraryStyle.sectionLabel("Media Pool")
        poolHeader.addArrangedSubview(poolLabel)
        let spacer = NSView()
        poolHeader.addArrangedSubview(spacer)
        let poolCount = FlowLibraryStyle.secondaryLabel("")
        poolCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        poolCount.alignment = .right
        flowPoolCountLabel = poolCount
        poolHeader.addArrangedSubview(poolCount)
        stack.addArrangedSubview(poolHeader)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 285).isActive = true
        let grid = FlowLibraryGridView(frame: NSRect(x: 0, y: 0, width: 300, height: 285))
        grid.canvas = canvas
        flowGridView = grid
        scroll.documentView = grid
        stack.addArrangedSubview(scroll)

        panel.contentView = content
        return panel
    }

    @MainActor private func flowSettingRow(title: String, subtitle: String?, trailing: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.widthAnchor.constraint(equalToConstant: 206).isActive = true
        textStack.addArrangedSubview(FlowLibraryStyle.primaryLabel(title))
        if let subtitle {
            textStack.addArrangedSubview(FlowLibraryStyle.secondaryLabel(subtitle))
        }
        row.addArrangedSubview(textStack)

        let spacer = NSView()
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(trailing)
        return row
    }

    @MainActor private func flowSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return separator
    }

    @MainActor @objc private func flowMaxVisibleChanged(_ sender: FlowNumberStepper) {
        canvas?.flowMaxVisibleItems = sender.integerValue
    }

    @MainActor @objc private func flowModeChanged(_ sender: FlowSegmentedControl) {
        let rawValue = sender.selectedIndex
        canvas?.flowRotationMode = FlowRotationMode(rawValue: rawValue) ?? .roundRobin
    }

    @MainActor @objc private func flowAutoRotateChanged(_ sender: FlowSwitchControl) {
        canvas?.flowAutoRotateEnabled = sender.isOn
    }

    @MainActor @objc private func flowIntervalChanged(_ sender: FlowNumberStepper) {
        canvas?.flowRotationInterval = sender.doubleValue
    }

    @MainActor @objc private func flowDuplicateChanged(_ sender: FlowSwitchControl) {
        canvas?.flowAllowsRandomDuplicates = sender.isOn
    }

    @MainActor @objc private func syncFlowControls() {
        guard let canvas else { return }
        flowHeaderView?.needsDisplay = true
        flowPoolCountLabel?.stringValue = "\(canvas.items.count)/\(canvas.items.count) enabled"
        flowMaxStepper?.integerValue = canvas.flowMaxVisibleItems
        flowModeControl?.selectedIndex = canvas.flowRotationMode.rawValue
        flowAutoRotateButton?.isOn = canvas.flowAutoRotateEnabled
        flowIntervalStepper?.doubleValue = canvas.flowRotationInterval
        flowDuplicateButton?.isOn = canvas.flowAllowsRandomDuplicates
        flowDuplicateButton?.isEnabled = canvas.flowRotationMode == .random
        flowDuplicateButton?.needsDisplay = true
        flowGridView?.reloadData()
    }

    @MainActor @objc private func showQualityPanel() {
        if qualityPanel == nil {
            qualityPanel = makeQualityPanel()
        }
        syncQualityControls()
        if let window, let qualityPanel, !qualityPanel.isVisible {
            let x = min(window.frame.maxX - qualityPanel.frame.width - 18, max(window.frame.minX + 18, window.frame.midX - qualityPanel.frame.width / 2))
            let y = min(window.frame.maxY - qualityPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - qualityPanel.frame.height / 2))
            qualityPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        qualityPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func makeQualityPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 446),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quality Controls"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 360, height: 446))
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView(frame: content.bounds.insetBy(dx: 16, dy: 14))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)

        let targetLabel = NSTextField(labelWithString: "Target: Defaults for new files")
        targetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.widthAnchor.constraint(equalToConstant: 320).isActive = true
        qualityPanelTargetLabel = targetLabel
        stack.addArrangedSubview(targetLabel)

        let defaultsButton = NSButton(checkboxWithTitle: "Edit Defaults for New Files", target: self, action: #selector(qualityPanelDefaultsChanged(_:)))
        defaultsButton.toolTip = "Edit fallback quality settings used before a file has its own saved hash profile"
        qualityPanelDefaultsButton = defaultsButton
        stack.addArrangedSubview(defaultsButton)

        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in MetalQualityMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
            modePopup.lastItem?.representedObject = mode.rawValue
            modePopup.lastItem?.toolTip = mode.tooltip
        }
        modePopup.target = self
        modePopup.action = #selector(qualityPanelModeChanged(_:))
        modePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        qualityPanelModePopup = modePopup
        stack.addArrangedSubview(controlRow("Sampling", modePopup))

        let frameInterpolation = NSButton(checkboxWithTitle: "Frame Interpolation", target: self, action: #selector(qualityPanelFrameInterpolationChanged(_:)))
        qualityPanelFrameInterpolationButton = frameInterpolation
        stack.addArrangedSubview(frameInterpolation)

        let denoise = NSButton(checkboxWithTitle: "Natural Denoise + Detail", target: self, action: #selector(qualityPanelDenoiseChanged(_:)))
        qualityPanelDenoiseButton = denoise
        stack.addArrangedSubview(denoise)

        let denoiseSlider = NSSlider(value: 0.72, minValue: 0, maxValue: 1, target: self, action: #selector(qualityPanelDenoiseStrengthChanged(_:)))
        denoiseSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let denoiseValue = NSTextField(labelWithString: "72%")
        denoiseValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        denoiseValue.textColor = .secondaryLabelColor
        denoiseValue.alignment = .right
        denoiseValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        qualityPanelDenoiseSlider = denoiseSlider
        qualityPanelDenoiseValue = denoiseValue
        stack.addArrangedSubview(sliderRow("Noise", denoiseSlider, denoiseValue))

        let tone = NSButton(checkboxWithTitle: "Auto Tone / Detail Recovery", target: self, action: #selector(qualityPanelToneChanged(_:)))
        qualityPanelToneButton = tone
        stack.addArrangedSubview(tone)

        let toneSlider = NSSlider(value: 0.58, minValue: 0, maxValue: 1, target: self, action: #selector(qualityPanelToneStrengthChanged(_:)))
        toneSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let toneValue = NSTextField(labelWithString: "58%")
        toneValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        toneValue.textColor = .secondaryLabelColor
        toneValue.alignment = .right
        toneValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        qualityPanelToneSlider = toneSlider
        qualityPanelToneValue = toneValue
        stack.addArrangedSubview(sliderRow("Tone", toneSlider, toneValue))

        let magic = NSButton(checkboxWithTitle: "Magic Rescue", target: self, action: #selector(qualityPanelMagicChanged(_:)))
        magic.toolTip = "Aggressive shadow/highlight rescue, local contrast, vibrance, and sharpening"
        qualityPanelMagicButton = magic
        stack.addArrangedSubview(magic)

        let magicSlider = NSSlider(value: 0.82, minValue: 0, maxValue: 1, target: self, action: #selector(qualityPanelMagicStrengthChanged(_:)))
        magicSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        magicSlider.toolTip = "Magic Rescue strength"
        let magicValue = NSTextField(labelWithString: "82%")
        magicValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        magicValue.textColor = .secondaryLabelColor
        magicValue.alignment = .right
        magicValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        qualityPanelMagicSlider = magicSlider
        qualityPanelMagicValue = magicValue
        stack.addArrangedSubview(sliderRow("Magic", magicSlider, magicValue))

        let split = NSButton(checkboxWithTitle: "Split Compare", target: self, action: #selector(qualityPanelSplitCompareChanged(_:)))
        qualityPanelSplitButton = split
        stack.addArrangedSubview(split)

        let splitReverse = NSButton(checkboxWithTitle: "B/A Compare", target: self, action: #selector(qualityPanelSplitReverseChanged(_:)))
        splitReverse.toolTip = "Swap split compare: B Quality on the left, A Raw on the right"
        qualityPanelSplitReverseButton = splitReverse
        stack.addArrangedSubview(splitReverse)

        let clearProfiles = NSButton(title: "Clear Saved File Profiles...", target: self, action: #selector(clearSavedFileProfilesFromPanel))
        clearProfiles.bezelStyle = .rounded
        clearProfiles.toolTip = "Clear saved per-file quality profiles and A-B histories"
        stack.addArrangedSubview(clearProfiles)

        panel.contentView = content
        if let window {
            let origin = CGPoint(x: window.frame.maxX - 390, y: window.frame.maxY - 380)
            panel.setFrameOrigin(origin)
        }
        return panel
    }

    @MainActor private func controlRow(_ title: String, _ control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        return row
    }

    @MainActor private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    @MainActor @objc private func qualityPanelModeChanged(_ sender: NSPopUpButton) {
        let rawValue = sender.selectedItem?.representedObject as? Int ?? sender.indexOfSelectedItem
        canvas?.setMetalQualityMode(MetalQualityMode(rawValue: rawValue) ?? .best)
    }

    @MainActor @objc private func qualityPanelDefaultsChanged(_ sender: NSButton) {
        canvas?.setQualityEditsDefaults(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelFrameInterpolationChanged(_ sender: NSButton) {
        canvas?.setFrameInterpolationEnabled(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelDenoiseChanged(_ sender: NSButton) {
        canvas?.setNaturalDenoiseEnabled(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelDenoiseStrengthChanged(_ sender: NSSlider) {
        canvas?.setNaturalDenoiseStrength(Float(sender.doubleValue))
    }

    @MainActor @objc private func qualityPanelToneChanged(_ sender: NSButton) {
        canvas?.setToneRecoveryEnabled(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelToneStrengthChanged(_ sender: NSSlider) {
        canvas?.setToneRecoveryStrength(Float(sender.doubleValue))
    }

    @MainActor @objc private func qualityPanelMagicChanged(_ sender: NSButton) {
        canvas?.setMagicRescueMode(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelMagicStrengthChanged(_ sender: NSSlider) {
        canvas?.setMagicRescueStrength(Float(sender.doubleValue))
    }

    @MainActor @objc private func qualityPanelSplitCompareChanged(_ sender: NSButton) {
        canvas?.setSplitCompareEnabled(sender.state == .on)
    }

    @MainActor @objc private func qualityPanelSplitReverseChanged(_ sender: NSButton) {
        canvas?.setSplitCompareReversed(sender.state == .on)
    }

    @MainActor @objc private func clearSavedFileProfilesFromPanel() {
        let alert = NSAlert()
        alert.messageText = "Clear saved file profiles?"
        alert.informativeText = "This clears all per-file quality profiles and A-B histories saved by file hash. Current open files stay loaded."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        canvas?.clearSavedFileProfiles()
        syncQualityControls()
    }

    @MainActor @objc private func syncQualityControls() {
        guard let canvas else { return }
        rebuildQualityMenu()
        qualityPanelTargetLabel?.stringValue = "Target: \(canvas.activeQualityTargetName())"
        qualityPanelDefaultsButton?.state = canvas.isEditingQualityDefaults() ? .on : .off
        qualityPanelDefaultsButton?.isEnabled = canvas.hasQualityTargetItem()
        qualityPanelModePopup?.selectItem(at: canvas.activeMetalQualityMode().rawValue)
        qualityPanelFrameInterpolationButton?.state = canvas.activeFrameInterpolationEnabled() ? .on : .off
        qualityPanelDenoiseButton?.state = canvas.activeNaturalDenoiseEnabled() ? .on : .off
        qualityPanelDenoiseSlider?.doubleValue = Double(canvas.activeNaturalDenoiseStrength())
        qualityPanelDenoiseSlider?.isEnabled = canvas.activeNaturalDenoiseEnabled()
        qualityPanelDenoiseValue?.stringValue = percent(canvas.activeNaturalDenoiseStrength())
        qualityPanelToneButton?.state = canvas.activeToneRecoveryEnabled() ? .on : .off
        qualityPanelToneSlider?.doubleValue = Double(canvas.activeToneRecoveryStrength())
        qualityPanelToneSlider?.isEnabled = canvas.activeToneRecoveryEnabled()
        qualityPanelToneValue?.stringValue = percent(canvas.activeToneRecoveryStrength())
        qualityPanelMagicButton?.state = canvas.activeMagicRescueEnabled() ? .on : .off
        qualityPanelMagicSlider?.doubleValue = Double(canvas.activeMagicRescueStrength())
        qualityPanelMagicSlider?.isEnabled = canvas.activeMagicRescueEnabled()
        qualityPanelMagicValue?.stringValue = percent(canvas.activeMagicRescueStrength())
        qualityPanelSplitButton?.state = canvas.splitCompareEnabled ? .on : .off
        qualityPanelSplitReverseButton?.state = canvas.splitCompareReversed ? .on : .off
        qualityPanelSplitReverseButton?.isEnabled = canvas.splitCompareEnabled
        frameInterpolationMenuItem?.state = canvas.activeFrameInterpolationEnabled() ? .on : .off
        naturalDenoiseMenuItem?.state = canvas.activeNaturalDenoiseEnabled() ? .on : .off
        magicRescueMenuItem?.state = canvas.activeMagicRescueEnabled() ? .on : .off
    }

    @MainActor private func percent(_ value: Float) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }

    @MainActor @objc private func rebuildQualityMenu() {
        qualityMenu.removeAllItems()
        let activeMode = canvas?.activeMetalQualityMode() ?? .best
        for mode in MetalQualityMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setMetalQualityFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = mode.tooltip
            item.state = mode == activeMode ? .on : .off
            qualityMenu.addItem(item)
        }
    }

    @MainActor @objc private func setMetalQualityFromMenu(_ sender: NSMenuItem) {
        let rawValue = sender.representedObject as? Int ?? MetalQualityMode.best.rawValue
        canvas?.setMetalQualityMode(MetalQualityMode(rawValue: rawValue) ?? .best)
        rebuildQualityMenu()
    }

    @MainActor @objc private func toggleFrameInterpolation(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeFrameInterpolationEnabled()
        canvas.setFrameInterpolationEnabled(enabled)
        sender.state = enabled ? .on : .off
        frameInterpolationMenuItem?.state = sender.state
    }

    @MainActor @objc private func toggleNaturalDenoise(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeNaturalDenoiseEnabled()
        canvas.setNaturalDenoiseEnabled(enabled)
        sender.state = enabled ? .on : .off
        naturalDenoiseMenuItem?.state = sender.state
    }

    @MainActor @objc private func toggleMagicRescue(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeMagicRescueEnabled()
        canvas.setMagicRescueMode(enabled)
        sender.state = enabled ? .on : .off
        magicRescueMenuItem?.state = sender.state
    }

    @MainActor @objc private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let urls = RecentPlaybacksStore.urls()
        guard !urls.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Playbacks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for url in urls {
            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = parent.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) - \(parent)"
            let item = NSMenuItem(title: title, action: #selector(openRecentPlayback(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            recentMenu.addItem(item)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent Playbacks", action: #selector(clearRecentPlaybacks), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    @MainActor @objc private func openRecentPlayback(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        canvas?.loadPlayback(from: url, addToRecents: true)
    }

    @MainActor @objc private func clearRecentPlaybacks() {
        RecentPlaybacksStore.clear()
    }

    @MainActor @objc private func toggleHoverTools(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.isHoverToolPanelEnabled
        canvas.setHoverToolPanelEnabled(enabled)
        sender.state = enabled ? .on : .off
        hoverToolsMenuItem?.state = sender.state
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
