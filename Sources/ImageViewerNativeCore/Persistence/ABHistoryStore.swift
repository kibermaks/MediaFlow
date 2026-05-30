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

enum ABHistoryStore {
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
