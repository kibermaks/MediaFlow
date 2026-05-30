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
    func setHoverToolPanelEnabled(_ enabled: Bool) {
        hoverToolPanelEnabled = enabled
        if !enabled {
            toolPanel.isHidden = true
        } else {
            positionToolPanel()
        }
    }

    var isHoverToolPanelEnabled: Bool {
        hoverToolPanelEnabled
    }

    var flowStatusText: String {
        let visibleCount = visibleSlots.count
        let loadedCount = items.count
        let mode = flowRotationMode.displayName
        let interval = Int(flowRotationInterval.rounded())
        let suffix = flowAutoRotateEnabled ? "Every \(interval)s" : "Manual"
        return "\(loadedCount) loaded - \(visibleCount) on screen - \(mode) - \(suffix)"
    }

    func visibleIndexCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for index in flowVisibleIndexes where items.indices.contains(index) {
            counts[index, default: 0] += 1
        }
        return counts
    }

    func selectedLibraryIndex() -> Int? {
        guard let selected = items.first(where: \.selected) else { return nil }
        return items.firstIndex(of: selected)
    }

    func selectLibraryItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectOnly(items[index])
    }

    func revealLibraryItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectOnly(items[index])
        if !flowVisibleIndexes.contains(index) {
            flowCursor = index
            flowVisibleIndexes = makeFlowIndexes(including: index)
            relayout()
            postFlowLibraryChanged()
        }
    }

    @objc func advanceFlowFromMenu() {
        advanceFlow()
    }

    @objc func shuffleFlowFromMenu() {
        shuffleFlow()
    }

    func advanceFlow() {
        guard !items.isEmpty else { return }
        switch flowRotationMode {
        case .roundRobin:
            let step = max(1, flowTargetSlotCount())
            flowCursor = (flowCursor + step) % max(1, items.count)
        case .random:
            break
        }
        flowVisibleIndexes = makeFlowIndexes()
        relayout()
        postFlowLibraryChanged()
    }

    func shuffleFlow() {
        guard !items.isEmpty else { return }
        let allowsDuplicates = flowRotationMode == .random && flowAllowsRandomDuplicates
        flowVisibleIndexes = makeRandomFlowIndexes(allowsDuplicates: allowsDuplicates)
        if let firstIndex = flowVisibleIndexes.first {
            flowCursor = (firstIndex + max(1, flowTargetSlotCount())) % max(1, items.count)
        }
        relayout()
        postFlowLibraryChanged()
    }

    func postFlowLibraryChanged() {
        NotificationCenter.default.post(name: .flowLibraryChanged, object: self)
    }

    func postFlowSettingsChanged() {
        NotificationCenter.default.post(name: .flowSettingsChanged, object: self)
        postFlowLibraryChanged()
    }

    func restartFlowTimer() {
        flowTimer?.invalidate()
        flowTimer = nil
        guard flowAutoRotateEnabled else { return }
        flowTimer = Timer.scheduledTimer(withTimeInterval: flowRotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.flowCanRotate else { return }
                self.advanceFlow()
            }
        }
    }

    var flowCanRotate: Bool {
        guard !items.isEmpty else { return false }
        if flowRotationMode == .random && flowAllowsRandomDuplicates {
            return flowMaxVisibleItems > 1 || items.count > 1
        }
        return items.count > flowTargetSlotCount()
    }

    func resetFlowSelection() {
        if items.isEmpty {
            flowVisibleIndexes.removeAll()
            visibleSlots.removeAll()
        } else {
            flowCursor = min(flowCursor, max(0, items.count - 1))
            flowVisibleIndexes = makeFlowIndexes()
        }
        relayout()
        postFlowLibraryChanged()
    }

    func normalizeFlowSelection() {
        flowVisibleIndexes = flowVisibleIndexes.filter { items.indices.contains($0) }
        let targetCount = flowTargetSlotCount()
        guard targetCount > 0 else {
            flowVisibleIndexes.removeAll()
            return
        }
        if flowVisibleIndexes.count != targetCount || flowVisibleIndexes.isEmpty {
            flowVisibleIndexes = makeFlowIndexes()
        }
    }

    func flowTargetSlotCount() -> Int {
        guard !items.isEmpty else { return 0 }
        if flowRotationMode == .random && flowAllowsRandomDuplicates {
            return flowMaxVisibleItems
        }
        return min(flowMaxVisibleItems, items.count)
    }

    func makeFlowIndexes(including requiredIndex: Int? = nil) -> [Int] {
        guard !items.isEmpty else { return [] }
        let count = flowTargetSlotCount()
        guard count > 0 else { return [] }

        switch flowRotationMode {
        case .roundRobin:
            let start = requiredIndex ?? flowCursor
            return (0..<count).map { offset in
                (start + offset) % items.count
            }
        case .random:
            return makeRandomFlowIndexes(including: requiredIndex, allowsDuplicates: flowAllowsRandomDuplicates)
        }
    }

    func makeRandomFlowIndexes(including requiredIndex: Int? = nil, allowsDuplicates: Bool) -> [Int] {
        guard !items.isEmpty else { return [] }
        let count = allowsDuplicates ? max(1, flowMaxVisibleItems) : min(max(1, flowMaxVisibleItems), items.count)
        if allowsDuplicates {
            var indexes: [Int] = []
            if let requiredIndex, items.indices.contains(requiredIndex) {
                indexes.append(requiredIndex)
            }
            while indexes.count < count {
                indexes.append(Int.random(in: 0..<items.count))
            }
            return indexes
        }

        var pool = Array(items.indices).shuffled()
        if let requiredIndex, items.indices.contains(requiredIndex) {
            pool.removeAll { $0 == requiredIndex }
            pool.insert(requiredIndex, at: 0)
        }
        return Array(pool.prefix(count))
    }

    func savedFlowSettings() -> SavedFlowSettings {
        SavedFlowSettings(
            maxVisibleItems: flowMaxVisibleItems,
            rotationMode: flowRotationMode,
            allowsRandomDuplicates: flowAllowsRandomDuplicates,
            autoRotateEnabled: flowAutoRotateEnabled,
            rotationInterval: flowRotationInterval
        )
    }

    func applySavedFlowSettings(_ settings: SavedFlowSettings?) {
        guard let settings else { return }
        flowMaxVisibleItems = settings.maxVisibleItems
        flowRotationMode = settings.rotationMode
        flowAllowsRandomDuplicates = settings.allowsRandomDuplicates
        flowAutoRotateEnabled = settings.autoRotateEnabled
        flowRotationInterval = settings.rotationInterval
    }

}
