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
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var window: NSWindow?
    weak var canvas: MetalCollageView?
    var pendingExternalOpenURLs: [URL] = []
    var qualityPanel: NSPanel?
    var qualityPanelTargetLabel: NSTextField?
    var qualityPanelDefaultsButton: FlowSwitchControl?
    var qualityPanelModeControl: FlowSegmentedControl?
    var qualityPanelFrameInterpolationButton: FlowSwitchControl?
    var qualityPanelDenoiseButton: FlowSwitchControl?
    var qualityPanelDenoiseSlider: FlowSliderControl?
    var qualityPanelDenoiseValue: NSTextField?
    var qualityPanelToneButton: FlowSwitchControl?
    var qualityPanelToneSlider: FlowSliderControl?
    var qualityPanelToneValue: NSTextField?
    var qualityPanelBrightnessSlider: FlowSliderControl?
    var qualityPanelBrightnessValue: NSTextField?
    var qualityPanelMagicButton: FlowSwitchControl?
    var qualityPanelMagicSlider: FlowSliderControl?
    var qualityPanelMagicValue: NSTextField?
    var qualityPanelSplitButton: FlowSwitchControl?
    var qualityPanelSplitReverseButton: FlowSwitchControl?
    var flowPanel: NSPanel?
    var flowGridView: FlowLibraryGridView?
    var flowHeaderView: FlowHeaderCardView?
    var flowPoolCountLabel: NSTextField?
    var flowMaxStepper: FlowNumberStepper?
    var flowModeControl: FlowSegmentedControl?
    var flowAutoRotateButton: FlowSwitchControl?
    var flowIntervalStepper: FlowNumberStepper?
    var flowDuplicateButton: FlowSwitchControl?
    var photosPanel: NSPanel?
    var photosCollectionsView: PhotosImportCollectionsView?
    var photosGridView: PhotosImportGridView?
    var photosHeaderView: PhotosImportHeaderView?
    var photosImportButton: FlowActionButton?
    var photosRefreshButton: FlowActionButton?
    var photosImportInProgress = false
    let updateService = MediaFlowUpdateService()
    var checkForUpdatesMenuItem: NSMenuItem?
    var aboutWindow: NSWindow?
    var changelogWindow: NSWindow?
    var changelogTextView: NSTextView?
    var installStatusPanel: NSPanel?
    var installStatusLabel: NSTextField?
    let recentMenu = NSMenu(title: "Recent Playbacks")
    let qualityMenu = NSMenu(title: "Metal Quality")
    var frameInterpolationMenuItem: NSMenuItem?
    var naturalDenoiseMenuItem: NSMenuItem?
    var magicRescueMenuItem: NSMenuItem?
    var hoverToolsMenuItem: NSMenuItem?
    var debugInformationMenuItem: NSMenuItem?
    var shortcutMonitor: Any?

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
        window.appearance = NSAppearance(named: .darkAqua)
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

    @MainActor func openPendingExternalURLsIfNeeded() {
        guard !pendingExternalOpenURLs.isEmpty else { return }
        let urls = pendingExternalOpenURLs
        pendingExternalOpenURLs.removeAll()
        openExternalMediaURLs(urls)
    }

    @MainActor func openExternalMediaURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let canvas else {
            pendingExternalOpenURLs.append(contentsOf: urls)
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        canvas.replacePlayback(withMediaURLs: urls)
    }

    @MainActor func configureUpdateService() {
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
}
