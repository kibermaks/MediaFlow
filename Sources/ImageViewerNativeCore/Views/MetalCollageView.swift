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

final class MetalCollageView: MTKView {
    var items: [CollageItem] = []
    var visibleSlots: [FlowSlot] = []
    var panItem: CollageItem?
    var activeCropRect: CGRect?
    var isDraggingMedia = false
    weak var soloVideoItem: CollageItem?

    let textureLoader: MTKTextureLoader
    let imageContext: CIContext
    let imageCommandQueue: MTLCommandQueue?
    let mediaWorkingColorSpace: CGColorSpace
    let mediaStandardColorSpace: CGColorSpace
    let mediaLinearStandardColorSpace: CGColorSpace
    let mediaDisplayColorSpace: CGColorSpace
    let renderer: MetalRenderer
    let overlay = OverlayView()
    let toolPanel = NSVisualEffectView()
    let toolStack = NSStackView()
    let videoPanel = MediaControlBarView()
    let videoStack = NSStackView()
    let timelineView = VideoTimelineView()
    let speedLabel = NSTextField(labelWithString: "1.00x")
    let volumeLabel = NSTextField(labelWithString: "Vol 100%")
    let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    let muteButton = NSButton(title: "", target: nil, action: nil)
    let soloButton = NSButton(title: "", target: nil, action: nil)
    let playButton = NSButton(title: "", target: nil, action: nil)
    let restoreABButton = NSButton(title: "", target: nil, action: nil)
    var uiTimer: Timer?
    var flowTimer: Timer?
    var flowVisibleIndexes: [Int] = []
    var flowCursor = 0
    var hoverItem: CollageItem?
    var lastMousePoint: CGPoint?
    var hoverToolPanelEnabled = false
    var tracking: NSTrackingArea?
    var isAddFilesPanelOpen = false

    var cropMode = false
    var cropStart: CGPoint?
    weak var cropTarget: CollageItem?
    var panDrag: (item: CollageItem, start: CGPoint, pan: CGPoint)?
    weak var temporaryPanItem: CollageItem?
    weak var pendingSelectionToggleItem: CollageItem?
    var didPanDragItem = false
    var dragStart: CGPoint?
    weak var dragItem: CollageItem?
    var didDragItem = false
    var qualityEditsDefaults = false
    var debugFrameCount = 0
    var debugLastSampleTime = CACurrentMediaTime()
    private(set) var debugFramesPerSecond: Double = 0
    private(set) var debugCPUPercent: Double = 0

