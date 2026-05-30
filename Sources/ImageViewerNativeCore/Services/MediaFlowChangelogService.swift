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

@MainActor
final class MediaFlowChangelogService {
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
