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

final class FlowLibraryGridView: NSView {
    weak var canvas: MetalCollageView?
    private let thumbnailCache = FlowThumbnailCache()
    private let tileSize = CGSize(width: 146, height: 100)
    private let gap: CGFloat = 8

    override var isFlipped: Bool { true }

    func reloadData() {
        let width = max(300, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        let columns = max(1, Int((width + gap) / (tileSize.width + gap)))
        let count = max(1, canvas?.items.count ?? 0)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * gap + 4
        setFrameSize(CGSize(width: width, height: max(height, enclosingScrollView?.contentView.bounds.height ?? height)))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reloadData()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let canvas, !canvas.items.isEmpty else {
            drawEmptyState()
            return
        }

        let activeCounts = canvas.visibleIndexCounts()
        let selectedIndex = canvas.selectedLibraryIndex()
        for index in canvas.items.indices {
            let rect = tileRect(for: index)
            guard rect.intersects(dirtyRect) else { continue }
            drawTile(item: canvas.items[index], index: index, rect: rect, activeCount: activeCounts[index] ?? 0, selected: selectedIndex == index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = itemIndex(at: point), canvas.items.indices.contains(index) else { return }
        if event.clickCount >= 2 {
            canvas.revealLibraryItem(at: index)
        } else {
            canvas.selectLibraryItem(at: index)
        }
        needsDisplay = true
    }

    private func drawEmptyState() {
        let text = "No media loaded"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: bounds.insetBy(dx: 18, dy: max(18, bounds.height / 2 - 10)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: FlowLibraryStyle.secondaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawTile(item: CollageItem, index: Int, rect: CGRect, activeCount: Int, selected: Bool) {
        let tile = rect.integral.insetBy(dx: 0.5, dy: 0.5)
        drawPlaceholder(for: item, in: tile, index: index)
        if let image = thumbnailCache.thumbnail(for: item, redraw: { [weak self] in self?.needsDisplay = true }) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).setClip()
            drawAspectFill(image, in: tile)
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.08),
                NSColor.black.withAlphaComponent(0.62)
            ])?.draw(in: tile, angle: 270)
            NSGraphicsContext.restoreGraphicsState()
        }

        let strokeColor = activeCount > 0 || selected ? FlowLibraryStyle.accent : NSColor.white.withAlphaComponent(0.09)
        strokeColor.setStroke()
        let border = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
        border.lineWidth = activeCount > 0 || selected ? 1.8 : 1
        border.stroke()

        drawBadge(item.kind == .video ? "VIDEO" : "IMAGE", in: CGRect(x: tile.minX + 7, y: tile.minY + 7, width: item.kind == .video ? 52 : 54, height: 17))
        drawActiveBadge(activeCount: activeCount, selected: selected, in: CGRect(x: tile.maxX - 25, y: tile.minY + 7, width: 18, height: 18))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingMiddle
        item.name.draw(in: CGRect(x: tile.minX + 8, y: tile.maxY - 22, width: tile.width - 16, height: 14), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: FlowLibraryStyle.primaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : rect.size
        let imageAspect = imageSize.width / max(1, imageSize.height)
        let rectAspect = rect.width / max(1, rect.height)
        var source = CGRect(origin: .zero, size: imageSize)
        if imageAspect > rectAspect {
            let width = imageSize.height * rectAspect
            source.origin.x = (imageSize.width - width) / 2
            source.size.width = width
        } else {
            let height = imageSize.width / rectAspect
            source.origin.y = (imageSize.height - height) / 2
            source.size.height = height
        }
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawPlaceholder(for item: CollageItem, in rect: CGRect, index: Int) {
        let colors = FlowLibraryStyle.tilePalettes[index % FlowLibraryStyle.tilePalettes.count]
        FlowLibraryStyle.drawRoundedGradient(in: rect, colors: colors, radius: 8)

        let highlight = CGRect(x: rect.minX - rect.width * 0.18, y: rect.minY - rect.height * 0.15, width: rect.width * 1.2, height: rect.height * 0.9)
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.00)
        ])?.draw(in: highlight, relativeCenterPosition: CGPoint(x: -0.15, y: -0.20))

        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    private func drawBadge(_ text: String, in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.44).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 4, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ])
    }

    private func drawActiveBadge(activeCount: Int, selected: Bool, in rect: CGRect) {
        guard activeCount > 0 || selected else { return }
        FlowLibraryStyle.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let text = activeCount > 1 ? "\(activeCount)" : "✓"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 1, dy: activeCount > 1 ? 2 : 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: activeCount > 1 ? 10 : 12, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
            .paragraphStyle: paragraph
        ])
    }

    private func itemIndex(at point: CGPoint) -> Int? {
        guard let canvas else { return nil }
        for index in canvas.items.indices where tileRect(for: index).contains(point) {
            return index
        }
        return nil
    }

    private func tileRect(for index: Int) -> CGRect {
        let columns = max(1, Int((max(1, bounds.width) + gap) / (tileSize.width + gap)))
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: CGFloat(column) * (tileSize.width + gap),
            y: CGFloat(row) * (tileSize.height + gap),
            width: tileSize.width,
            height: tileSize.height
        )
    }
}
