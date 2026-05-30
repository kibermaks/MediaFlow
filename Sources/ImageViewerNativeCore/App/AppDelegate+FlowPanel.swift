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
    @MainActor @objc func showFlowPanel() {
        if flowPanel == nil {
            flowPanel = makeFlowPanel()
        }
        syncFlowControls()
        if let window, let flowPanel, !flowPanel.isVisible {
            let x = min(window.frame.maxX - flowPanel.frame.width - 18, max(window.frame.minX + 18, window.frame.minX + 28))
            let y = min(window.frame.maxY - flowPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - flowPanel.frame.height / 2))
            flowPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        flowPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func makeFlowPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 734),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Flow Library"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 340, height: 560)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 340, height: 734))
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView(frame: NSRect(x: 15, y: 38, width: content.bounds.width - 30, height: content.bounds.height - 52))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)

        let header = FlowHeaderCardView()
        header.canvas = canvas
        header.widthAnchor.constraint(equalToConstant: 300).isActive = true
        header.heightAnchor.constraint(equalToConstant: 56).isActive = true
        flowHeaderView = header
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(FlowLibraryStyle.sectionLabel("Layout"))

        let maxStepper = FlowNumberStepper()
        maxStepper.minimumValue = 1
        maxStepper.maximumValue = 64
        maxStepper.stepValue = 1
        maxStepper.target = self
        maxStepper.action = #selector(flowMaxVisibleChanged(_:))
        flowMaxStepper = maxStepper
        stack.addArrangedSubview(flowSettingRow(title: "Max on Screen", subtitle: "Tiles shown at once", trailing: maxStepper))

        stack.addArrangedSubview(flowSeparator())
        stack.addArrangedSubview(FlowLibraryStyle.sectionLabel("Rotation"))

        let modeControl = FlowSegmentedControl()
        modeControl.segments = FlowRotationMode.allCases.map(\.displayName)
        modeControl.target = self
        modeControl.action = #selector(flowModeChanged(_:))
        modeControl.widthAnchor.constraint(equalToConstant: 300).isActive = true
        modeControl.heightAnchor.constraint(equalToConstant: 30).isActive = true
        flowModeControl = modeControl
        stack.addArrangedSubview(modeControl)

        let autoRotate = FlowSwitchControl()
        autoRotate.target = self
        autoRotate.action = #selector(flowAutoRotateChanged(_:))
        flowAutoRotateButton = autoRotate
        stack.addArrangedSubview(flowSettingRow(title: "Auto-Rotate", subtitle: "Cycle slots on a timer", trailing: autoRotate))

        let intervalStepper = FlowNumberStepper()
        intervalStepper.minimumValue = 4
        intervalStepper.maximumValue = 600
        intervalStepper.stepValue = 5
        intervalStepper.suffix = "s"
        intervalStepper.target = self
        intervalStepper.action = #selector(flowIntervalChanged(_:))
        flowIntervalStepper = intervalStepper
        stack.addArrangedSubview(flowSettingRow(title: "Change Every", subtitle: nil, trailing: intervalStepper))

        let duplicates = FlowSwitchControl()
        duplicates.target = self
        duplicates.action = #selector(flowDuplicateChanged(_:))
        duplicates.toolTip = "Random rotation can fill multiple preview slots with the same source item."
        flowDuplicateButton = duplicates
        stack.addArrangedSubview(flowSettingRow(title: "Allow Duplicate Slots", subtitle: "Same clip in multiple tiles", trailing: duplicates))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let shuffleButton = FlowActionButton(title: "Shuffle", symbolName: "shuffle", isAccent: false)
        shuffleButton.target = canvas
        shuffleButton.action = #selector(MetalCollageView.shuffleFlowFromMenu)
        shuffleButton.toolTip = "Shuffle the visible flow set now"
        shuffleButton.widthAnchor.constraint(equalToConstant: 146).isActive = true
        shuffleButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(shuffleButton)
        let nextButton = FlowActionButton(title: "Advance", symbolName: "forward.end.fill", isAccent: true)
        nextButton.target = canvas
        nextButton.action = #selector(MetalCollageView.advanceFlowFromMenu)
        nextButton.toolTip = "Advance to the next flow page now"
        nextButton.widthAnchor.constraint(equalToConstant: 146).isActive = true
        nextButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(nextButton)
        stack.addArrangedSubview(buttonRow)

        stack.addArrangedSubview(flowSeparator())
        let poolHeader = NSStackView()
        poolHeader.orientation = .horizontal
        poolHeader.alignment = .centerY
        poolHeader.spacing = 8
        poolHeader.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let poolLabel = FlowLibraryStyle.sectionLabel("Media Pool")
        poolHeader.addArrangedSubview(poolLabel)
        let spacer = NSView()
        poolHeader.addArrangedSubview(spacer)
        let poolCount = FlowLibraryStyle.secondaryLabel("")
        poolCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        poolCount.alignment = .right
        flowPoolCountLabel = poolCount
        poolHeader.addArrangedSubview(poolCount)
        stack.addArrangedSubview(poolHeader)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 285).isActive = true
        let grid = FlowLibraryGridView(frame: NSRect(x: 0, y: 0, width: 300, height: 285))
        grid.canvas = canvas
        flowGridView = grid
        scroll.documentView = grid
        stack.addArrangedSubview(scroll)

        panel.contentView = content
        return panel
    }

    @MainActor func flowSettingRow(title: String, subtitle: String?, trailing: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.widthAnchor.constraint(equalToConstant: 206).isActive = true
        textStack.addArrangedSubview(FlowLibraryStyle.primaryLabel(title))
        if let subtitle {
            textStack.addArrangedSubview(FlowLibraryStyle.secondaryLabel(subtitle))
        }
        row.addArrangedSubview(textStack)

        let spacer = NSView()
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(trailing)
        return row
    }

    @MainActor func flowSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return separator
    }

    @MainActor @objc func flowMaxVisibleChanged(_ sender: FlowNumberStepper) {
        canvas?.flowMaxVisibleItems = sender.integerValue
    }

    @MainActor @objc func flowModeChanged(_ sender: FlowSegmentedControl) {
        let rawValue = sender.selectedIndex
        canvas?.flowRotationMode = FlowRotationMode(rawValue: rawValue) ?? .roundRobin
    }

    @MainActor @objc func flowAutoRotateChanged(_ sender: FlowSwitchControl) {
        canvas?.flowAutoRotateEnabled = sender.isOn
    }

    @MainActor @objc func flowIntervalChanged(_ sender: FlowNumberStepper) {
        canvas?.flowRotationInterval = sender.doubleValue
    }

    @MainActor @objc func flowDuplicateChanged(_ sender: FlowSwitchControl) {
        canvas?.flowAllowsRandomDuplicates = sender.isOn
    }

    @MainActor @objc func syncFlowControls() {
        guard let canvas else { return }
        flowHeaderView?.needsDisplay = true
        flowPoolCountLabel?.stringValue = "\(canvas.items.count)/\(canvas.items.count) enabled"
        flowMaxStepper?.integerValue = canvas.flowMaxVisibleItems
        flowModeControl?.selectedIndex = canvas.flowRotationMode.rawValue
        flowAutoRotateButton?.isOn = canvas.flowAutoRotateEnabled
        flowIntervalStepper?.doubleValue = canvas.flowRotationInterval
        flowDuplicateButton?.isOn = canvas.flowAllowsRandomDuplicates
        flowDuplicateButton?.isEnabled = canvas.flowRotationMode == .random
        flowDuplicateButton?.needsDisplay = true
        flowGridView?.reloadData()
    }

}
