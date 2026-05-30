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
    @MainActor @objc func showQualityPanel() {
        if qualityPanel == nil {
            qualityPanel = makeQualityPanel()
        }
        syncQualityControls()
        if let window, let qualityPanel, !qualityPanel.isVisible {
            let x = min(window.frame.maxX - qualityPanel.frame.width - 18, max(window.frame.minX + 18, window.frame.midX - qualityPanel.frame.width / 2))
            let y = min(window.frame.maxY - qualityPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - qualityPanel.frame.height / 2))
            qualityPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        qualityPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func makeQualityPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 650),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quality Controls"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 390, height: 590)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 430, height: 650))
        content.panelTitle = "Quality Controls"
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        func addFullWidth(_ view: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addFullWidth(FlowLibraryStyle.sectionLabel("Target"))
        let targetLabel = FlowLibraryStyle.secondaryLabel("Target: Defaults for new files")
        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.lineBreakMode = .byTruncatingMiddle
        qualityPanelTargetLabel = targetLabel
        addFullWidth(targetLabel)

        let defaultsButton = FlowSwitchControl()
        defaultsButton.target = self
        defaultsButton.action = #selector(qualityPanelDefaultsChanged(_:))
        defaultsButton.toolTip = "Edit fallback quality settings used before a file has its own saved hash profile"
        qualityPanelDefaultsButton = defaultsButton
        addFullWidth(qualitySettingRow(title: "Edit Defaults", subtitle: "For new files", trailing: defaultsButton))

        addFullWidth(qualitySeparator())
        addFullWidth(FlowLibraryStyle.sectionLabel("Sampling"))
        let modeControl = FlowSegmentedControl()
        modeControl.segments = MetalQualityMode.allCases.map(\.displayName)
        modeControl.target = self
        modeControl.action = #selector(qualityPanelModeChanged(_:))
        modeControl.heightAnchor.constraint(equalToConstant: 30).isActive = true
        qualityPanelModeControl = modeControl
        addFullWidth(modeControl)

        addFullWidth(qualitySeparator())
        addFullWidth(FlowLibraryStyle.sectionLabel("Processing"))
        let frameInterpolation = FlowSwitchControl()
        frameInterpolation.target = self
        frameInterpolation.action = #selector(qualityPanelFrameInterpolationChanged(_:))
        qualityPanelFrameInterpolationButton = frameInterpolation
        addFullWidth(qualitySettingRow(title: "Frame Interpolation", subtitle: "Smooth speed changes", trailing: frameInterpolation))

        let denoise = FlowSwitchControl()
        denoise.target = self
        denoise.action = #selector(qualityPanelDenoiseChanged(_:))
        qualityPanelDenoiseButton = denoise
        addFullWidth(qualitySettingRow(title: "Natural Denoise", subtitle: "Edge-aware detail", trailing: denoise))

        let denoiseSlider = FlowSliderControl()
        denoiseSlider.doubleValue = 0.72
        denoiseSlider.target = self
        denoiseSlider.action = #selector(qualityPanelDenoiseStrengthChanged(_:))
        let denoiseValue = qualityValueLabel("72%")
        qualityPanelDenoiseSlider = denoiseSlider
        qualityPanelDenoiseValue = denoiseValue
        addFullWidth(qualitySliderRow("Noise", denoiseSlider, denoiseValue))

        let tone = FlowSwitchControl()
        tone.target = self
        tone.action = #selector(qualityPanelToneChanged(_:))
        qualityPanelToneButton = tone
        addFullWidth(qualitySettingRow(title: "Auto Tone", subtitle: "Recover detail", trailing: tone))

        let toneSlider = FlowSliderControl()
        toneSlider.doubleValue = 0.58
        toneSlider.target = self
        toneSlider.action = #selector(qualityPanelToneStrengthChanged(_:))
        let toneValue = qualityValueLabel("58%")
        qualityPanelToneSlider = toneSlider
        qualityPanelToneValue = toneValue
        addFullWidth(qualitySliderRow("Tone", toneSlider, toneValue))

        let brightnessSlider = FlowSliderControl()
        brightnessSlider.doubleValue = 0
        brightnessSlider.target = self
        brightnessSlider.action = #selector(qualityPanelBrightnessChanged(_:))
        brightnessSlider.toolTip = "Boosts exposure, shadows, midtone contrast, and vibrance together"
        let brightnessValue = qualityValueLabel("0%")
        qualityPanelBrightnessSlider = brightnessSlider
        qualityPanelBrightnessValue = brightnessValue
        addFullWidth(qualitySliderRow("Bright", brightnessSlider, brightnessValue))

        let magic = FlowSwitchControl()
        magic.target = self
        magic.action = #selector(qualityPanelMagicChanged(_:))
        magic.toolTip = "Aggressive shadow/highlight rescue, local contrast, vibrance, and sharpening"
        qualityPanelMagicButton = magic
        addFullWidth(qualitySettingRow(title: "Magic Rescue", subtitle: "Aggressive recovery", trailing: magic))

        let magicSlider = FlowSliderControl()
        magicSlider.doubleValue = 0.82
        magicSlider.target = self
        magicSlider.action = #selector(qualityPanelMagicStrengthChanged(_:))
        magicSlider.toolTip = "Magic Rescue strength"
        let magicValue = qualityValueLabel("82%")
        qualityPanelMagicSlider = magicSlider
        qualityPanelMagicValue = magicValue
        addFullWidth(qualitySliderRow("Magic", magicSlider, magicValue))

        addFullWidth(qualitySeparator())
        addFullWidth(FlowLibraryStyle.sectionLabel("Compare"))
        let split = FlowSwitchControl()
        split.target = self
        split.action = #selector(qualityPanelSplitCompareChanged(_:))
        qualityPanelSplitButton = split
        addFullWidth(qualitySettingRow(title: "Split Compare", subtitle: "Raw vs quality", trailing: split))

        let splitReverse = FlowSwitchControl()
        splitReverse.target = self
        splitReverse.action = #selector(qualityPanelSplitReverseChanged(_:))
        splitReverse.toolTip = "Swap split compare: B Quality on the left, A Raw on the right"
        qualityPanelSplitReverseButton = splitReverse
        addFullWidth(qualitySettingRow(title: "B/A Compare", subtitle: "Swap sides", trailing: splitReverse))

        let clearProfiles = FlowActionButton(title: "Clear Saved File Profiles...", symbolName: nil, isAccent: false)
        clearProfiles.target = self
        clearProfiles.action = #selector(clearSavedFileProfilesFromPanel)
        clearProfiles.toolTip = "Clear saved per-file quality profiles and A-B histories"
        clearProfiles.heightAnchor.constraint(equalToConstant: 32).isActive = true
        addFullWidth(clearProfiles)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])

        panel.contentView = content
        if let window {
            let origin = CGPoint(x: window.frame.maxX - 390, y: window.frame.maxY - 380)
            panel.setFrameOrigin(origin)
        }
        return panel
    }

    @MainActor func qualitySettingRow(title: String, subtitle: String?, trailing: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.addArrangedSubview(FlowLibraryStyle.primaryLabel(title))
        if let subtitle {
            textStack.addArrangedSubview(FlowLibraryStyle.secondaryLabel(subtitle))
        }
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(trailing)
        return row
    }

    @MainActor func qualitySliderRow(_ title: String, _ slider: FlowSliderControl, _ value: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let label = FlowLibraryStyle.secondaryLabel(title)
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        row.addArrangedSubview(label)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    @MainActor func qualityValueLabel(_ text: String) -> NSTextField {
        let label = FlowLibraryStyle.secondaryLabel(text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return label
    }

    @MainActor func qualitySeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @MainActor @objc func qualityPanelModeChanged(_ sender: FlowSegmentedControl) {
        let rawValue = sender.selectedIndex
        canvas?.setMetalQualityMode(MetalQualityMode(rawValue: rawValue) ?? .best)
    }

    @MainActor @objc func qualityPanelDefaultsChanged(_ sender: FlowSwitchControl) {
        canvas?.setQualityEditsDefaults(sender.isOn)
    }

    @MainActor @objc func qualityPanelFrameInterpolationChanged(_ sender: FlowSwitchControl) {
        canvas?.setFrameInterpolationEnabled(sender.isOn)
    }

    @MainActor @objc func qualityPanelDenoiseChanged(_ sender: FlowSwitchControl) {
        canvas?.setNaturalDenoiseEnabled(sender.isOn)
    }

    @MainActor @objc func qualityPanelDenoiseStrengthChanged(_ sender: FlowSliderControl) {
        canvas?.setNaturalDenoiseStrength(Float(sender.doubleValue))
    }

    @MainActor @objc func qualityPanelToneChanged(_ sender: FlowSwitchControl) {
        canvas?.setToneRecoveryEnabled(sender.isOn)
    }

    @MainActor @objc func qualityPanelToneStrengthChanged(_ sender: FlowSliderControl) {
        canvas?.setToneRecoveryStrength(Float(sender.doubleValue))
    }

    @MainActor @objc func qualityPanelBrightnessChanged(_ sender: FlowSliderControl) {
        canvas?.setBrightnessBoost(Float(sender.doubleValue))
    }

    @MainActor @objc func qualityPanelMagicChanged(_ sender: FlowSwitchControl) {
        canvas?.setMagicRescueMode(sender.isOn)
    }

    @MainActor @objc func qualityPanelMagicStrengthChanged(_ sender: FlowSliderControl) {
        canvas?.setMagicRescueStrength(Float(sender.doubleValue))
    }

    @MainActor @objc func qualityPanelSplitCompareChanged(_ sender: FlowSwitchControl) {
        canvas?.setSplitCompareEnabled(sender.isOn)
    }

    @MainActor @objc func qualityPanelSplitReverseChanged(_ sender: FlowSwitchControl) {
        canvas?.setSplitCompareReversed(sender.isOn)
    }

    @MainActor @objc func clearSavedFileProfilesFromPanel() {
        guard showFlowStyledConfirmation(
            panelTitle: "Quality Profiles",
            title: "Clear saved file profiles?",
            message: "This clears all per-file quality profiles and A-B histories saved by file hash. Current open files stay loaded.",
            confirmTitle: "Clear",
            cancelTitle: "Cancel"
        ) else { return }
        canvas?.clearSavedFileProfiles()
        syncQualityControls()
    }

    @MainActor @objc func syncQualityControls() {
        guard let canvas else { return }
        rebuildQualityMenu()
        qualityPanelTargetLabel?.stringValue = "Target: \(canvas.activeQualityTargetName())"
        qualityPanelDefaultsButton?.isOn = canvas.isEditingQualityDefaults()
        qualityPanelDefaultsButton?.isEnabled = canvas.hasQualityTargetItem()
        qualityPanelModeControl?.selectedIndex = canvas.activeMetalQualityMode().rawValue
        qualityPanelFrameInterpolationButton?.isOn = canvas.activeFrameInterpolationEnabled()
        qualityPanelDenoiseButton?.isOn = canvas.activeNaturalDenoiseEnabled()
        qualityPanelDenoiseSlider?.doubleValue = Double(canvas.activeNaturalDenoiseStrength())
        qualityPanelDenoiseSlider?.isEnabled = canvas.activeNaturalDenoiseEnabled()
        qualityPanelDenoiseValue?.stringValue = percent(canvas.activeNaturalDenoiseStrength())
        qualityPanelToneButton?.isOn = canvas.activeToneRecoveryEnabled()
        qualityPanelToneSlider?.doubleValue = Double(canvas.activeToneRecoveryStrength())
        qualityPanelToneSlider?.isEnabled = canvas.activeToneRecoveryEnabled()
        qualityPanelToneValue?.stringValue = percent(canvas.activeToneRecoveryStrength())
        qualityPanelBrightnessSlider?.doubleValue = Double(canvas.activeBrightnessBoost())
        qualityPanelBrightnessValue?.stringValue = percent(canvas.activeBrightnessBoost())
        qualityPanelMagicButton?.isOn = canvas.activeMagicRescueEnabled()
        qualityPanelMagicSlider?.doubleValue = Double(canvas.activeMagicRescueStrength())
        qualityPanelMagicSlider?.isEnabled = canvas.activeMagicRescueEnabled()
        qualityPanelMagicValue?.stringValue = percent(canvas.activeMagicRescueStrength())
        qualityPanelSplitButton?.isOn = canvas.splitCompareEnabled
        qualityPanelSplitReverseButton?.isOn = canvas.splitCompareReversed
        qualityPanelSplitReverseButton?.isEnabled = canvas.splitCompareEnabled
        frameInterpolationMenuItem?.state = canvas.activeFrameInterpolationEnabled() ? .on : .off
        naturalDenoiseMenuItem?.state = canvas.activeNaturalDenoiseEnabled() ? .on : .off
        magicRescueMenuItem?.state = canvas.activeMagicRescueEnabled() ? .on : .off
    }

    @MainActor func percent(_ value: Float) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }

    @MainActor @objc func rebuildQualityMenu() {
        qualityMenu.removeAllItems()
        let activeMode = canvas?.activeMetalQualityMode() ?? .best
        for mode in MetalQualityMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setMetalQualityFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = mode.tooltip
            item.state = mode == activeMode ? .on : .off
            qualityMenu.addItem(item)
        }
    }

    @MainActor @objc func setMetalQualityFromMenu(_ sender: NSMenuItem) {
        let rawValue = sender.representedObject as? Int ?? MetalQualityMode.best.rawValue
        canvas?.setMetalQualityMode(MetalQualityMode(rawValue: rawValue) ?? .best)
        rebuildQualityMenu()
    }

    @MainActor @objc func toggleFrameInterpolation(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeFrameInterpolationEnabled()
        canvas.setFrameInterpolationEnabled(enabled)
        sender.state = enabled ? .on : .off
        frameInterpolationMenuItem?.state = sender.state
    }

    @MainActor @objc func toggleNaturalDenoise(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeNaturalDenoiseEnabled()
        canvas.setNaturalDenoiseEnabled(enabled)
        sender.state = enabled ? .on : .off
        naturalDenoiseMenuItem?.state = sender.state
    }

    @MainActor @objc func toggleMagicRescue(_ sender: NSMenuItem) {
        guard let canvas else { return }
        let enabled = !canvas.activeMagicRescueEnabled()
        canvas.setMagicRescueMode(enabled)
        sender.state = enabled ? .on : .off
        magicRescueMenuItem?.state = sender.state
    }

}
