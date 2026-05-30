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

final class OverlayView: NSView {
    weak var canvas: MetalCollageView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }

        if canvas.items.isEmpty {
            drawEmptyState(in: bounds, isDragging: canvas.isDraggingMedia)
            if canvas.debugInformationEnabled {
                drawDebugInformation(fps: canvas.debugFramesPerSecond, cpuPercent: canvas.debugCPUPercent, in: bounds)
            }
            return
        }

        if canvas.splitCompareEnabled {
            drawSplitCompareOverlay(in: bounds, reversed: canvas.splitCompareReversed)
        }

        for slot in canvas.visibleSlots where canvas.panItem === slot.item || (slot.item.selected && canvas.visibleSlots.count > 1) {
            let color = canvas.panItem === slot.item ? NSColor.systemOrange : NSColor.systemTeal
            color.setStroke()
            let path = NSBezierPath(roundedRect: slot.cellRect, xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            path.stroke()
        }

        for slot in canvas.visibleSlots where slot.item.kind == .video {
            drawVideoBadges(for: slot.item, in: slot.cellRect, solo: canvas.soloVideoItem === slot.item)
        }

        if let rect = canvas.activeCropRect {
            NSColor.systemTeal.withAlphaComponent(0.16).setFill()
            rect.fill()
            NSColor.systemTeal.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.setLineDash([7, 5], count: 2, phase: 0)
            path.stroke()
        }

        if canvas.debugInformationEnabled {
            drawDebugInformation(fps: canvas.debugFramesPerSecond, cpuPercent: canvas.debugCPUPercent, in: bounds)
        }
    }

    private func drawDebugInformation(fps: Double, cpuPercent: Double, in rect: CGRect) {
        let safeFPS = fps.isFinite && fps > 0 ? fps : 0
        let safeCPU = cpuPercent.isFinite ? max(0, min(999, cpuPercent)) : 0
        let fpsText = safeFPS > 0 ? String(format: "FPS %.1f", safeFPS) : "FPS --"
        let text = "\(fpsText)   App CPU \(Int(safeCPU.rounded()))%"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let badge = CGRect(
            x: rect.minX + 14,
            y: max(rect.minY + 14, rect.maxY - 38),
            width: ceil(textSize.width) + 20,
            height: 24
        )

        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.8
        border.stroke()

        text.draw(in: badge.insetBy(dx: 10, dy: 5), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.90)
        ])
    }

    private func drawSplitCompareOverlay(in rect: CGRect, reversed: Bool) {
        let dividerX = rect.midX
        NSColor.white.withAlphaComponent(0.76).setStroke()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: dividerX, y: rect.minY))
        divider.line(to: CGPoint(x: dividerX, y: rect.maxY))
        divider.lineWidth = 1
        divider.stroke()

        let leftLabel = reversed ? "B QUALITY" : "A RAW"
        let rightLabel = reversed ? "A RAW" : "B QUALITY"
        drawPill(leftLabel, at: CGPoint(x: max(rect.minX + 58, dividerX - 62), y: rect.maxY - 30), color: reversed ? .systemTeal : .secondaryLabelColor)
        drawPill(rightLabel, at: CGPoint(x: min(rect.maxX - 72, dividerX + 78), y: rect.maxY - 30), color: reversed ? .secondaryLabelColor : .systemTeal)
    }

    private func drawPill(_ text: String, at center: CGPoint, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: center.x - textSize.width / 2 - 9, y: center.y - 8, width: textSize.width + 18, height: 17)
        NSColor.black.withAlphaComponent(0.56).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        color.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.8
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 4, dy: 2), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ])
    }

    private func drawVideoBadges(for item: CollageItem, in cellRect: CGRect, solo: Bool) {
        var labels: [(String, NSColor)] = []
        if !item.abLoops.isEmpty {
            labels.append(("A-B", .systemOrange))
        }
        if !item.isVideoPlaying {
            labels.append(("Pause", .secondaryLabelColor))
        }
        if solo {
            labels.append(("Solo", .systemTeal))
        }
        guard !labels.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let gap: CGFloat = 4
        var x = cellRect.maxX - 8
        let y = cellRect.maxY - 22

        for (label, color) in labels.reversed() {
            let textSize = (label as NSString).size(withAttributes: [.font: font])
            let badge = CGRect(x: x - textSize.width - 14, y: y, width: textSize.width + 14, height: 16)
            x = badge.minX - gap

            NSColor.black.withAlphaComponent(0.56).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            color.withAlphaComponent(0.88).setStroke()
            let border = NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7)
            border.lineWidth = 0.8
            border.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            label.draw(in: badge.insetBy(dx: 5, dy: 1.5), withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                .paragraphStyle: paragraph
            ])
        }
    }

    private func drawEmptyState(in rect: CGRect, isDragging: Bool) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.020, green: 0.023, blue: 0.027, alpha: 1),
            NSColor(calibratedRed: 0.040, green: 0.050, blue: 0.058, alpha: 1)
        ])?.draw(in: rect, angle: 90)

        let scale = max(0.78, min(1.0, min(rect.width / 980, rect.height / 720)))
        let panelWidth = min(rect.width - 48, max(420, 560 * scale))
        let panelHeight = max(250, 292 * scale)
        let panel = CGRect(
            x: rect.midX - panelWidth / 2,
            y: rect.midY - panelHeight / 2,
            width: panelWidth,
            height: panelHeight
        )

        let accent = isDragging ? NSColor.systemTeal : NSColor(calibratedRed: 0.38, green: 0.72, blue: 0.78, alpha: 1)
        let fill = NSColor.white.withAlphaComponent(isDragging ? 0.095 : 0.055)
        fill.setFill()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22)
        panelPath.fill()

        accent.withAlphaComponent(isDragging ? 0.80 : 0.36).setStroke()
        panelPath.lineWidth = isDragging ? 2.5 : 1.2
        if !isDragging {
            panelPath.setLineDash([8, 7], count: 2, phase: 0)
        }
        panelPath.stroke()

        drawEmptyGlyph(in: CGRect(x: panel.midX - 72 * scale, y: panel.maxY - 118 * scale, width: 144 * scale, height: 80 * scale), accent: accent, scale: scale)

        let title = isDragging ? "Release to Add" : "Drop Images or Videos"
        drawCentered(
            title,
            in: CGRect(x: panel.minX + 32, y: panel.midY - 8 * scale, width: panel.width - 64, height: 34),
            font: .systemFont(ofSize: 26 * scale, weight: .semibold),
            color: .white
        )

        drawCentered(
            "File -> Add Files (Cmd-O)  •  Quality Controls (Cmd-K)",
            in: CGRect(x: panel.minX + 34, y: panel.midY - 44 * scale, width: panel.width - 68, height: 22),
            font: .systemFont(ofSize: 13 * scale, weight: .medium),
            color: NSColor.white.withAlphaComponent(0.58)
        )

        drawCentered(
            "Load Playback (Cmd-L) and Recent Playbacks are in File",
            in: CGRect(x: panel.minX + 34, y: panel.midY - 72 * scale, width: panel.width - 68, height: 20),
            font: .systemFont(ofSize: 12 * scale, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.38)
        )
    }

    private func drawEmptyGlyph(in rect: CGRect, accent: NSColor, scale: CGFloat) {
        let tileSize = CGSize(width: 62 * scale, height: 46 * scale)
        let tiles: [(CGPoint, CGFloat, NSColor)] = [
            (CGPoint(x: rect.minX + 12 * scale, y: rect.minY + 18 * scale), -9, NSColor(calibratedRed: 0.07, green: 0.55, blue: 0.66, alpha: 1)),
            (CGPoint(x: rect.midX - tileSize.width / 2, y: rect.minY + 30 * scale), 0, NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.88, alpha: 1)),
            (CGPoint(x: rect.maxX - tileSize.width - 12 * scale, y: rect.minY + 18 * scale), 9, NSColor(calibratedRed: 0.12, green: 0.33, blue: 0.55, alpha: 1))
        ]

        for (origin, degrees, color) in tiles {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: origin.x + tileSize.width / 2, yBy: origin.y + tileSize.height / 2)
            transform.rotate(byDegrees: degrees)
            transform.translateX(by: -tileSize.width / 2, yBy: -tileSize.height / 2)
            transform.concat()

            let tile = CGRect(origin: .zero, size: tileSize)
            color.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 10 * scale, yRadius: 10 * scale).fill()
            NSColor.white.withAlphaComponent(0.36).setStroke()
            let stroke = NSBezierPath(roundedRect: tile, xRadius: 10 * scale, yRadius: 10 * scale)
            stroke.lineWidth = 1.2
            stroke.stroke()

            accent.withAlphaComponent(0.42).setStroke()
            let horizon = NSBezierPath()
            horizon.move(to: CGPoint(x: 10 * scale, y: 16 * scale))
            horizon.line(to: CGPoint(x: 26 * scale, y: 28 * scale))
            horizon.line(to: CGPoint(x: 38 * scale, y: 20 * scale))
            horizon.line(to: CGPoint(x: 52 * scale, y: 32 * scale))
            horizon.lineWidth = 2
            horizon.stroke()

            NSGraphicsContext.restoreGraphicsState()
        }

        let playRect = CGRect(x: rect.midX - 13 * scale, y: rect.minY - 1 * scale, width: 30 * scale, height: 30 * scale)
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: playRect.insetBy(dx: -7 * scale, dy: -7 * scale)).fill()
        NSColor.white.withAlphaComponent(0.88).setFill()
        let play = NSBezierPath()
        play.move(to: CGPoint(x: playRect.minX + 9 * scale, y: playRect.minY + 6 * scale))
        play.line(to: CGPoint(x: playRect.maxX - 6 * scale, y: playRect.midY))
        play.line(to: CGPoint(x: playRect.minX + 9 * scale, y: playRect.maxY - 6 * scale))
        play.close()
        play.fill()
    }

    private func drawCentered(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

final class VideoTimelineView: NSView {
    weak var canvas: MetalCollageView?
    weak var item: CollageItem?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let duration = max(0.001, item.durationSeconds)
        let track = bounds.insetBy(dx: 8, dy: bounds.height * 0.34)

        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        for (index, loop) in item.abLoops.enumerated() {
            let x0 = track.minX + track.width * CGFloat(loop.a / duration)
            let x1 = track.minX + track.width * CGFloat(loop.b / duration)
            let rect = CGRect(x: min(x0, x1), y: track.minY, width: max(2, abs(x1 - x0)), height: track.height)
            NSColor.systemOrange.withAlphaComponent(0.62).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            drawLoopLabels(index: index + 1, startX: min(x0, x1), endX: max(x0, x1), track: track)
        }

        if let a = item.pendingA {
            drawMarker("A", at: a, duration: duration, track: track, color: .systemTeal)
        }
        if let b = item.pendingB {
            drawMarker("B", at: b, duration: duration, track: track, color: .systemPink)
        }

        let progress = max(0, min(1, item.currentTimeSeconds / duration))
        let progressRect = CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(progress), height: track.height)
        FlowLibraryStyle.accent.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: progressRect, xRadius: 4, yRadius: 4).fill()

        let knobX = track.minX + track.width * CGFloat(progress)
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: CGRect(x: knobX - 5, y: track.midY - 5, width: 10, height: 10)).fill()
    }

    private func drawLoopLabels(index: Int, startX: CGFloat, endX: CGFloat, track: CGRect) {
        drawPin("A", x: startX, y: track.maxY + 2, color: .systemOrange)
        drawPin("B", x: endX, y: track.maxY + 2, color: .systemOrange)
        guard endX - startX > 38 else { return }
        let label = "\(index)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let rect = CGRect(x: (startX + endX) / 2 - 8, y: track.minY - 1.5, width: 16, height: track.height + 3)
        NSColor.black.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.draw(in: rect.insetBy(dx: 1, dy: 1), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .paragraphStyle: paragraph
        ])
    }

    private func drawMarker(_ label: String, at seconds: Double, duration: Double, track: CGRect, color: NSColor) {
        let x = track.minX + track.width * CGFloat(max(0, min(1, seconds / duration)))
        color.withAlphaComponent(0.9).setFill()
        CGRect(x: x - 1, y: track.minY - 4, width: 2, height: track.height + 8).fill()
        drawPin(label, x: x, y: track.maxY + 2, color: color)
    }

    private func drawPin(_ label: String, x: CGFloat, y: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let clampedX = max(bounds.minX + 8, min(bounds.maxX - 8, x))
        let rect = CGRect(x: clampedX - 8, y: min(bounds.maxY - 12, y), width: 16, height: 12)
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        color.withAlphaComponent(0.96).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        border.lineWidth = 0.8
        border.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.draw(in: rect.insetBy(dx: 1, dy: 0.5), withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
    }

    override func mouseDown(with event: NSEvent) {
        scrub(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(with: event)
    }

    private func scrub(with event: NSEvent) {
        guard let item, item.durationSeconds > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = bounds.insetBy(dx: 8, dy: bounds.height * 0.34)
        let pct = max(0, min(1, (point.x - track.minX) / max(1, track.width)))
        canvas?.suspendABLoop(for: item, seconds: 5)
        canvas?.resetVideoFrameHistory(for: item)
        item.player?.seek(to: CMTime(seconds: item.durationSeconds * Double(pct), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }
}

final class MediaControlBarView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.controlPanelFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()

        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        border.lineWidth = 1
        border.stroke()
    }
}
