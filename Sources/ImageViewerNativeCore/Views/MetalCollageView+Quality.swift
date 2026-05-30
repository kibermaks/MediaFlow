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
    func setQualityEditsDefaults(_ enabled: Bool) {
        qualityEditsDefaults = enabled
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
    }

    func isEditingQualityDefaults() -> Bool {
        qualityEditsDefaults || qualityTargetItemIgnoringDefaults() == nil
    }

    func hasQualityTargetItem() -> Bool {
        qualityTargetItemIgnoringDefaults() != nil
    }

    func qualityTargetItemIgnoringDefaults() -> CollageItem? {
        if let selected = items.first(where: \.selected) { return selected }
        if let hoverItem { return hoverItem }
        if let lastMousePoint, let item = item(at: lastMousePoint) { return item }
        return items.last
    }

    func qualityTargetItem() -> CollageItem? {
        qualityEditsDefaults ? nil : qualityTargetItemIgnoringDefaults()
    }

    func activeMetalQualityMode() -> MetalQualityMode {
        guard let item = qualityTargetItem() else { return metalQualityMode }
        return MetalQualityMode(rawValue: item.qualityModeRaw) ?? .best
    }

    func activeFrameInterpolationEnabled() -> Bool {
        qualityTargetItem()?.frameInterpolationEnabled ?? frameInterpolationEnabled
    }

    func activeNaturalDenoiseEnabled() -> Bool {
        qualityTargetItem()?.naturalDenoiseEnabled ?? naturalDenoiseEnabled
    }

    func activeNaturalDenoiseStrength() -> Float {
        qualityTargetItem()?.naturalDenoiseStrength ?? naturalDenoiseStrength
    }

    func activeToneRecoveryEnabled() -> Bool {
        qualityTargetItem()?.toneRecoveryEnabled ?? toneRecoveryEnabled
    }

    func activeToneRecoveryStrength() -> Float {
        qualityTargetItem()?.toneRecoveryStrength ?? toneRecoveryStrength
    }

    func activeBrightnessBoost() -> Float {
        qualityTargetItem()?.brightnessBoost ?? brightnessBoost
    }

    func activeMagicRescueEnabled() -> Bool {
        qualityTargetItem()?.magicRescueEnabled ?? magicRescueEnabled
    }

    func activeMagicRescueStrength() -> Float {
        qualityTargetItem()?.magicRescueStrength ?? magicRescueStrength
    }

    func activeQualityTargetName() -> String {
        isEditingQualityDefaults() ? "Defaults for new files" : (qualityTargetItem()?.name ?? "Defaults for new files")
    }

    func persistQualitySettings(for item: CollageItem) {
        ensureFileHash(for: item)
        QualityProfileStore.saveProfile(for: item)
        needsDisplay = true
        NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
    }

    func setMetalQualityMode(_ mode: MetalQualityMode) {
        if let item = qualityTargetItem() {
            item.qualityModeRaw = mode.rawValue
            persistQualitySettings(for: item)
        } else {
            metalQualityMode = mode
            DefaultQualityStore.qualityModeRaw = mode.rawValue
        }
    }

    func setFrameInterpolationEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.frameInterpolationEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            frameInterpolationEnabled = enabled
        }
    }

    func setNaturalDenoiseEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.naturalDenoiseEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            naturalDenoiseEnabled = enabled
        }
    }

    func setNaturalDenoiseStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.naturalDenoiseStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            naturalDenoiseStrength = strength
        }
    }

    func setToneRecoveryEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.toneRecoveryEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            toneRecoveryEnabled = enabled
        }
    }

    func setToneRecoveryStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.toneRecoveryStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            toneRecoveryStrength = strength
        }
    }

    func setBrightnessBoost(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.brightnessBoost = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            brightnessBoost = strength
        }
    }

    func setMagicRescueEnabled(_ enabled: Bool) {
        if let item = qualityTargetItem() {
            item.magicRescueEnabled = enabled
            persistQualitySettings(for: item)
        } else {
            magicRescueEnabled = enabled
        }
    }

    func setMagicRescueMode(_ enabled: Bool) {
        if enabled {
            setMetalQualityMode(.best)
            setNaturalDenoiseEnabled(true)
            setNaturalDenoiseStrength(max(activeNaturalDenoiseStrength(), 0.72))
            setToneRecoveryEnabled(true)
            setToneRecoveryStrength(max(activeToneRecoveryStrength(), 0.66))
            setMagicRescueStrength(max(activeMagicRescueStrength(), 0.82))
        }
        setMagicRescueEnabled(enabled)
    }

    func setMagicRescueStrength(_ strength: Float) {
        if let item = qualityTargetItem() {
            item.magicRescueStrength = max(0, min(1, strength))
            persistQualitySettings(for: item)
        } else {
            magicRescueStrength = strength
        }
    }

    func setSplitCompareEnabled(_ enabled: Bool) {
        splitCompareEnabled = enabled
    }

    func setSplitCompareReversed(_ reversed: Bool) {
        splitCompareReversed = reversed
    }

    func clearSavedFileProfiles() {
        do {
            try ABHistoryStore.clearAll()
            try QualityProfileStore.clearAll()
            items.forEach { $0.hasSavedABHistory = false }
            tickVideoUI()
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func cycleMetalQualityMode() {
        let cases = MetalQualityMode.allCases
        guard let index = cases.firstIndex(of: activeMetalQualityMode()) else {
            setMetalQualityMode(.best)
            return
        }
        setMetalQualityMode(cases[(index + 1) % cases.count])
    }

}
