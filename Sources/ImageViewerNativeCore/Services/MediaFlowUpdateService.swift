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
final class MediaFlowUpdateService {
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
}
