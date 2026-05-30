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
    func item(at point: CGPoint) -> CollageItem? {
        visibleSlots.reversed().first { $0.cellRect.contains(point) }?.item
    }

    func updateHover(at point: CGPoint) {
        let next = item(at: point)
        if hoverItem !== next {
            hoverItem = next
            positionToolPanel()
        }
    }

    func positionToolPanel() {
        guard hoverToolPanelEnabled else {
            toolPanel.isHidden = true
            return
        }
        guard let item = hoverItem else {
            toolPanel.isHidden = true
            return
        }
        let cellRect = visibleSlots.first(where: { $0.item === item })?.cellRect ?? item.cellRect
        let size = toolStack.fittingSize
        let panelSize = CGSize(width: size.width + 10, height: size.height + 10)
        toolPanel.frame = CGRect(
            x: min(bounds.maxX - panelSize.width - 8, cellRect.maxX - panelSize.width - 8),
            y: max(bounds.minY + 8, cellRect.maxY - panelSize.height - 8),
            width: panelSize.width,
            height: panelSize.height
        )
        toolStack.frame = toolPanel.bounds
        toolPanel.isHidden = false
    }

    @objc func enlargeHoveredItem() {
        guard let hoverItem else { return }
        resize(item: hoverItem, factor: 1.16)
    }

    @objc func reduceHoveredItem() {
        guard let hoverItem else { return }
        resize(item: hoverItem, factor: 1 / 1.16)
    }

    func keyboardTargetItem() -> CollageItem? {
        if let selected = items.first(where: \.selected) { return selected }
        if let hoverItem { return hoverItem }
        if let lastMousePoint, let item = item(at: lastMousePoint) { return item }
        return items.last
    }

    func resize(item: CollageItem, factor: CGFloat) {
        item.weight = max(0.55, min(2.6, item.weight * factor))
        selectOnly(item)
        relayout()
    }

    @objc func enlargeFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        resize(item: item, factor: 1.16)
    }

    @objc func reduceFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        resize(item: item, factor: 1 / 1.16)
    }

    @objc func zoomInFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        setZoom(for: item, zoom: item.zoom * 1.16, anchor: lastMousePoint)
        selectOnly(item)
    }

    @objc func zoomOutFocusedItem() {
        guard let item = keyboardTargetItem() else { return }
        setZoom(for: item, zoom: item.zoom / 1.16, anchor: lastMousePoint)
        selectOnly(item)
    }

    @objc func togglePanForFocusedItem() {
        guard let item = keyboardTargetItem(), item.canPan else { return }
        selectOnly(item)
        panItem = panItem === item ? nil : item
        overlay.needsDisplay = true
    }

    @objc func zoomInHoveredItem() {
        guard let hoverItem else { return }
        setZoom(for: hoverItem, zoom: hoverItem.zoom * 1.16, anchor: lastMousePoint)
    }

    @objc func zoomOutHoveredItem() {
        guard let hoverItem else { return }
        setZoom(for: hoverItem, zoom: hoverItem.zoom / 1.16, anchor: lastMousePoint)
    }

    @objc func panHoveredItem() {
        guard let hoverItem, hoverItem.canPan else { return }
        panItem = panItem === hoverItem ? nil : hoverItem
        overlay.needsDisplay = true
    }

    @objc func rotateHoveredItemLeft() {
        guard let hoverItem else { return }
        rotate(item: hoverItem, deltaQuarterTurns: -1)
    }

    @objc func rotateHoveredItemRight() {
        guard let hoverItem else { return }
        rotate(item: hoverItem, deltaQuarterTurns: 1)
    }

    @objc func rotateHoveredItemHalfTurn() {
        guard let hoverItem else { return }
        rotate(item: hoverItem, deltaQuarterTurns: 2)
    }

    @objc func rotateFocusedItemLeft() {
        guard let item = keyboardTargetItem() else { return }
        rotate(item: item, deltaQuarterTurns: -1)
    }

    @objc func rotateFocusedItemRight() {
        guard let item = keyboardTargetItem() else { return }
        rotate(item: item, deltaQuarterTurns: 1)
    }

    @objc func rotateFocusedItemHalfTurn() {
        guard let item = keyboardTargetItem() else { return }
        rotate(item: item, deltaQuarterTurns: 2)
    }

    @objc func resetFocusedItemRotation() {
        guard let item = keyboardTargetItem() else { return }
        setRotation(for: item, quarterTurns: 0)
    }

    func rotate(item: CollageItem, deltaQuarterTurns: Int) {
        setRotation(for: item, quarterTurns: item.rotationQuarterTurns + deltaQuarterTurns)
    }

    func setRotation(for item: CollageItem, quarterTurns: Int) {
        let normalized = CollageItem.normalizedRotationQuarterTurns(quarterTurns)
        guard item.rotationQuarterTurns != normalized else { return }
        item.rotationQuarterTurns = normalized
        selectOnly(item)
        relayout()
        postFlowLibraryChanged()
    }

    func setZoom(for item: CollageItem, zoom requestedZoom: CGFloat, anchor: CGPoint? = nil) {
        let oldZoom = item.zoom
        let targetRect = drawRect(for: item)
        let anchorPoint = anchor.map { clamp($0, to: targetRect) } ?? CGPoint(x: targetRect.midX, y: targetRect.midY)
        let localX = max(0, min(1, (anchorPoint.x - targetRect.minX) / max(1, targetRect.width)))
        let localY = max(0, min(1, (anchorPoint.y - targetRect.minY) / max(1, targetRect.height)))
        let before = normalizedSourceRect(for: item, targetAspect: targetRect.width / max(1, targetRect.height))
        let displayAnchor = CGPoint(x: localX, y: 1 - localY)
        let sourceAnchor = item.sourcePoint(fromDisplayNormalizedPoint: displayAnchor)
        let anchorSourceX = before.minX + sourceAnchor.x * before.width
        let anchorSourceY = before.minY + sourceAnchor.y * before.height

        if requestedZoom < 1, item.zoom <= 1.001, item.cropRect != nil {
            expandCrop(
                for: item,
                factor: min(1.4, 1 / max(0.3, requestedZoom)),
                anchorSource: CGPoint(x: anchorSourceX, y: anchorSourceY),
                sourceAnchor: sourceAnchor
            )
            return
        }

        item.zoom = max(1, min(6, requestedZoom))
        let after = normalizedSourceRect(for: item, targetAspect: targetRect.width / max(1, targetRect.height), zoom: item.zoom, pan: .zero)
        let base = item.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let desiredCenterX = anchorSourceX - (sourceAnchor.x - 0.5) * after.width
        let desiredCenterY = anchorSourceY - (sourceAnchor.y - 0.5) * after.height
        let maxOffsetX = max(0, (base.width - after.width) / 2)
        let maxOffsetY = max(0, (base.height - after.height) / 2)

        if maxOffsetX > 0.0001 {
            item.pan.x = max(-1, min(1, (desiredCenterX - base.midX) / maxOffsetX))
        } else {
            item.pan.x = 0
        }
        if maxOffsetY > 0.0001 {
            item.pan.y = max(-1, min(1, (desiredCenterY - base.midY) / maxOffsetY))
        } else {
            item.pan.y = 0
        }

        if item.zoom <= 1.001 {
            item.zoom = 1
            item.pan = .zero
        }
        item.contentRect = contentRect(for: item, cell: item.cellRect)
        if (oldZoom <= 1.001) != (item.zoom <= 1.001) {
            relayout()
        } else {
            needsDisplay = true
        }
        overlay.needsDisplay = true
    }

    func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(rect.maxX, point.x)), y: max(rect.minY, min(rect.maxY, point.y)))
    }

    func normalizedSourceRect(for item: CollageItem, targetAspect: CGFloat, zoom: CGFloat? = nil, pan: CGPoint? = nil) -> CGRect {
        let base = item.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let sourceTargetAspect = item.sourceAspect(forDisplayAspect: targetAspect)
        let sourceAspect = (base.width * item.pixelSize.width) / max(1, base.height * item.pixelSize.height)
        var width = base.width
        var height = base.height

        if sourceAspect > sourceTargetAspect {
            width = base.height * sourceTargetAspect * item.pixelSize.height / max(1, item.pixelSize.width)
        } else {
            height = base.width * item.pixelSize.width / max(1, sourceTargetAspect * item.pixelSize.height)
        }

        let z = max(1, min(6, zoom ?? item.zoom))
        width /= z
        height /= z

        let p = pan ?? item.pan
        let maxOffsetX = max(0, (base.width - width) / 2)
        let maxOffsetY = max(0, (base.height - height) / 2)
        let centerX = min(base.maxX - width / 2, max(base.minX + width / 2, base.midX + p.x * maxOffsetX))
        let centerY = min(base.maxY - height / 2, max(base.minY + height / 2, base.midY + p.y * maxOffsetY))

        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    func expandCrop(for item: CollageItem, factor: CGFloat, anchorSource: CGPoint, sourceAnchor: CGPoint) {
        guard let crop = item.cropRect else { return }
        let width = min(1, crop.width * factor)
        let height = min(1, crop.height * factor)
        var x = anchorSource.x - sourceAnchor.x * width
        var y = anchorSource.y - sourceAnchor.y * height
        x = max(0, min(1 - width, x))
        y = max(0, min(1 - height, y))
        if width >= 0.995, height >= 0.995 {
            item.cropRect = nil
        } else {
            item.cropRect = CGRect(x: x, y: y, width: width, height: height)
        }
        item.zoom = 1
        item.pan = .zero
        relayout()
    }

    func applyCrop(rect rawRect: CGRect, to item: CollageItem) {
        let rect = rawRect.standardized.intersection(item.contentRect)
        guard rect.width >= 12, rect.height >= 12 else { return }
        let content = item.contentRect
        let u0 = (rect.minX - content.minX) / max(1, content.width)
        let u1 = (rect.maxX - content.minX) / max(1, content.width)
        let v0 = (content.maxY - rect.maxY) / max(1, content.height)
        let v1 = (content.maxY - rect.minY) / max(1, content.height)
        item.cropRect = item.sourceRect(fromDisplayNormalizedRect: CGRect(
            x: max(0, min(1, u0)),
            y: max(0, min(1, v0)),
            width: max(0.01, min(1, u1) - max(0, u0)),
            height: max(0.01, min(1, v1) - max(0, v0))
        ))
        item.zoom = 1
        item.pan = .zero
        selectOnly(item)
        relayout()
    }

    func selectOnly(_ item: CollageItem?) {
        items.forEach { $0.selected = $0 === item }
        overlay.needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        positionVideoPanel()
        tickVideoUI()
    }

    func clearSelection() {
        items.forEach { $0.selected = false }
        panItem = nil
        temporaryPanItem = nil
        pendingSelectionToggleItem = nil
        didPanDragItem = false
        cropMode = false
        activeCropRect = nil
        overlay.needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        positionVideoPanel()
    }

}
