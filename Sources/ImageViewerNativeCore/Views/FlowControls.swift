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

final class FlowHeaderCardView: NSView {
    weak var canvas: MetalCollageView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.cardFill.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        let loaded = canvas?.items.count ?? 0
        let visible = canvas?.visibleSlots.count ?? 0
        let circle = CGRect(x: 13, y: 12, width: 32, height: 32)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: circle).fill()
        FlowLibraryStyle.accent.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2.5
        ring.stroke()

        let number = "\(max(visible, 0))"
        let numberParagraph = NSMutableParagraphStyle()
        numberParagraph.alignment = .center
        number.draw(in: circle.insetBy(dx: 2, dy: 7), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText,
            .paragraphStyle: numberParagraph
        ])

        let title = "\(visible) on screen - \(loaded) loaded"
        title.draw(in: CGRect(x: 56, y: 13, width: bounds.width - 68, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText
        ])

        let mode = canvas?.flowRotationMode.displayName ?? "Round Robin"
        let interval = Int((canvas?.flowRotationInterval ?? 20).rounded())
        let subtitle = canvas?.flowAutoRotateEnabled == true ? "\(mode) - rotates every \(interval)s" : "\(mode) - manual advance"
        subtitle.draw(in: CGRect(x: 56, y: 31, width: bounds.width - 68, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: FlowLibraryStyle.secondaryText
        ])
    }
}

final class FlowSwitchControl: NSControl {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let trackColors = isOn && isEnabled
            ? [FlowLibraryStyle.accent, FlowLibraryStyle.accentBlue]
            : [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.10)]
        FlowLibraryStyle.drawRoundedGradient(in: rect, colors: trackColors, radius: rect.height / 2)
        let knobDiameter = rect.height - 4
        let knobX = isOn ? rect.maxX - knobDiameter - 2 : rect.minX + 2
        NSColor.white.withAlphaComponent(isEnabled ? 0.96 : 0.45).setFill()
        NSBezierPath(ovalIn: CGRect(x: knobX, y: rect.minY + 2, width: knobDiameter, height: knobDiameter)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }
}

final class FlowSegmentedControl: NSControl {
    var segments: [String] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 300, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()

        guard !segments.isEmpty else { return }
        let segmentWidth = rect.width / CGFloat(segments.count)
        for index in segments.indices {
            let segmentRect = CGRect(x: rect.minX + CGFloat(index) * segmentWidth, y: rect.minY, width: segmentWidth, height: rect.height)
            if index == selectedIndex {
                NSColor.white.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: segmentRect.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
            }
            if index > 0 {
                NSColor.white.withAlphaComponent(0.08).setStroke()
                let divider = NSBezierPath()
                divider.move(to: CGPoint(x: segmentRect.minX, y: rect.minY + 6))
                divider.line(to: CGPoint(x: segmentRect.minX, y: rect.maxY - 6))
                divider.lineWidth = 1
                divider.stroke()
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            segments[index].draw(in: segmentRect.insetBy(dx: 3, dy: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .medium),
                .foregroundColor: index == selectedIndex ? FlowLibraryStyle.primaryText : FlowLibraryStyle.secondaryText,
                .paragraphStyle: paragraph
            ])
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !segments.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = min(segments.count - 1, max(0, Int(point.x / max(1, bounds.width) * CGFloat(segments.count))))
        guard index != selectedIndex else { return }
        selectedIndex = index
        sendAction(action, to: target)
    }
}

final class FlowNumberStepper: NSControl {
    var minimumValue: Double = 0
    var maximumValue: Double = 100
    var stepValue: Double = 1
    var suffix = ""
    private var value: Double = 0

    override var doubleValue: Double {
        get { value }
        set { setDoubleValue(newValue, notify: false) }
    }

    override var integerValue: Int {
        get { Int(value.rounded()) }
        set { setDoubleValue(Double(newValue), notify: false) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 64, height: 30)
    }

