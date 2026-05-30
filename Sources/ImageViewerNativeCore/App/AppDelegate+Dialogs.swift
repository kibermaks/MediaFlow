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
    @MainActor func showFlowStyledMessage(panelTitle: String, title: String, message: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 196),
            styleMask: [.titled, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = panelTitle
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 380, height: 196))
        content.panelTitle = panelTitle
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let titleLabel = FlowLibraryStyle.primaryLabel(title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        let messageLabel = FlowLibraryStyle.secondaryLabel(message)
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)

        let okButton = FlowActionButton(title: "OK", symbolName: nil, isAccent: true)
        okButton.target = self
        okButton.action = #selector(dismissFlowStyledMessage(_:))
        okButton.tag = NSApplication.ModalResponse.OK.rawValue
        okButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(okButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            messageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            okButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            okButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            okButton.widthAnchor.constraint(equalToConstant: 112),
            okButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        if let window {
            panel.center()
            window.beginSheet(panel) { _ in
                panel.close()
            }
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: panel)
            panel.close()
        }
    }

    @MainActor func showFlowStyledConfirmation(
        panelTitle: String,
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String
    ) -> Bool {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = panelTitle
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 420, height: 220))
        content.panelTitle = panelTitle
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let titleLabel = FlowLibraryStyle.primaryLabel(title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        let messageLabel = FlowLibraryStyle.secondaryLabel(message)
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttonRow)

        let cancelButton = FlowActionButton(title: cancelTitle, symbolName: nil, isAccent: false)
        cancelButton.target = self
        cancelButton.action = #selector(dismissFlowStyledMessage(_:))
        cancelButton.tag = NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        cancelButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(cancelButton)

        let confirmButton = FlowActionButton(title: confirmTitle, symbolName: nil, isAccent: true)
        confirmButton.target = self
        confirmButton.action = #selector(dismissFlowStyledMessage(_:))
        confirmButton.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        confirmButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttonRow.addArrangedSubview(confirmButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 50),
            messageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            buttonRow.heightAnchor.constraint(equalToConstant: 32)
        ])

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.close()
        return response == .alertFirstButtonReturn
    }

    @MainActor @objc func dismissFlowStyledMessage(_ sender: NSControl) {
        guard let modalWindow = sender.window else { return }
        let response = NSApplication.ModalResponse(rawValue: sender.tag)
        if modalWindow.sheetParent != nil {
            modalWindow.sheetParent?.endSheet(modalWindow, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
    }

}
