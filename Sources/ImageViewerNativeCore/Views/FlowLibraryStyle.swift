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

enum FlowLibraryStyle {
    static let accent = NSColor(calibratedRed: 0.16, green: 0.92, blue: 0.72, alpha: 1)
    static let accentBlue = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.88, alpha: 1)
    static let backgroundTop = NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.14, alpha: 1)
    static let backgroundBottom = NSColor(calibratedRed: 0.18, green: 0.09, blue: 0.05, alpha: 1)
    static let cardFill = NSColor(calibratedRed: 0.27, green: 0.18, blue: 0.14, alpha: 0.78)
    static let controlPanelFill = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 0.94)
    static let controlFill = NSColor(calibratedRed: 0.34, green: 0.26, blue: 0.22, alpha: 0.86)
    static let controlStroke = NSColor.white.withAlphaComponent(0.10)
    static let primaryText = NSColor.white.withAlphaComponent(0.92)
    static let secondaryText = NSColor.white.withAlphaComponent(0.52)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.34)

    static let tilePalettes: [[NSColor]] = [
        [NSColor(calibratedRed: 0.02, green: 0.38, blue: 0.49, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.13, alpha: 1)],
        [NSColor(calibratedRed: 0.66, green: 0.37, blue: 0.12, alpha: 1), NSColor(calibratedRed: 0.31, green: 0.16, blue: 0.06, alpha: 1)],
        [NSColor(calibratedRed: 0.48, green: 0.13, blue: 0.58, alpha: 1), NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.23, alpha: 1)],
        [NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.26, alpha: 1), NSColor(calibratedRed: 0.02, green: 0.14, blue: 0.18, alpha: 1)],
        [NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.23, alpha: 1), NSColor(calibratedRed: 0.14, green: 0.06, blue: 0.08, alpha: 1)],
        [NSColor(calibratedRed: 0.04, green: 0.46, blue: 0.38, alpha: 1), NSColor(calibratedRed: 0.11, green: 0.18, blue: 0.43, alpha: 1)],
        [NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.44, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)],
        [NSColor(calibratedRed: 0.68, green: 0.36, blue: 0.18, alpha: 1), NSColor(calibratedRed: 0.28, green: 0.08, blue: 0.12, alpha: 1)]
    ]

    @MainActor static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: secondaryText,
            .kern: 1.2
        ]))
        return label
    }

    @MainActor static func primaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = primaryText
        return label
    }

    @MainActor static func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = secondaryText
        return label
    }

    static func drawRoundedGradient(in rect: CGRect, colors: [NSColor], radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        NSGradient(colors: colors)?.draw(in: rect, angle: 135)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class FlowPanelBackgroundView: NSView {
    var panelTitle = "Flow Library" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [FlowLibraryStyle.backgroundTop, FlowLibraryStyle.backgroundBottom])?.draw(in: bounds, angle: 100)

        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        let warmGlow = CGRect(x: bounds.minX - 80, y: bounds.minY + 60, width: bounds.width * 1.45, height: bounds.height * 0.58)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.08, alpha: 0.36),
            NSColor(calibratedRed: 0.18, green: 0.06, blue: 0.04, alpha: 0.02)
        ])?.draw(in: warmGlow, relativeCenterPosition: CGPoint(x: -0.25, y: -0.18))

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        panelTitle.draw(in: CGRect(x: 0, y: 8, width: bounds.width, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: FlowLibraryStyle.primaryText.withAlphaComponent(0.74),
            .paragraphStyle: titleParagraph
        ])
    }
}
