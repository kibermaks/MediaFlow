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

extension MetalCollageView {
    func replacePlayback(withMediaURLs urls: [URL]) {
        resetSceneForNewPlayback()
        loadMedia(urls: urls)
    }

    func resetSceneForNewPlayback() {
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

    func clearABHistoryForClosingItems(_ closingItems: [CollageItem]) {
        for item in closingItems where item.kind == .video && item.abLoops.isEmpty {
            ABHistoryStore.clearHistory(for: item)
        }
    }

}