    func setDoubleValue(_ newValue: Double, notify: Bool) {
        value = max(minimumValue, min(maximumValue, newValue))
        needsDisplay = true
        if notify {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 1
        border.stroke()

        let valueRect = CGRect(x: rect.minX + 8, y: rect.minY + 7, width: rect.width - 28, height: 16)
        let valueText = "\(Int(value.rounded()))\(suffix)"
        valueText.draw(in: valueRect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText
        ])

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: rect.maxX - 21, y: rect.minY + 5))
        divider.line(to: CGPoint(x: rect.maxX - 21, y: rect.maxY - 5))
        divider.stroke()

        drawChevron(up: true, in: CGRect(x: rect.maxX - 18, y: rect.minY + 5, width: 14, height: 8))
        drawChevron(up: false, in: CGRect(x: rect.maxX - 18, y: rect.midY + 2, width: 14, height: 8))
    }

    private func drawChevron(up: Bool, in rect: CGRect) {
        let path = NSBezierPath()
        if up {
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 2))
            path.line(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 2))
        } else {
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + 2))
            path.line(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 2))
        }
        path.lineWidth = 1.2
        FlowLibraryStyle.secondaryText.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.y > bounds.midY ? stepValue : -stepValue
        setDoubleValue(value + delta, notify: true)
    }
}

final class FlowSliderControl: NSControl {
    var minimumValue: Double = 0 {
        didSet { setDoubleValue(value, notify: false) }
    }
    var maximumValue: Double = 1 {
        didSet { setDoubleValue(value, notify: false) }
    }
    private var value: Double = 0

    override var doubleValue: Double {
        get { value }
        set { setDoubleValue(newValue, notify: false) }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 28)
    }

    func setDoubleValue(_ newValue: Double, notify: Bool) {
        value = max(minimumValue, min(maximumValue, newValue))
        needsDisplay = true
        if notify {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.42
        let track = CGRect(x: bounds.minX + 4, y: bounds.midY - 3, width: bounds.width - 8, height: 6)
        FlowLibraryStyle.controlFill.withAlphaComponent(0.82 * alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        FlowLibraryStyle.controlStroke.withAlphaComponent(alpha).setStroke()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).stroke()

        let progress = CGFloat((value - minimumValue) / max(0.0001, maximumValue - minimumValue))
        let fillWidth = max(6, track.width * progress)
        let fillRect = CGRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
        FlowLibraryStyle.drawRoundedGradient(
            in: fillRect,
            colors: [
                FlowLibraryStyle.accent.withAlphaComponent(alpha),
                FlowLibraryStyle.accentBlue.withAlphaComponent(alpha)
            ],
            radius: 3
        )

        let knobDiameter: CGFloat = 18
        let knobX = track.minX + track.width * progress - knobDiameter / 2
        let knobRect = CGRect(x: max(bounds.minX + 1, min(bounds.maxX - knobDiameter - 1, knobX)), y: bounds.midY - knobDiameter / 2, width: knobDiameter, height: knobDiameter)
        NSColor.black.withAlphaComponent(0.26 * alpha).setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSColor.white.withAlphaComponent(0.94 * alpha).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        updateValue(with: event)
    }

    private func updateValue(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let ratio = max(0, min(1, (point.x - 4) / max(1, bounds.width - 8)))
        setDoubleValue(minimumValue + Double(ratio) * (maximumValue - minimumValue), notify: true)
    }
}

