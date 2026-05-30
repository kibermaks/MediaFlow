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

struct PhotosImportCollection {
    let id: String
    let title: String
    let subtitle: String
    let assetCollection: PHAssetCollection?
}

final class PhotosImportHeaderView: NSView {
    var collectionTitle = "Photos Library" {
        didSet { needsDisplay = true }
    }
    var assetCount = 0 {
        didSet { needsDisplay = true }
    }
    var selectedCount = 0 {
        didSet { needsDisplay = true }
    }
    var statusMessage: String? {
        didSet { needsDisplay = true }
    }
    var isImporting = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 58)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        FlowLibraryStyle.cardFill.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        let circle = CGRect(x: 13, y: 12, width: 34, height: 34)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: circle).fill()
        FlowLibraryStyle.accent.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2.5
        ring.stroke()

        let number = "\(max(selectedCount, 0))"
        let numberParagraph = NSMutableParagraphStyle()
        numberParagraph.alignment = .center
        number.draw(in: circle.insetBy(dx: 2, dy: 8), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText,
            .paragraphStyle: numberParagraph
        ])

        let title: String
        if isImporting {
            title = "Importing from Photos"
        } else if selectedCount > 0 {
            title = "\(selectedCount) selected"
        } else {
            title = collectionTitle
        }
        title.draw(in: CGRect(x: 58, y: 13, width: bounds.width - 70, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: FlowLibraryStyle.primaryText
        ])

        let subtitle = statusMessage ?? {
            if assetCount == 0 {
                return "No local Photos assets available"
            }
            return selectedCount > 0
                ? "\(selectedCount) selected from \(assetCount) recent assets"
                : "\(assetCount) recent Photos assets"
        }()
        subtitle.draw(in: CGRect(x: 58, y: 31, width: bounds.width - 70, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: FlowLibraryStyle.secondaryText
        ])
    }
}


final class PhotosImportCollectionsView: NSView {
    var collections: [PhotosImportCollection] = [] {
        didSet {
            selectedIndex = min(selectedIndex, max(0, collections.count - 1))
            reloadData()
        }
    }
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }
    var selectionChanged: (() -> Void)?

    private let rowHeight: CGFloat = 46
    private let gap: CGFloat = 6

    override var isFlipped: Bool { true }

    var selectedCollection: PhotosImportCollection? {
        guard collections.indices.contains(selectedIndex) else { return nil }
        return collections[selectedIndex]
    }

    func reloadData() {
        let width = max(172, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        let count = max(1, collections.count)
        let height = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * gap + 12
        setFrameSize(CGSize(width: width, height: max(height, enclosingScrollView?.contentView.bounds.height ?? height)))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reloadData()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            reloadData()
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        FlowLibraryStyle.controlPanelFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
        FlowLibraryStyle.controlStroke.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()

        guard !collections.isEmpty else {
            drawCollectionText("No Collections", subtitle: nil, in: bounds.insetBy(dx: 8, dy: 8), selected: false)
            return
        }

        for index in collections.indices {
            let rect = rowRect(for: index)
            guard rect.intersects(dirtyRect) else { continue }
            drawCollection(collections[index], in: rect, selected: index == selectedIndex)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = collectionIndex(at: point), collections.indices.contains(index) else { return }
        guard index != selectedIndex else { return }
        selectedIndex = index
        selectionChanged?()
    }

    private func drawCollection(_ collection: PhotosImportCollection, in rect: CGRect, selected: Bool) {
        let row = rect.insetBy(dx: 0.5, dy: 0.5)
        if selected {
            FlowLibraryStyle.accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7).fill()
            FlowLibraryStyle.accent.withAlphaComponent(0.78).setStroke()
        } else {
            FlowLibraryStyle.controlFill.withAlphaComponent(0.54).setFill()
            NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7).fill()
            FlowLibraryStyle.controlStroke.setStroke()
        }
        let border = NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7)
        border.lineWidth = selected ? 1.2 : 1
        border.stroke()
        drawCollectionText(collection.title, subtitle: collection.subtitle, in: row, selected: selected)
    }

    private func drawCollectionText(_ title: String, subtitle: String?, in rect: CGRect, selected: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: CGRect(x: rect.minX + 10, y: rect.minY + (subtitle == nil ? 14 : 8), width: rect.width - 20, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .bold : .semibold),
            .foregroundColor: selected ? FlowLibraryStyle.primaryText : FlowLibraryStyle.primaryText.withAlphaComponent(0.86),
            .paragraphStyle: paragraph
        ])
        if let subtitle {
            subtitle.draw(in: CGRect(x: rect.minX + 10, y: rect.minY + 25, width: rect.width - 20, height: 14), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: selected ? FlowLibraryStyle.secondaryText.withAlphaComponent(0.86) : FlowLibraryStyle.secondaryText,
                .paragraphStyle: paragraph
            ])
        }
    }

    private func collectionIndex(at point: CGPoint) -> Int? {
        for index in collections.indices where rowRect(for: index).contains(point) {
            return index
        }
        return nil
    }

    private func rowRect(for index: Int) -> CGRect {
        CGRect(
            x: 6,
            y: 6 + CGFloat(index) * (rowHeight + gap),
            width: max(40, bounds.width - 12),
            height: rowHeight
        )
    }
}


final class PhotosImportGridView: NSView {
    var assets: [PHAsset] = [] {
        didSet {
            selectedAssetIDs.removeAll()
            thumbnails.removeAll()
            requestedThumbnails.removeAll()
            reloadData()
        }
    }
    var selectionChanged: (() -> Void)?