    var flowMaxVisibleItems: Int = FlowSettingsStore.maxVisibleItems {
        didSet {
            flowMaxVisibleItems = max(1, min(64, flowMaxVisibleItems))
            guard oldValue != flowMaxVisibleItems else { return }
            FlowSettingsStore.maxVisibleItems = flowMaxVisibleItems
            resetFlowSelection()
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var flowRotationMode: FlowRotationMode = FlowSettingsStore.rotationMode {
        didSet {
            guard oldValue != flowRotationMode else { return }
            FlowSettingsStore.rotationMode = flowRotationMode
            resetFlowSelection()
            postFlowSettingsChanged()
        }
    }

    var flowAllowsRandomDuplicates: Bool = FlowSettingsStore.allowsRandomDuplicates {
        didSet {
            guard oldValue != flowAllowsRandomDuplicates else { return }
            FlowSettingsStore.allowsRandomDuplicates = flowAllowsRandomDuplicates
            resetFlowSelection()
            postFlowSettingsChanged()
        }
    }

    var flowAutoRotateEnabled: Bool = FlowSettingsStore.autoRotateEnabled {
        didSet {
            guard oldValue != flowAutoRotateEnabled else { return }
            FlowSettingsStore.autoRotateEnabled = flowAutoRotateEnabled
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var flowRotationInterval: TimeInterval = FlowSettingsStore.rotationInterval {
        didSet {
            flowRotationInterval = max(4, min(600, flowRotationInterval))
            guard oldValue != flowRotationInterval else { return }
            FlowSettingsStore.rotationInterval = flowRotationInterval
            restartFlowTimer()
            postFlowSettingsChanged()
        }
    }

    var metalQualityMode: MetalQualityMode = MetalQualityMode(rawValue: DefaultQualityStore.qualityModeRaw) ?? .best {
        didSet {
            guard oldValue != metalQualityMode else { return }
            DefaultQualityStore.qualityModeRaw = metalQualityMode.rawValue
            renderer.qualityMode = metalQualityMode
            needsDisplay = true
            NotificationCenter.default.post(name: .metalQualityModeChanged, object: self)
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var frameInterpolationEnabled: Bool = FrameInterpolationStore.enabled {
        didSet {
            guard oldValue != frameInterpolationEnabled else { return }
            FrameInterpolationStore.enabled = frameInterpolationEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var naturalDenoiseEnabled: Bool = NaturalDenoiseStore.enabled {
        didSet {
            guard oldValue != naturalDenoiseEnabled else { return }
            NaturalDenoiseStore.enabled = naturalDenoiseEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var naturalDenoiseStrength: Float = NaturalDenoiseStore.strength {
        didSet {
            naturalDenoiseStrength = max(0, min(1, naturalDenoiseStrength))
            guard oldValue != naturalDenoiseStrength else { return }
            NaturalDenoiseStore.strength = naturalDenoiseStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var toneRecoveryEnabled: Bool = ToneRecoveryStore.enabled {
        didSet {
            guard oldValue != toneRecoveryEnabled else { return }
            ToneRecoveryStore.enabled = toneRecoveryEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var toneRecoveryStrength: Float = ToneRecoveryStore.strength {
        didSet {
            toneRecoveryStrength = max(0, min(1, toneRecoveryStrength))
            guard oldValue != toneRecoveryStrength else { return }
            ToneRecoveryStore.strength = toneRecoveryStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var brightnessBoost: Float = BrightnessBoostStore.strength {
        didSet {
            brightnessBoost = max(0, min(1, brightnessBoost))
            guard oldValue != brightnessBoost else { return }
            BrightnessBoostStore.strength = brightnessBoost
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var magicRescueEnabled: Bool = MagicRescueStore.enabled {
        didSet {
            guard oldValue != magicRescueEnabled else { return }
            MagicRescueStore.enabled = magicRescueEnabled
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var magicRescueStrength: Float = MagicRescueStore.strength {
        didSet {
            magicRescueStrength = max(0, min(1, magicRescueStrength))
            guard oldValue != magicRescueStrength else { return }
            MagicRescueStore.strength = magicRescueStrength
            needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var splitCompareEnabled: Bool = SplitCompareStore.enabled {
        didSet {
            guard oldValue != splitCompareEnabled else { return }
            SplitCompareStore.enabled = splitCompareEnabled
            renderer.splitCompareEnabled = splitCompareEnabled
            needsDisplay = true
            overlay.needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var splitCompareReversed: Bool = SplitCompareStore.reversed {
        didSet {
            guard oldValue != splitCompareReversed else { return }
            SplitCompareStore.reversed = splitCompareReversed
            renderer.splitCompareReversed = splitCompareReversed
            needsDisplay = true
            overlay.needsDisplay = true
            NotificationCenter.default.post(name: .qualitySettingsChanged, object: self)
        }
    }

    var debugInformationEnabled: Bool = DebugInformationStore.enabled {
        didSet {
            guard oldValue != debugInformationEnabled else { return }
            DebugInformationStore.enabled = debugInformationEnabled
            resetDebugInformationMetrics()
            overlay.needsDisplay = true
            needsDisplay = true
        }
    }

    init(frame frameRect: NSRect, device: MTLDevice) {
        self.textureLoader = MTKTextureLoader(device: device)
        let standardColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let linearStandardColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? standardColorSpace
        let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? linearStandardColorSpace
        self.mediaWorkingColorSpace = workingColorSpace
        self.mediaStandardColorSpace = standardColorSpace
        self.mediaLinearStandardColorSpace = linearStandardColorSpace
        self.mediaDisplayColorSpace = displayColorSpace
        self.imageContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: displayColorSpace
        ])
        self.imageCommandQueue = device.makeCommandQueue()
        guard let renderer = MetalRenderer(device: device, colorPixelFormat: .rgba16Float) else {
            fatalError("Metal is not available on this Mac.")
        }
        self.renderer = renderer
        super.init(frame: frameRect, device: device)

        colorPixelFormat = .rgba16Float
        clearColor = MTLClearColor(red: 0.025, green: 0.025, blue: 0.025, alpha: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        delegate = renderer
        renderer.canvas = self
        renderer.splitCompareEnabled = splitCompareEnabled
        renderer.splitCompareReversed = splitCompareReversed

        wantsLayer = true
        syncDisplayColorState()
        registerForDraggedTypes([.fileURL])

        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        setupToolPanel()
        setupVideoPanel()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickVideoUI()
            }
        }
        restartFlowTimer()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDebugInformationEnabled(_ enabled: Bool) {
        debugInformationEnabled = enabled
    }

    func recordRenderedFrame() {
        guard debugInformationEnabled else { return }
        debugFrameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - debugLastSampleTime
        guard elapsed >= 0.5 else { return }

        debugFramesPerSecond = Double(debugFrameCount) / elapsed
        debugCPUPercent = ProcessCPUUsage.currentPercent()
        debugFrameCount = 0
        debugLastSampleTime = now
        overlay.needsDisplay = true
    }

    func resetDebugInformationMetrics() {
        debugFrameCount = 0
        debugLastSampleTime = CACurrentMediaTime()
        debugFramesPerSecond = 0
        debugCPUPercent = debugInformationEnabled ? ProcessCPUUsage.currentPercent() : 0
    }

    func syncDisplayColorState() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let displayedItems = visibleSlots.isEmpty ? items : visibleSlots.map(\.item)
        let layerMode = layerOutputMode(for: displayedItems)

        metalLayer.colorspace = layerColorSpace(for: layerMode)
        metalLayer.wantsExtendedDynamicRangeContent = layerMode.usesEDR
        syncVisibleMediaColorOutputs(for: layerMode.canvasColorMode, items: displayedItems)

        guard CAEDRMetadata.isAvailable else {
            metalLayer.edrMetadata = nil
            return
        }

        switch layerMode.edrMetadataRange {
        case .hlg:
            metalLayer.edrMetadata = CAEDRMetadata.hlg
        case .pq:
            metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0, maxLuminance: 1000, opticalOutputScale: 100)
        case .standard, .wide, .adaptiveHDR:
            metalLayer.edrMetadata = nil
        }
    }

    struct LayerOutputMode {
        var dynamicRange: MediaDynamicRange
        var canvasColorMode: CanvasColorMode

        var usesEDR: Bool {
            canvasColorMode == .linearDisplayP3
        }

        var edrMetadataRange: MediaDynamicRange {
            usesEDR ? dynamicRange : .standard
        }
    }

    func layerOutputMode(for items: [CollageItem]) -> LayerOutputMode {
        guard !items.isEmpty else {
            return LayerOutputMode(dynamicRange: .standard, canvasColorMode: .displayP3)
        }
        let dynamicRange = items
            .map(\.dynamicRange)
            .max { $0.priority < $1.priority } ?? .standard
        return LayerOutputMode(dynamicRange: dynamicRange, canvasColorMode: dynamicRange.canvasColorMode)
    }

    func layerColorSpace(for layerMode: LayerOutputMode) -> CGColorSpace? {
        colorSpace(for: layerMode.canvasColorMode)
    }

    func colorSpace(for canvasColorMode: CanvasColorMode) -> CGColorSpace {
        switch canvasColorMode {
        case .displayP3:
            return mediaDisplayColorSpace
        case .linearDisplayP3:
            return mediaWorkingColorSpace
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
}
