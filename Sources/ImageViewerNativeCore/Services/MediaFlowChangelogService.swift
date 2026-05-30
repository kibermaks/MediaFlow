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
import Combine

struct MediaFlowChangelogEntry: Equatable, Sendable {
    let version: String
    let date: String
    let sections: [Section]

    struct Section: Equatable, Sendable {
        let category: String
        let items: [String]
    }
}

@MainActor
final class MediaFlowChangelogService: ObservableObject {
    static let shared = MediaFlowChangelogService()

    @Published private(set) var entries: [MediaFlowChangelogEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasFetched = false

    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    init() {
        entries = Self.parse(loadBundledOrCachedMarkdown())
    }

    func fetchIfNeeded() {
        guard !hasFetched, !isLoading else { return }
        Task { await fetch() }
    }

    func fetch() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasFetched = true
        }

        guard let markdown = await fetchRemoteMarkdown() else { return }
        entries = Self.parse(markdown)
    }

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

    nonisolated static func parse(_ markdown: String) -> [MediaFlowChangelogEntry] {
        var results: [MediaFlowChangelogEntry] = []
        let lines = markdown.components(separatedBy: "\n")

        var currentVersion: String?
        var currentDate = ""
        var currentSections: [MediaFlowChangelogEntry.Section] = []
        var currentCategory: String?
        var currentItems: [String] = []

        func flushCategory() {
            if let category = currentCategory, !currentItems.isEmpty {
                currentSections.append(.init(category: category, items: currentItems))
            }
            currentCategory = nil
            currentItems = []
        }

        func flushVersion() {
            flushCategory()
            if let version = currentVersion, !currentSections.isEmpty {
                results.append(MediaFlowChangelogEntry(version: version, date: currentDate, sections: currentSections))
            }
            currentVersion = nil
            currentDate = ""
            currentSections = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## [") {
                flushVersion()
                let stripped = trimmed.dropFirst(4)
                let parts = stripped.split(separator: "]", maxSplits: 1)
                if let versionPart = parts.first {
                    currentVersion = String(versionPart)
                }
                if parts.count > 1 {
                    let datePart = parts[1].trimmingCharacters(in: .whitespaces)
                    if datePart.hasPrefix("- ") {
                        currentDate = String(datePart.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }
                }
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushCategory()
                currentCategory = String(trimmed.dropFirst(4))
                continue
            }

            if trimmed.hasPrefix("- "), currentCategory != nil {
                currentItems.append(String(trimmed.dropFirst(2)))
                continue
            }

            if trimmed == "---" {
                break
            }
        }

        flushVersion()
        return results
    }

    @MainActor static var currentVersion: String {
        AppMetadata.shortVersion
    }

    nonisolated static func compareVersion(lhs: String, rhs: String) -> ComparisonResult {
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

    nonisolated private static func versionComponents(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }
}
