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

extension AppDelegate {
    @MainActor func makeMainMenu() -> NSMenu {
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
        let debugInformation = viewMenu.addItem(withTitle: "Debug Information", action: #selector(toggleDebugInformation(_:)), keyEquivalent: "")
        debugInformation.target = self
        debugInformation.state = canvas?.debugInformationEnabled == true ? .on : .off
        debugInformation.toolTip = "Show render FPS and MediaFlow CPU usage"
        debugInformationMenuItem = debugInformation
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
        itemMenu.addItem(.separator())
        let rotateLeft = itemMenu.addItem(withTitle: "Rotate Left", action: #selector(MetalCollageView.rotateFocusedItemLeft), keyEquivalent: "[")
        rotateLeft.keyEquivalentModifierMask = []
        let rotateHalfTurn = itemMenu.addItem(withTitle: "Rotate 180", action: #selector(MetalCollageView.rotateFocusedItemHalfTurn), keyEquivalent: "r")
        rotateHalfTurn.keyEquivalentModifierMask = []
        let rotateRight = itemMenu.addItem(withTitle: "Rotate Right", action: #selector(MetalCollageView.rotateFocusedItemRight), keyEquivalent: "]")
        rotateRight.keyEquivalentModifierMask = []
        itemMenu.addItem(withTitle: "Reset Rotation", action: #selector(MetalCollageView.resetFocusedItemRotation), keyEquivalent: "")
        itemMenuItem.submenu = itemMenu
        main.addItem(itemMenuItem)

        return main
    }

    @MainActor @objc func checkForUpdatesFromMenu() {
        updateService.userInitiatedCheck()
    }

}
