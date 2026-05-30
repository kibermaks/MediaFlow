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
import SwiftUI

extension AppDelegate {
    @MainActor @objc func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = makeAboutWindow()
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func makeAboutWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "About \(AppMetadata.name)"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 86),
            icon.heightAnchor.constraint(equalToConstant: 86)
        ])
        stack.addArrangedSubview(icon)

        stack.addArrangedSubview(makeDialogLabel(AppMetadata.name, size: 24, weight: .semibold, color: .labelColor))
        let tagline = makeDialogLabel(AppMetadata.tagline, size: 13, weight: .regular, color: .secondaryLabelColor)
        tagline.maximumNumberOfLines = 2
        tagline.alignment = .center
        stack.addArrangedSubview(tagline)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let versionLabel = makeDialogLabel("Version \(version) (\(build))", size: 12, weight: .regular, color: .tertiaryLabelColor)
        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(versionLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let author = makeDialogLabel("by \(AppMetadata.authorName)", size: 13, weight: .medium, color: .secondaryLabelColor)
        stack.addArrangedSubview(author)

        let links = NSStackView()
        links.orientation = .vertical
        links.spacing = 8
        links.alignment = .width
        links.translatesAutoresizingMaskIntoConstraints = false
        links.addArrangedSubview(makeLinkButton(title: "Project on GitHub", url: AppMetadata.repositoryURL))
        links.addArrangedSubview(makeLinkButton(title: "Author Profile", url: AppMetadata.authorURL))
        links.addArrangedSubview(makeLinkButton(
            title: AppMetadata.licenseName,
            url: URL(string: "\(AppMetadata.repositoryURL.absoluteString)/blob/main/LICENSE") ?? AppMetadata.repositoryURL
        ))
        stack.addArrangedSubview(links)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 34)
        ])

        return panel
    }

    @MainActor @objc func showChangelogWindow() {
        if changelogWindow == nil {
            changelogWindow = makeChangelogWindow()
        }
        MediaFlowChangelogService.shared.fetchIfNeeded()
        changelogWindow?.center()
        changelogWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func makeChangelogWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "What's New"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 500, height: 430)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        let changelogURL = URL(string: "\(AppMetadata.repositoryURL.absoluteString)/blob/main/CHANGELOG.md") ?? AppMetadata.repositoryURL
        let view = MediaFlowWhatsNewView(
            changelog: MediaFlowChangelogService.shared,
            onClose: { [weak panel] in panel?.orderOut(nil) },
            onOpenGitHub: { NSWorkspace.shared.open(changelogURL) }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 680, height: 560)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        return panel
    }

    @MainActor func showUpdateAvailableDialog(_ info: MediaFlowUpdateInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = "\(AppMetadata.name) \(info.displayVersion) is ready.\n\n\(info.title)"
        alert.icon = NSImage(named: NSImage.applicationIconName)
        if !info.releaseNotes.isEmpty {
            alert.accessoryView = makeReleaseNotesAccessory(info.releaseNotes)
        }

        if info.downloadURL != nil {
            alert.addButton(withTitle: "Install Update")
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                updateService.installLatestUpdate(info)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(info.pageURL)
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(info.pageURL)
            }
        }
    }

    @MainActor func showSimpleAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor func makeReleaseNotesAccessory(_ notes: String) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.string = notes
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        return scrollView
    }

    @MainActor func showInstallStatus(_ message: String) {
        if installStatusPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "Installing Update"
            panel.isReleasedWhenClosed = false

            let content = NSView()
            panel.contentView = content

            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.startAnimation(nil)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(indicator)

            let label = makeDialogLabel(message, size: 13, weight: .regular, color: .labelColor)
            label.maximumNumberOfLines = 2
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            installStatusLabel = label

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 14)
            ])

            installStatusPanel = panel
        }

        installStatusLabel?.stringValue = message
        installStatusPanel?.center()
        installStatusPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func hideInstallStatusPanel() {
        installStatusPanel?.orderOut(nil)
    }

    @MainActor func makeDialogLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        return label
    }

    @MainActor func makeLinkButton(title: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openButtonURL(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return button
    }

    @MainActor @objc func openButtonURL(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

}
