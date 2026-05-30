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
    func setupToolPanel() {
        toolPanel.material = .hudWindow
        toolPanel.blendingMode = .withinWindow
        toolPanel.state = .active
        toolPanel.wantsLayer = true
        toolPanel.layer?.cornerRadius = 13
        toolPanel.layer?.masksToBounds = true
        toolPanel.isHidden = true

        toolStack.orientation = .horizontal
        toolStack.spacing = 4
        toolStack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        toolPanel.addSubview(toolStack)

        addToolButton(symbol: "arrow.up.left.and.arrow.down.right", fallbackTitle: "+", tooltip: "Enlarge item", #selector(enlargeHoveredItem))
        addToolButton(symbol: "arrow.down.right.and.arrow.up.left", fallbackTitle: "-", tooltip: "Reduce item", #selector(reduceHoveredItem))
        addToolButton(symbol: "plus.magnifyingglass", fallbackTitle: "+", tooltip: "Zoom in", #selector(zoomInHoveredItem))
        addToolButton(symbol: "minus.magnifyingglass", fallbackTitle: "-", tooltip: "Zoom out", #selector(zoomOutHoveredItem))
        addToolButton(symbol: "hand.draw", fallbackTitle: "P", tooltip: "Pan visible content", #selector(panHoveredItem))
        addToolButton(symbol: "rotate.left", fallbackTitle: "L", tooltip: "Rotate item left", #selector(rotateHoveredItemLeft))
        addToolButton(symbol: "arrow.triangle.2.circlepath", fallbackTitle: "180", tooltip: "Rotate item 180 degrees", #selector(rotateHoveredItemHalfTurn))
        addToolButton(symbol: "rotate.right", fallbackTitle: "R", tooltip: "Rotate item right", #selector(rotateHoveredItemRight))

        addSubview(toolPanel)
    }

    func setupVideoPanel() {
        videoPanel.wantsLayer = true
        videoPanel.layer?.cornerRadius = 16
        videoPanel.layer?.masksToBounds = true
        videoPanel.isHidden = true

        videoStack.orientation = .horizontal
        videoStack.alignment = .centerY
        videoStack.spacing = 8
        videoStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        videoPanel.addSubview(videoStack)

        configureVideoIconButton(playButton, symbol: "pause.fill", fallbackTitle: "Pause", tooltip: "Pause or play video", accent: true)
        playButton.target = self
        playButton.action = #selector(toggleSelectedVideoPlayback)
        videoStack.addArrangedSubview(playButton)

        configureVideoIconButton(playbackModeButton, symbol: "repeat", fallbackTitle: "Lp", tooltip: "Loop playback is on. Press to switch to Swing.", accent: true, iconPointSize: 16)
        playbackModeButton.target = self
        playbackModeButton.action = #selector(toggleSelectedVideoPlaybackMode)
        videoStack.addArrangedSubview(playbackModeButton)

        configureVideoIconButton(muteButton, symbol: "speaker.wave.2.fill", fallbackTitle: "Mute", tooltip: "Mute or unmute this video")
        muteButton.target = self
        muteButton.action = #selector(toggleSelectedVideoMute)
        videoStack.addArrangedSubview(muteButton)

        configureVideoIconButton(soloButton, symbol: "headphones", fallbackTitle: "Solo", tooltip: "Solo this video's audio")
        soloButton.target = self
        soloButton.action = #selector(toggleSelectedVideoSolo)
        videoStack.addArrangedSubview(soloButton)

        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeLabel.textColor = FlowLibraryStyle.secondaryText
        volumeLabel.alignment = .center
        volumeLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        videoStack.addArrangedSubview(volumeLabel)

        volumeSlider.target = self
        volumeSlider.action = #selector(selectedVideoVolumeChanged)
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Volume"
        volumeSlider.trackFillColor = FlowLibraryStyle.accent
        volumeSlider.widthAnchor.constraint(equalToConstant: 112).isActive = true
        videoStack.addArrangedSubview(volumeSlider)

        let speedStack = NSStackView()
        speedStack.orientation = .horizontal
        speedStack.alignment = .centerY
        speedStack.spacing = 3
        let speedDownButton = videoIconButton(
            symbol: "tortoise.fill",
            fallbackTitle: "-",
            tooltip: "Slow down playback",
            action: #selector(speedDownSelectedVideo),
            iconPointSize: 12.5,
            buttonSize: 30
        )
        speedStack.addArrangedSubview(speedDownButton)
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        speedLabel.textColor = FlowLibraryStyle.primaryText
        speedLabel.alignment = .center
        speedLabel.toolTip = "Double-click to reset speed to 1x"
        let speedResetClick = NSClickGestureRecognizer(target: self, action: #selector(resetSelectedVideoSpeed(_:)))
        speedResetClick.numberOfClicksRequired = 2
        speedLabel.addGestureRecognizer(speedResetClick)
        speedLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        speedStack.addArrangedSubview(speedLabel)
        let speedUpButton = videoIconButton(
            symbol: "hare.fill",
            fallbackTitle: "+",
            tooltip: "Speed up playback",
            action: #selector(speedUpSelectedVideo),
            iconPointSize: 12.5,
            buttonSize: 30
        )
        speedStack.addArrangedSubview(speedUpButton)
        videoStack.addArrangedSubview(speedStack)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = FlowLibraryStyle.secondaryText
        timeLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
        videoStack.addArrangedSubview(timeLabel)

        timelineView.canvas = self
        timelineView.wantsLayer = true
        timelineView.layer?.cornerRadius = 8
        timelineView.widthAnchor.constraint(equalToConstant: 360).isActive = true
        timelineView.heightAnchor.constraint(equalToConstant: 34).isActive = true
        videoStack.addArrangedSubview(timelineView)

        addVideoButton(symbol: "a.circle", fallbackTitle: "A", tooltip: "Set A point (1)", #selector(setAForSelectedVideo))
        addVideoButton(symbol: "b.circle", fallbackTitle: "B", tooltip: "Set B point and add A-B clip (2)", #selector(setBForSelectedVideo))
        addVideoButton(symbol: "xmark.circle", fallbackTitle: "Clear", tooltip: "Clear all A-B clips (0)", #selector(clearABForSelectedVideo))
        configureVideoIconButton(restoreABButton, symbol: "clock.arrow.circlepath", fallbackTitle: "AB", tooltip: "Restore saved A-B clips for this file")
        restoreABButton.target = self
        restoreABButton.action = #selector(restoreABForSelectedVideo)
        restoreABButton.isHidden = true
        videoStack.addArrangedSubview(restoreABButton)

        addSubview(videoPanel)
    }

    func addToolButton(symbol: String, fallbackTitle: String, tooltip: String, _ action: Selector) {
        let button = iconButton(symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, action: action)
        toolStack.addArrangedSubview(button)
    }

    func addVideoButton(symbol: String, fallbackTitle: String, tooltip: String, _ action: Selector) {
        let button = videoIconButton(symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, action: action, iconPointSize: 17)
        videoStack.addArrangedSubview(button)
    }

    func iconButton(symbol: String, fallbackTitle: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        configureIconButton(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip)
        return button
    }

    func configureIconButton(_ button: NSButton, symbol: String, fallbackTitle: String, tooltip: String) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        setIcon(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip)
    }

    func videoIconButton(
        symbol: String,
        fallbackTitle: String,
        tooltip: String,
        action: Selector,
        iconPointSize: CGFloat,
        buttonSize: CGFloat = 34
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        configureVideoIconButton(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, iconPointSize: iconPointSize, buttonSize: buttonSize)
        return button
    }

    func configureVideoIconButton(
        _ button: NSButton,
        symbol: String,
        fallbackTitle: String,
        tooltip: String,
        accent: Bool = false,
        iconPointSize: CGFloat = 17,
        buttonSize: CGFloat = 34
    ) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        setVideoButtonAppearance(button, accent: accent)
        setIcon(button, symbol: symbol, fallbackTitle: fallbackTitle, tooltip: tooltip, pointSize: iconPointSize)
    }

    func setVideoButtonAppearance(_ button: NSButton, accent: Bool) {
        let fill = accent
            ? FlowLibraryStyle.accent
            : NSColor.white.withAlphaComponent(0.08)
        let stroke = accent
            ? FlowLibraryStyle.accent.withAlphaComponent(0.75)
            : NSColor.white.withAlphaComponent(0.08)
        button.layer?.backgroundColor = fill.cgColor
        button.layer?.borderColor = stroke.cgColor
        button.contentTintColor = accent ? NSColor.black.withAlphaComponent(0.84) : FlowLibraryStyle.primaryText
    }

    func setIcon(_ button: NSButton, symbol: String, fallbackTitle: String, tooltip: String, pointSize: CGFloat? = nil) {
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.title = ""
            let templateImage = image.copy() as? NSImage ?? image
            if let pointSize,
               let configuredImage = templateImage.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold)) {
                configuredImage.isTemplate = true
                button.image = configuredImage
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                return
            }
            templateImage.isTemplate = true
            button.image = templateImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        } else {
            button.title = fallbackTitle
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    @objc func addFilesFromPanel() {
        guard !isAddFilesPanelOpen else { return }
        isAddFilesPanelOpen = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.begin { [weak self] response in
            self?.isAddFilesPanelOpen = false
            guard response == .OK else { return }
            self?.loadMedia(urls: panel.urls)
        }
    }

    @objc func savePlaybackFromPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "collage"
        panel.allowedContentTypes = [AppMetadata.playbackPanelContentType]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.savePlayback(to: PlaybackFile.normalizedSaveURL(url), addToRecents: true)
            } catch {
                // savePlayback shows the user-facing alert for manual saves.
            }
        }
    }

    @objc func loadPlaybackFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [AppMetadata.playbackPanelContentType]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.loadPlayback(from: url, addToRecents: true)
        }
    }

    @objc func toggleCropFromPanel() {
        cropMode.toggle()
        activeCropRect = nil
        overlay.needsDisplay = true
    }

    @objc func clearAllFromPanel() {
        resetSceneForNewPlayback()
        syncLayerEDRMetadata()
        relayout()
        tickVideoUI()
        postFlowLibraryChanged()
    }

}
