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
    func saveLastPlayback() {
        guard !items.isEmpty else { return }
        do {
            try LastPlaybackStore.ensureDirectory()
            try savePlayback(to: LastPlaybackStore.url, addToRecents: false)
        } catch {
            NSLog("Last playback save failed: \(error)")
        }
    }

    @discardableResult
    func restoreLastPlaybackIfAvailable() -> Bool {
        guard let url = LastPlaybackStore.existingURL else { return false }
        loadPlayback(from: url, addToRecents: false)
        return true
    }

    @objc func openLastClosedSessionFromMenu() {
        if !restoreLastPlaybackIfAvailable() {
            NSSound.beep()
        }
    }

    @objc func forgetLastClosedSessionFromMenu() {
        do {
            if try !LastPlaybackStore.deleteExisting() {
                NSSound.beep()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @discardableResult
    func savePlayback(to url: URL, addToRecents: Bool) throws -> Bool {
        let payload = SavedPlayback(
            items: items.map { item in
                SavedItem(
                    path: item.url.path,
                    weight: item.weight,
                    zoom: item.zoom,
                    panX: item.pan.x,
                    panY: item.pan.y,
                    crop: item.cropRect,
                    rotationQuarterTurns: item.rotationQuarterTurns,
                    speed: item.speed,
                    volume: item.volume,
                    muted: item.muted,
                    playbackMode: item.kind == .video ? item.playbackMode : nil,
                    swingDirection: item.kind == .video ? item.normalizedSwingDirection : nil,
                    currentTime: item.kind == .video ? item.currentTimeSeconds : nil,
                    playing: item.kind == .video ? item.playWhenVisible : nil,
                    abLoops: item.abLoops.map { SavedLoop(a: $0.a, b: $0.b) }
                )
            },
            flowSettings: savedFlowSettings()
        )
        do {
            let data = try JSONEncoder().encode(payload)
            let encrypted = try PlaybackCrypto.encrypt(data)
            try encrypted.write(to: url, options: .atomic)
            if addToRecents {
                RecentPlaybacksStore.add(url)
            }
            return true
        } catch {
            if addToRecents {
                NSAlert(error: error).runModal()
            }
            throw error
        }
    }

    func loadPlayback(from url: URL, addToRecents: Bool) {
        do {
            let data = try Data(contentsOf: url)
            let playbackData = try PlaybackCrypto.decrypt(data)
            let payload = try JSONDecoder().decode(SavedPlayback.self, from: playbackData)
            clearABHistoryForClosingItems(items)
            items.forEach { $0.player?.pause() }
            items.removeAll()
            visibleSlots.removeAll()
            flowVisibleIndexes.removeAll()
            flowCursor = 0
            soloVideoItem = nil
            for saved in payload.items {
                let mediaURL = URL(fileURLWithPath: saved.path)
                guard let item = loadImage(url: mediaURL) ?? loadVideo(url: mediaURL) else { continue }
                prepareLoadedItem(item, restoreABHistory: false)
                item.weight = saved.weight
                item.zoom = max(1, saved.zoom)
                item.pan = CGPoint(x: saved.panX, y: saved.panY)
                item.cropRect = saved.crop
                item.rotationQuarterTurns = saved.rotationQuarterTurns ?? 0
                item.speed = saved.speed
                item.volume = max(0, min(1, saved.volume ?? 1))
                item.muted = saved.muted
                item.playbackMode = saved.playbackMode ?? .loop
                item.swingDirection = (saved.swingDirection ?? 1) < 0 ? -1 : 1
                item.abLoops = saved.abLoops.map { ($0.a, $0.b) }
                applyAudioState(for: item)
                if let seconds = saved.currentTime, seconds.isFinite, seconds > 0 {
                    resetVideoFrameHistory(for: item)
                    item.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                item.playWhenVisible = saved.playing ?? true
                if item.playWhenVisible {
                    resumePlayback(for: item)
                } else {
                    item.player?.pause()
                }
                items.append(item)
            }
            applySavedFlowSettings(payload.flowSettings)
            items.last?.selected = true
            isPaused = !items.contains { $0.kind == .video }
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
            relayout()
            postFlowLibraryChanged()
            if addToRecents {
                RecentPlaybacksStore.add(url)
            }
        } catch {
            if addToRecents {
                NSAlert(error: error).runModal()
            } else {
                NSLog("Last playback restore failed: \(error)")
            }
        }
    }

}
