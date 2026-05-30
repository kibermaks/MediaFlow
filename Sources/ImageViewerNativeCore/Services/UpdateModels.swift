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

struct MediaFlowUpdateInfo: Sendable {
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

enum MediaFlowUpdatePhase: Sendable {
    case preparing
    case downloading
    case extracting
    case installing
    case relaunching
}

extension MediaFlowUpdateService {
    struct GitHubRelease: Decodable, Sendable {
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

    enum UpdateError: LocalizedError {
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

    enum InstallationError: LocalizedError {
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