    private var selectedAssetIDs = Set<String>()
    private var thumbnails: [String: NSImage] = [:]
    private var requestedThumbnails = Set<String>()
    private let imageManager = PHCachingImageManager()
    private let minimumTileWidth: CGFloat = 104
    private let gap: CGFloat = 10

    private struct GridMetrics {
        let columns: Int
        let tileWidth: CGFloat
        let tileHeight: CGFloat
    }

    override var isFlipped: Bool { true }

    var selectedAssets: [PHAsset] {
        assets.filter { selectedAssetIDs.contains($0.localIdentifier) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reloadData()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            reloadData()
        } else {
            needsDisplay = true
        }
    }

    func clearSelection(notify: Bool = true) {
        selectedAssetIDs.removeAll()
        needsDisplay = true
        if notify {
            selectionChanged?()
        }
    }

    func reloadData() {
        let width = max(260, enclosingScrollView?.contentView.bounds.width ?? bounds.width)
        let metrics = gridMetrics(for: width)
        let count = max(1, assets.count)
        let rows = Int(ceil(Double(count) / Double(metrics.columns)))
        let height = CGFloat(rows) * metrics.tileHeight + CGFloat(max(0, rows - 1)) * gap + 12
        setFrameSize(CGSize(width: width, height: max(height, enclosingScrollView?.contentView.bounds.height ?? height)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard !assets.isEmpty else {
            drawCentered("No local Photos assets available", in: bounds)
            return
        }

        for index in assets.indices {
            let rect = tileRect(for: index)
            guard rect.intersects(dirtyRect) else { continue }
            let asset = assets[index]
            drawAsset(asset, rect: rect, selected: selectedAssetIDs.contains(asset.localIdentifier))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = assetIndex(at: point), assets.indices.contains(index) else { return }
        let id = assets[index].localIdentifier
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
        needsDisplay = true
        selectionChanged?()
    }

    private func drawAsset(_ asset: PHAsset, rect: CGRect, selected: Bool) {
        let background = selected ? FlowLibraryStyle.accent.withAlphaComponent(0.18) : FlowLibraryStyle.cardFill
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        (selected ? FlowLibraryStyle.accent : FlowLibraryStyle.controlStroke).setStroke()
        border.lineWidth = selected ? 2 : 1
        border.stroke()

        let imageRect = CGRect(x: rect.minX + 7, y: rect.minY + 7, width: rect.width - 14, height: max(70, rect.height - 38))
        FlowLibraryStyle.controlPanelFill.setFill()
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)
        imagePath.fill()
        if let image = thumbnails[asset.localIdentifier] {
            NSGraphicsContext.saveGraphicsState()
            imagePath.setClip()
            drawAspectFill(image, in: imageRect)
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0.02),
                NSColor.black.withAlphaComponent(0.36)
            ])?.draw(in: imageRect, angle: 270)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            requestThumbnail(for: asset, targetSize: imageRect.size)
            drawCentered(asset.mediaType == .video ? "VIDEO" : "PHOTO", in: imageRect)
        }

        if asset.mediaType == .video {
            drawBadge("VIDEO", in: CGRect(x: imageRect.minX + 6, y: imageRect.minY + 6, width: 42, height: 16), color: NSColor.systemOrange)
        }
        if selected {
            drawBadge("ADD", in: CGRect(x: imageRect.maxX - 40, y: imageRect.minY + 6, width: 34, height: 16), color: FlowLibraryStyle.accent)
        }

        let title = asset.creationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "Photo"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: CGRect(x: rect.minX + 6, y: imageRect.maxY + 8, width: rect.width - 12, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: FlowLibraryStyle.primaryText.withAlphaComponent(0.86),
            .paragraphStyle: paragraph
        ])
    }

    private func requestThumbnail(for asset: PHAsset, targetSize: CGSize) {
        let id = asset.localIdentifier
        guard requestedThumbnails.insert(id).inserted else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: targetSize.width * 2, height: targetSize.height * 2),
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let image else { return }
            DispatchQueue.main.async { [weak self] in
                self?.thumbnails[id] = image
                self?.needsDisplay = true
            }
        }
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

    private func drawBadge(_ text: String, in rect: CGRect, color: NSColor) {
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        color.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        border.lineWidth = 0.8
        border.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.draw(in: rect.insetBy(dx: 2, dy: 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph
        ])
    }

    private func drawCentered(_ text: String, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.draw(in: rect.insetBy(dx: 6, dy: max(4, rect.height / 2 - 9)), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: FlowLibraryStyle.secondaryText,
            .paragraphStyle: paragraph
        ])
    }

    private func assetIndex(at point: CGPoint) -> Int? {
        for index in assets.indices where tileRect(for: index).contains(point) {
            return index
        }
        return nil
    }

    private func tileRect(for index: Int) -> CGRect {
        let metrics = gridMetrics(for: max(1, bounds.width))
        let column = index % metrics.columns
        let row = index / metrics.columns
        return CGRect(
            x: CGFloat(column) * (metrics.tileWidth + gap) + 6,
            y: CGFloat(row) * (metrics.tileHeight + gap) + 6,
            width: metrics.tileWidth,
            height: metrics.tileHeight
        )
    }

    private func gridMetrics(for width: CGFloat) -> GridMetrics {
        let usableWidth = max(minimumTileWidth, width - 12)
        let columns = max(1, Int((usableWidth + gap) / (minimumTileWidth + gap)))
        let totalGap = CGFloat(max(0, columns - 1)) * gap
        let tileWidth = floor((usableWidth - totalGap) / CGFloat(columns))
        let tileHeight = max(124, floor(tileWidth * 0.78) + 38)
        return GridMetrics(columns: columns, tileWidth: tileWidth, tileHeight: tileHeight)
    }
}
