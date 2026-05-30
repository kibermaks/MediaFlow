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
    @MainActor @objc func rebuildRecentMenu() {
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

    @MainActor @objc func openRecentPlayback(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        canvas?.loadPlayback(from: url, addToRecents: true)
    }

    @MainActor @objc func clearRecentPlaybacks() {
        RecentPlaybacksStore.clear()
    }

    @MainActor @objc func toggleHoverTools(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.isHoverToolPanelEnabled
        canvas.setHoverToolPanelEnabled(enabled)
        sender.state = enabled ? .on : .off
        hoverToolsMenuItem?.state = sender.state
    }

    @MainActor @objc func toggleDebugInformation(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.debugInformationEnabled
        canvas.setDebugInformationEnabled(enabled)
        sender.state = enabled ? .on : .off
        debugInformationMenuItem?.state = sender.state
    }
}
