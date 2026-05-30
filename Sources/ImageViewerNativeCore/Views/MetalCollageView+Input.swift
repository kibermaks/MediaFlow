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

    func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
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
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
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
        if !commandDown, event.keyCode == 33 {
            rotateFocusedItemLeft()
            return true
        }
        if !commandDown, event.keyCode == 30 {
            rotateFocusedItemRight()
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
                        resumePlayback(for: item)
                    }
                }
            }
            isPaused = shouldPause || !items.contains { $0.kind == .video }
            return true
        }
        return false
    }

    func restoreWindowIfExpanded() -> Bool {
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