final class FlowActionButton: NSControl {
    var title: String {
        didSet {
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }
    var symbolName: String?
    var isAccent: Bool

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    init(title: String, symbolName: String?, isAccent: Bool) {
        self.title = title
        self.symbolName = symbolName
        self.isAccent = isAccent
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isAccent && isEnabled {
            FlowLibraryStyle.drawRoundedGradient(in: rect, colors: [FlowLibraryStyle.accent, FlowLibraryStyle.accentBlue], radius: 7)
        } else {
            FlowLibraryStyle.controlFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            FlowLibraryStyle.controlStroke.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            border.lineWidth = 1
            border.stroke()
        }

        let textColor = isAccent && isEnabled ? NSColor.black.withAlphaComponent(0.86) : FlowLibraryStyle.primaryText
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        var textRect = rect.insetBy(dx: 8, dy: 8)
        if let symbolName {
            let textSize = (title as NSString).size(withAttributes: [.font: font])
            let textWidth = min(textSize.width + 2, max(24, rect.width - 16 - 6 - 12))
            let totalWidth = min(rect.width - 12, 16 + 6 + textWidth)
            let iconRect = CGRect(x: rect.midX - totalWidth / 2, y: rect.midY - 7, width: 14, height: 14)
            drawSymbol(named: symbolName, in: iconRect, color: isEnabled ? textColor : FlowLibraryStyle.tertiaryText)
            textRect = CGRect(x: iconRect.maxX + 6, y: rect.minY + 8, width: textWidth, height: 16)
            paragraph.alignment = .left
        }
        title.draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: isEnabled ? textColor : FlowLibraryStyle.tertiaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawSymbol(named symbolName: String, in rect: CGRect, color: NSColor) {
        color.setStroke()
        color.setFill()

        switch symbolName {
        case "arrow.down.to.line":
            let stem = NSBezierPath()
            stem.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
            stem.line(to: CGPoint(x: rect.midX, y: rect.maxY - 5))
            stem.lineWidth = 1.6
            stem.lineCapStyle = .round
            stem.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: rect.midX - 4, y: rect.maxY - 8))
            arrow.line(to: CGPoint(x: rect.midX, y: rect.maxY - 4))
            arrow.line(to: CGPoint(x: rect.midX + 4, y: rect.maxY - 8))
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()

            let baseline = NSBezierPath()
            baseline.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 1.5))
            baseline.line(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 1.5))
            baseline.lineWidth = 1.6
            baseline.lineCapStyle = .round
            baseline.stroke()
        case "arrow.clockwise":
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: CGPoint(x: rect.midX, y: rect.midY),
                radius: min(rect.width, rect.height) * 0.36,
                startAngle: 35,
                endAngle: 315,
                clockwise: true
            )
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            arc.stroke()
            let tip = CGPoint(x: rect.maxX - 2.5, y: rect.midY - 2)
            let head = NSBezierPath()
            head.move(to: tip)
            head.line(to: CGPoint(x: tip.x - 5, y: tip.y - 1))
            head.move(to: tip)
            head.line(to: CGPoint(x: tip.x - 2, y: tip.y + 5))
            head.lineWidth = 1.6
            head.lineCapStyle = .round
            head.stroke()
        case "shuffle":
            let top = NSBezierPath()
            top.move(to: CGPoint(x: rect.minX + 1.5, y: rect.minY + 4))
            top.curve(
                to: CGPoint(x: rect.maxX - 3.5, y: rect.maxY - 4),
                controlPoint1: CGPoint(x: rect.midX - 1, y: rect.minY + 4),
                controlPoint2: CGPoint(x: rect.midX + 1, y: rect.maxY - 4)
            )
            top.lineWidth = 1.5
            top.lineCapStyle = .round
            top.stroke()

            let bottom = NSBezierPath()
            bottom.move(to: CGPoint(x: rect.minX + 1.5, y: rect.maxY - 4))
            bottom.curve(
                to: CGPoint(x: rect.maxX - 3.5, y: rect.minY + 4),
                controlPoint1: CGPoint(x: rect.midX - 1, y: rect.maxY - 4),
                controlPoint2: CGPoint(x: rect.midX + 1, y: rect.minY + 4)
            )
            bottom.lineWidth = 1.5
            bottom.lineCapStyle = .round
            bottom.stroke()

            drawArrowHead(tip: CGPoint(x: rect.maxX - 1.5, y: rect.maxY - 4), up: true)
            drawArrowHead(tip: CGPoint(x: rect.maxX - 1.5, y: rect.minY + 4), up: false)
        case "forward.end.fill":
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2.5))
            triangle.line(to: CGPoint(x: rect.maxX - 4.5, y: rect.midY))
            triangle.line(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2.5))
            triangle.close()
            triangle.fill()

            let bar = NSBezierPath(roundedRect: CGRect(x: rect.maxX - 3, y: rect.minY + 2.5, width: 1.8, height: rect.height - 5), xRadius: 0.9, yRadius: 0.9)
            bar.fill()
        default:
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            dot.fill()
        }
    }

    private func drawArrowHead(tip: CGPoint, up: Bool) {
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - 4, y: tip.y + (up ? -3 : 3)))
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - 4, y: tip.y + (up ? 3 : -3)))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}
