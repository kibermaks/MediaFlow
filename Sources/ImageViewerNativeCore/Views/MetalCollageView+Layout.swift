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
    override func layout() {
        super.layout()
        relayout()
        positionToolPanel()
        positionVideoPanel()
    }

    func positionVideoPanel() {
        let selectedVideo = selectedVideoItem()
        videoPanel.isHidden = selectedVideo == nil
        timelineView.item = selectedVideo
        guard selectedVideo != nil else { return }
        let size = videoStack.fittingSize
        let width = min(max(size.width + 20, 760), bounds.width - 24)
        let height = max(54, size.height + 18)
        videoPanel.frame = CGRect(x: bounds.midX - width / 2, y: 14, width: width, height: height)
        videoStack.frame = videoPanel.bounds
    }

    func relayout() {
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard !items.isEmpty else {
            visibleSlots.removeAll()
            syncDisplayColorState()
            needsDisplay = true
            overlay.needsDisplay = true
            return
        }

        normalizeFlowSelection()
        let layoutItems = flowVisibleIndexes.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
        guard !layoutItems.isEmpty else {
            visibleSlots.removeAll()
            needsDisplay = true
            overlay.needsDisplay = true
            return
        }

        let candidate = bestLayout(in: bounds.size, items: layoutItems)
        visibleSlots = []
        for item in items {
            item.cellRect = .zero
            item.contentRect = .zero
        }
        for (index, rect) in candidate.rects.enumerated() {
            let item = layoutItems[index]
            let content = contentRect(for: item, cell: rect)
            visibleSlots.append(FlowSlot(item: item, cellRect: rect, contentRect: content))
            if item.cellRect == .zero {
                item.cellRect = rect
                item.contentRect = content
            }
        }
        applyFlowVisibilityPlayback()
        syncDisplayColorState()
        needsDisplay = true
        overlay.needsDisplay = true
        positionToolPanel()
        positionVideoPanel()
    }

    func applyFlowVisibilityPlayback() {
        let visibleIDs = Set(visibleSlots.map { $0.item.id })
        for item in items where item.kind == .video {
            if visibleIDs.contains(item.id) {
                if item.playWhenVisible && !isPaused && !item.isVideoPlaying {
                    resumePlayback(for: item)
                }
            } else if item.isVideoPlaying {
                item.player?.pause()
            }
        }
        applyAllAudioStates()
    }

    func selectedVideoItem() -> CollageItem? {
        items.first { $0.selected && $0.kind == .video }
    }

    func keyboardVideoTarget() -> CollageItem? {
        if let hoverItem, hoverItem.kind == .video {
            return hoverItem
        }
        if let lastMousePoint, let item = item(at: lastMousePoint), item.kind == .video {
            return item
        }
        return selectedVideoItem()
    }

    func seekVideo(_ item: CollageItem, delta: Double, preservePlayback: Bool = true) {
        guard item.durationSeconds > 0 else { return }
        suspendABLoop(for: item, seconds: 5)
        let target = max(0, min(item.durationSeconds, item.currentTimeSeconds + delta))
        let player = item.player
        let wasPlaying = item.isVideoPlaying
        let rate = item.playbackRate
        if wasPlaying && !preservePlayback {
            item.playWhenVisible = false
            player?.pause()
        }
        resetVideoFrameHistory(for: item)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            guard wasPlaying && preservePlayback else { return }
            player?.rate = rate
        }
        if wasPlaying && preservePlayback {
            resumePlayback(for: item)
        }
        selectOnly(item)
        tickVideoUI()
    }

    func resetVideoFrameHistory(for item: CollageItem) {
        item.resetVideoFrameHistory()
    }

    func adjustVideoSpeed(_ item: CollageItem, delta: Float) {
        selectOnly(item)
        setSpeed(for: item, speed: max(0.1, min(8, item.speed + delta)))
    }

    func drawRect(for slot: FlowSlot) -> CGRect {
        if slot.item.cropRect != nil || slot.item.zoom > 1.001 {
            return slot.cellRect
        }
        return slot.contentRect
    }

    func drawRect(for item: CollageItem) -> CGRect {
        if let slot = visibleSlots.first(where: { $0.item === item }) {
            return drawRect(for: slot)
        }
        if item.cropRect != nil || item.zoom > 1.001 {
            return item.cellRect
        }
        return item.contentRect
    }

    func contentRect(for item: CollageItem, cell: CGRect) -> CGRect {
        if item.cropRect != nil || item.zoom > 1.001 { return cell }
        return fitAspect(item.visibleAspect, inside: cell)
    }

    func fitAspect(_ aspect: CGFloat, inside rect: CGRect) -> CGRect {
        let cellAspect = rect.width / max(1, rect.height)
        if cellAspect > aspect {
            let width = rect.height * aspect
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / aspect
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    func bestLayout(in size: CGSize, items layoutItems: [CollageItem]) -> (rects: [CGRect], score: CGFloat) {
        var best: (rects: [CGRect], score: CGFloat)?
        for order in layoutOrders(items: layoutItems) {
            var rects = Array(repeating: CGRect.zero, count: layoutItems.count)
            masonry(indices: order, in: bounds, rects: &rects, items: layoutItems)
            let score = layoutScore(rects: rects, items: layoutItems, canvasSize: size)
            if best == nil || score > best!.score {
                best = (rects, score)
            }
        }
        return best ?? (Array(repeating: bounds, count: layoutItems.count), 0)
    }

    func layoutOrders(items layoutItems: [CollageItem]) -> [[Int]] {
        let base = Array(layoutItems.indices)
        var orders: [[Int]] = [base]
        let byArea = base.sorted { areaWeight(for: layoutItems[$0]) > areaWeight(for: layoutItems[$1]) }
        let byAspectWide = base.sorted { layoutItems[$0].visibleAspect > layoutItems[$1].visibleAspect }
        let byAspectTall = byAspectWide.reversed()
        orders.append(byArea)
        orders.append(Array(byArea.reversed()))
        orders.append(byAspectWide)
        orders.append(Array(byAspectTall))

        let interleavedAspect = interleaveExtremes(byAspectWide)
        orders.append(interleavedAspect)
        orders.append(Array(interleavedAspect.reversed()))

        let interleavedArea = interleaveExtremes(byArea)
        orders.append(interleavedArea)
        orders.append(Array(interleavedArea.reversed()))

        var unique: [[Int]] = []
        var seen = Set<String>()
        for order in orders {
            let key = order.map(String.init).joined(separator: ",")
            if seen.insert(key).inserted { unique.append(order) }
        }
        return unique
    }

    func interleaveExtremes(_ order: [Int]) -> [Int] {
        var result: [Int] = []
        var left = 0
        var right = order.count - 1
        while left <= right {
            result.append(order[left])
            if left != right { result.append(order[right]) }
            left += 1
            right -= 1
        }
        return result
    }

    func layoutScore(rects: [CGRect], items layoutItems: [CollageItem], canvasSize: CGSize) -> CGFloat {
        var visibleArea: CGFloat = 0
        var totalArea: CGFloat = 0
        var minSidePenalty: CGFloat = 0
        var shapePenalty: CGFloat = 0
        for index in layoutItems.indices {
            let cell = rects[index]
            let item = layoutItems[index]
            let area = cell.width * cell.height
            totalArea += area
            if item.cropRect != nil || item.zoom > 1.001 {
                visibleArea += area
            } else {
                let cellAspect = cell.width / max(1, cell.height)
                let util = min(cellAspect / item.visibleAspect, item.visibleAspect / cellAspect)
                visibleArea += area * max(0, min(1, util))
                shapePenalty += abs(log(max(0.05, cellAspect / max(0.05, item.visibleAspect)))) * 0.015
            }
            let minSide = min(cell.width, cell.height)
            if minSide < 70 {
                minSidePenalty += (70 - minSide) / 70 * 0.08
            }
        }
        let utilization = visibleArea / max(1, totalArea)
        return utilization - minSidePenalty - shapePenalty
    }

    func masonry(indices: [Int], in rect: CGRect, rects: inout [CGRect], items layoutItems: [CollageItem]) {
        guard !indices.isEmpty else { return }
        let gap: CGFloat = bounds.width < 720 ? 3 : 6
        if indices.count == 1 {
            rects[indices[0]] = rect.integral
            return
        }

        let totalWeight = indices.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
        var best: (split: Int, vertical: Bool, score: CGFloat)?

        for split in 1..<indices.count {
            let left = Array(indices[..<split])
            let right = Array(indices[split...])
            let leftWeight = left.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
            let fraction = max(0.12, min(0.88, leftWeight / max(0.001, totalWeight)))

            let verticalWidth = rect.width * fraction
            let verticalLeft = CGRect(x: rect.minX, y: rect.minY, width: verticalWidth - gap / 2, height: rect.height)
            let verticalRight = CGRect(x: rect.minX + verticalWidth + gap / 2, y: rect.minY, width: rect.width - verticalWidth - gap / 2, height: rect.height)
            let verticalScore = groupScore(left, in: verticalLeft, items: layoutItems) + groupScore(right, in: verticalRight, items: layoutItems)

            if best == nil || verticalScore < best!.score {
                best = (split, true, verticalScore)
            }

            let horizontalHeight = rect.height * fraction
            let bottom = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: horizontalHeight - gap / 2)
            let top = CGRect(x: rect.minX, y: rect.minY + horizontalHeight + gap / 2, width: rect.width, height: rect.height - horizontalHeight - gap / 2)
            let horizontalScore = groupScore(left, in: bottom, items: layoutItems) + groupScore(right, in: top, items: layoutItems)

            if best == nil || horizontalScore < best!.score {
                best = (split, false, horizontalScore)
            }
        }

        guard let best else { return }
        let left = Array(indices[..<best.split])
        let right = Array(indices[best.split...])
        let leftWeight = left.reduce(CGFloat(0)) { $0 + areaWeight(for: layoutItems[$1]) }
        let fraction = max(0.12, min(0.88, leftWeight / max(0.001, totalWeight)))

        if best.vertical {
            let leftWidth = rect.width * fraction
            masonry(indices: left, in: CGRect(x: rect.minX, y: rect.minY, width: max(1, leftWidth - gap / 2), height: rect.height), rects: &rects, items: layoutItems)
            masonry(indices: right, in: CGRect(x: rect.minX + leftWidth + gap / 2, y: rect.minY, width: max(1, rect.width - leftWidth - gap / 2), height: rect.height), rects: &rects, items: layoutItems)
        } else {
            let bottomHeight = rect.height * fraction
            masonry(indices: left, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, bottomHeight - gap / 2)), rects: &rects, items: layoutItems)
            masonry(indices: right, in: CGRect(x: rect.minX, y: rect.minY + bottomHeight + gap / 2, width: rect.width, height: max(1, rect.height - bottomHeight - gap / 2)), rects: &rects, items: layoutItems)
        }
    }

    func areaWeight(for item: CollageItem) -> CGFloat {
        max(0.2, min(4, item.weight * sqrt(max(0.2, min(5, item.visibleAspect)))))
    }

    func groupScore(_ indices: [Int], in rect: CGRect, items layoutItems: [CollageItem]) -> CGFloat {
        guard rect.width > 1, rect.height > 1 else { return 1000 }
        let rectAspect = rect.width / rect.height
        let desired = desiredAspect(for: indices, items: layoutItems)
        let shapePenalty = abs(log(max(0.05, rectAspect / max(0.05, desired))))
        let smallPenalty: CGFloat = min(rect.width, rect.height) < 56 ? 8 : 0
        return shapePenalty + smallPenalty + CGFloat(indices.count) * 0.015
    }

    func desiredAspect(for indices: [Int], items layoutItems: [CollageItem]) -> CGFloat {
        guard !indices.isEmpty else { return 1 }
        if indices.count == 1 { return layoutItems[indices[0]].visibleAspect }
        let aspects = indices.map { max(0.12, min(10, layoutItems[$0].visibleAspect)) }
        let geometricMean = exp(aspects.map { log($0) }.reduce(0, +) / CGFloat(aspects.count))
        return max(0.2, min(5, geometricMean))
    }

    func layout(rowCount: Int, size: CGSize) -> (rects: [CGRect], score: CGFloat) {
        let aspects = items.map(\.packingAspect)
        let totalAspect = aspects.reduce(0, +)
        let target = totalAspect / CGFloat(rowCount)
        var rows = Array(repeating: [Int](), count: rowCount)
        var rowSums = Array(repeating: CGFloat(0), count: rowCount)
        var index = 0

        for row in 0..<rowCount {
            let isLast = row == rowCount - 1
            let remainingRows = rowCount - row - 1
            while index < items.count {
                let remainingItems = items.count - index
                if !isLast, remainingItems <= remainingRows, !rows[row].isEmpty { break }
                rows[row].append(index)
                rowSums[row] += aspects[index]
                index += 1
                if !isLast, rowSums[row] >= target, items.count - index >= remainingRows { break }
            }
        }

        let naturalHeights = rowSums.map { size.width / max(0.1, $0) }
        let totalNaturalHeight = naturalHeights.reduce(0, +)
        let scaleY = size.height / max(1, totalNaturalHeight)
        let gap: CGFloat = size.width < 720 ? 3 : 6
        var rects = Array(repeating: CGRect.zero, count: items.count)
        var y: CGFloat = 0
        var visibleArea: CGFloat = 0
        var totalCellArea: CGFloat = 0

        for rowIndex in rows.indices {
            let rowHeight = naturalHeights[rowIndex] * scaleY
            var x: CGFloat = 0
            for itemIndexInRow in rows[rowIndex].indices {
                let itemIndex = rows[rowIndex][itemIndexInRow]
                let naturalWidth = aspects[itemIndex] * naturalHeights[rowIndex]
                let leftGap = itemIndexInRow == 0 ? 0 : gap / 2
                let rightGap = itemIndexInRow == rows[rowIndex].count - 1 ? 0 : gap / 2
                let bottomGap = rowIndex == 0 ? 0 : gap / 2
                let topGap = rowIndex == rows.count - 1 ? 0 : gap / 2
                let cell = CGRect(
                    x: x + leftGap,
                    y: y + bottomGap,
                    width: max(1, naturalWidth - leftGap - rightGap),
                    height: max(1, rowHeight - bottomGap - topGap)
                )
                rects[itemIndex] = cell

                let item = items[itemIndex]
                let util: CGFloat
                if item.cropRect != nil || item.zoom > 1.001 {
                    util = 1
                } else {
                    let cellAspect = cell.width / max(1, cell.height)
                    let contentAspect = item.visibleAspect
                    util = min(cellAspect / contentAspect, contentAspect / cellAspect)
                }
                let area = cell.width * cell.height
                visibleArea += area * max(0, min(1, util))
                totalCellArea += area
                x += naturalWidth
            }
            y += rowHeight
        }

        let utilization = visibleArea / max(1, totalCellArea)
        let scalePenalty = abs(log(max(0.05, scaleY))) * 0.035
        let tinyRowPenalty = rows.reduce(CGFloat(0)) { partial, row in
            guard let first = row.first else { return partial + 1 }
            let ratio = rects[first].height / min(size.width, size.height)
            return partial + (ratio < 0.08 ? (0.08 - ratio) * 2 : 0)
        }
        return (rects, utilization - scalePenalty - tinyRowPenalty)
    }

}
