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
    @objc func toggleSelectedVideoPlayback() {
        guard let item = selectedVideoItem() else { return }
        if item.isVideoPlaying {
            item.playWhenVisible = false
            item.player?.pause()
        } else {
            item.playWhenVisible = true
            resumePlayback(for: item)
        }
        overlay.needsDisplay = true
        tickVideoUI()
    }

    @objc func toggleSelectedVideoPlaybackMode() {
        guard let item = selectedVideoItem() else { return }
        let nextMode: VideoPlaybackMode = item.playbackMode == .loop ? .swing : .loop
        setPlaybackMode(for: item, mode: nextMode)
    }

    func setPlaybackMode(for item: CollageItem, mode: VideoPlaybackMode) {
        guard item.kind == .video, item.playbackMode != mode else { return }
        item.playbackMode = mode
        if mode == .loop {
            item.swingDirection = 1
        } else if item.currentTimeSeconds <= 0.05 {
            item.swingDirection = 1
        } else if item.durationSeconds > 0 && item.currentTimeSeconds >= item.durationSeconds - 0.05 {
            item.swingDirection = -1
        }
        resetVideoFrameHistory(for: item)
        if item.isVideoPlaying {
            resumePlayback(for: item)
        }
        overlay.needsDisplay = true
        tickVideoUI()
    }

    @objc func toggleSelectedVideoMute() {
        guard let item = selectedVideoItem() else { return }
        item.muted.toggle()
        if !item.muted, item.volume <= 0.01 {
            item.volume = 0.7
        }
        applyAllAudioStates()
        tickVideoUI()
    }

    @objc func toggleSelectedVideoSolo() {
        guard let item = selectedVideoItem() else { return }
        if soloVideoItem === item {
            soloVideoItem = nil
        } else {
            soloVideoItem = item
            if item.muted || item.volume <= 0.01 {
                item.muted = false
                item.volume = max(item.volume, 0.7)
            }
        }
        applyAllAudioStates()
        tickVideoUI()
        overlay.needsDisplay = true
    }

    @objc func selectedVideoVolumeChanged() {
        guard let item = selectedVideoItem() else { return }
        item.volume = Float(max(0, min(1, volumeSlider.doubleValue)))
        item.muted = item.volume <= 0.001
        applyAllAudioStates()
        tickVideoUI()
    }

    func applyAudioState(for item: CollageItem) {
        item.player?.volume = item.volume
        item.player?.isMuted = item.muted || (soloVideoItem != nil && soloVideoItem !== item)
    }

    func applyAllAudioStates() {
        for item in items where item.kind == .video {
            applyAudioState(for: item)
        }
    }

    func resumePlayback(for item: CollageItem, direction: Float? = nil) {
        guard item.kind == .video else { return }
        if let direction {
            item.swingDirection = direction < 0 ? -1 : 1
        }
        if item.playbackMode == .loop {
            item.swingDirection = 1
        }
        item.player?.rate = effectivePlaybackRate(for: item)
    }

    @objc func speedDownSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: max(0.1, item.speed - 0.05))
    }

    @objc func speedUpSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: min(8, item.speed + 0.05))
    }

    @objc func resetSelectedVideoSpeed(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let item = selectedVideoItem() else { return }
        setSpeed(for: item, speed: 1)
    }

    func setSpeed(for item: CollageItem, speed: Float) {
        item.speed = (speed * 100).rounded() / 100
        resetVideoFrameHistory(for: item)
        if item.isVideoPlaying {
            resumePlayback(for: item)
        }
        tickVideoUI()
    }

    @objc func setAForSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setA(for: item, updateSelection: false)
    }

    func setA(for item: CollageItem, updateSelection: Bool = true) {
        suspendABLoop(for: item, seconds: 30)
        item.pendingA = item.currentTimeSeconds
        activatePendingLoopIfReady(for: item)
        if updateSelection {
            selectOnly(item)
        } else {
            timelineView.needsDisplay = true
            overlay.needsDisplay = true
            tickVideoUI()
        }
    }

    @objc func setBForSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        setB(for: item, updateSelection: false)
    }

    func setB(for item: CollageItem, updateSelection: Bool = true) {
        suspendABLoop(for: item, seconds: 30)
        item.pendingB = item.currentTimeSeconds
        activatePendingLoopIfReady(for: item)
        if updateSelection {
            selectOnly(item)
        } else {
            timelineView.needsDisplay = true
            overlay.needsDisplay = true
            tickVideoUI()
        }
    }

    @objc func addABForSelectedVideo() {
        guard let item = selectedVideoItem(), let a = item.pendingA, let b = item.pendingB, abs(a - b) > 0.05 else { return }
        setLoop(for: item, a: a, b: b)
    }

    @objc func clearABForSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        clearAB(for: item)
    }

    @objc func restoreABForSelectedVideo() {
        guard let item = selectedVideoItem() else { return }
        _ = restoreSavedABHistory(for: item, seekToFirst: true)
    }

    func clearAB(for item: CollageItem) {
        item.abLoops.removeAll()
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        timelineView.needsDisplay = true
        overlay.needsDisplay = true
        tickVideoUI()
    }

    @discardableResult
    func restoreSavedABHistory(for item: CollageItem, seekToFirst: Bool, refreshUI: Bool = true) -> Bool {
        ensureFileHash(for: item)
        guard let hash = item.fileHash,
              let loops = ABHistoryStore.latestLoops(forHash: hash) else {
            item.hasSavedABHistory = false
            if refreshUI { tickVideoUI() }
            return false
        }
        item.abLoops = loops
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        item.hasSavedABHistory = true
        if seekToFirst, let first = loops.first {
            resetVideoFrameHistory(for: item)
            item.player?.seek(to: CMTime(seconds: first.a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if refreshUI {
            timelineView.needsDisplay = true
            overlay.needsDisplay = true
            tickVideoUI()
        }
        return true
    }

    func suspendABLoop(for item: CollageItem, seconds: TimeInterval) {
        guard item.kind == .video, !item.abLoops.isEmpty else { return }
        item.abLoopBypassUntil = max(item.abLoopBypassUntil, CACurrentMediaTime() + seconds)
    }

    func activatePendingLoopIfReady(for item: CollageItem) {
        guard let a = item.pendingA, let b = item.pendingB, abs(a - b) > 0.05 else {
            timelineView.needsDisplay = true
            return
        }
        setLoop(for: item, a: a, b: b)
    }

    func setLoop(for item: CollageItem, a: Double, b: Double) {
        let duration = item.durationSeconds
        let start = max(0, min(a, b))
        let end = duration > 0 ? min(duration, max(a, b)) : max(a, b)
        guard end - start > 0.05 else {
            timelineView.needsDisplay = true
            return
        }
        item.abLoops.append((start, end))
        item.abLoops.sort { $0.a < $1.a }
        ABHistoryStore.save(loops: item.abLoops, for: item)
        item.pendingA = nil
        item.pendingB = nil
        item.abLoopBypassUntil = 0
        let wasPlaying = item.isVideoPlaying
        resetVideoFrameHistory(for: item)
        if wasPlaying {
            seekPlaybackPlayer(item, to: start, direction: 1, resumeWhenDone: true)
            isPaused = false
        } else {
            item.player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        tickVideoUI()
    }

    func tickVideoUI() {
        enforceVideoLoops()
        guard let item = selectedVideoItem() else {
            videoPanel.isHidden = true
            return
        }
        videoPanel.isHidden = false
        timelineView.item = item
        let isPlaying = item.isVideoPlaying
        setVideoButtonAppearance(playButton, accent: true)
        setIcon(
            playButton,
            symbol: isPlaying ? "pause.fill" : "play.fill",
            fallbackTitle: isPlaying ? "Pause" : "Play",
            tooltip: isPlaying ? "Pause video" : "Play video",
            pointSize: 18
        )
        setVideoButtonAppearance(muteButton, accent: item.muted)
        setIcon(
            muteButton,
            symbol: item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            fallbackTitle: item.muted ? "Unmute" : "Mute",
            tooltip: item.muted ? "Unmute this video" : "Mute this video",
            pointSize: 17
        )
        let isSolo = soloVideoItem === item
        setVideoButtonAppearance(soloButton, accent: isSolo)
        setIcon(
            soloButton,
            symbol: isSolo ? "headphones.circle.fill" : "headphones",
            fallbackTitle: "Solo",
            tooltip: isSolo ? "Turn solo off" : "Solo this video's audio",
            pointSize: 17
        )
        volumeSlider.doubleValue = Double(item.volume)
        volumeLabel.stringValue = "Vol \(Int((item.volume * 100).rounded()))%"
        speedLabel.stringValue = String(format: "%.2fx", item.speed)
        timeLabel.stringValue = "\(formatTime(item.currentTimeSeconds)) / \(formatTime(item.durationSeconds))"
        let mode = item.playbackMode
        playbackModeButton.state = mode == .loop ? .on : .off
        setVideoButtonAppearance(playbackModeButton, accent: mode == .loop)
        setIcon(
            playbackModeButton,
            symbol: "repeat",
            fallbackTitle: "Lp",
            tooltip: mode == .loop ? "Loop playback is on. Press to switch to Swing." : "Swing playback is on. Press to switch to Loop.",
            pointSize: 16
        )
        restoreABButton.isHidden = !item.hasSavedABHistory
        restoreABButton.isEnabled = item.hasSavedABHistory
        timelineView.needsDisplay = true
        positionVideoPanel()
    }

    func enforceVideoLoops() {
        let now = CACurrentMediaTime()
        for item in items where item.kind == .video {
            guard item.isVideoPlaying else { continue }
            syncSwingDirectionFromPlayer(for: item)
            if item.abLoops.isEmpty {
                enforceWholeVideoBoundary(for: item)
                continue
            }
            if item.pendingA != nil || item.pendingB != nil || item.abLoopBypassUntil > now {
                continue
            }
            let t = item.currentTimeSeconds
            let guardBand = max(0.045, Double(max(0.1, item.speed)) * 0.075)
            let loops = item.abLoops.sorted { $0.a < $1.a }
            if item.playbackMode == .swing {
                enforceSwingLoops(for: item, loops: loops, time: t, guardBand: guardBand)
                continue
            }
            let targetStart: Double?

            if let index = loops.firstIndex(where: { t >= $0.a - 0.02 && t < $0.b - guardBand }) {
                targetStart = nil
                _ = index
            } else if let index = loops.firstIndex(where: { t >= $0.a && t <= $0.b + guardBand }) {
                targetStart = loops[(index + 1) % loops.count].a
            } else {
                targetStart = (loops.first { $0.a > t } ?? loops[0]).a
            }

            if let targetStart {
                seekLoopingPlayer(item, to: targetStart)
            }
        }
    }

    func seekLoopingPlayer(_ item: CollageItem, to seconds: Double) {
        seekPlaybackPlayer(item, to: seconds, direction: 1, resumeWhenDone: true)
    }

    func seekSwingingPlayer(_ item: CollageItem, to seconds: Double, direction: Float) {
        seekPlaybackPlayer(item, to: seconds, direction: direction, resumeWhenDone: true)
    }

    func seekPlaybackPlayer(_ item: CollageItem, to seconds: Double, direction: Float?, resumeWhenDone: Bool) {
        guard let player = item.player else { return }
        if let direction {
            item.swingDirection = direction < 0 ? -1 : 1
        }
        if item.playbackMode == .loop {
            item.swingDirection = 1
        }
        let rate = effectivePlaybackRate(for: item)
        resetVideoFrameHistory(for: item)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
            guard resumeWhenDone else { return }
            player?.rate = rate
        }
        if resumeWhenDone {
            player.rate = rate
        }
    }

    func effectivePlaybackRate(for item: CollageItem) -> Float {
        let requestedRate = item.playbackRate
        guard requestedRate < -0.001,
              let playerItem = item.player?.currentItem,
              playerItem.status == .readyToPlay else {
            return requestedRate
        }

        if abs(requestedRate) > 1.001, !playerItem.canPlayFastReverse {
            return -1
        }
        if !playerItem.canPlayReverse, playerItem.canPlaySlowReverse {
            return max(requestedRate, -0.5)
        }
        return requestedRate
    }

    func syncSwingDirectionFromPlayer(for item: CollageItem) {
        guard item.playbackMode == .swing, let player = item.player else { return }
        if player.rate < -0.001 {
            item.swingDirection = -1
        } else if player.rate > 0.001 {
            item.swingDirection = 1
        }
    }

    func enforceWholeVideoBoundary(for item: CollageItem) {
        guard item.playbackMode == .swing else { return }
        let duration = item.durationSeconds
        guard duration > 0.05 else { return }
        let t = item.currentTimeSeconds
        let guardBand = max(0.035, Double(max(0.1, item.speed)) * 0.06)
        if item.normalizedSwingDirection > 0, t >= duration - guardBand {
            seekSwingingPlayer(item, to: max(0, duration - 0.02), direction: -1)
        } else if item.normalizedSwingDirection < 0, t <= guardBand {
            seekSwingingPlayer(item, to: 0, direction: 1)
        }
    }

    func enforceSwingLoops(for item: CollageItem, loops: [(a: Double, b: Double)], time: Double, guardBand: Double) {
        guard let decision = VideoLoopBoundaryPlanner.swingDecision(
            loops: loops,
            time: time,
            direction: item.normalizedSwingDirection,
            guardBand: guardBand
        ) else { return }
        seekSwingingPlayer(item, to: decision.target, direction: decision.direction)
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

}
