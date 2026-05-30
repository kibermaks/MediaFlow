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
    @MainActor @objc func addFromPhotos() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            showPhotosImportPanel()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if newStatus == .authorized || newStatus == .limited {
                        self.showPhotosImportPanel()
                    } else {
                        self.showPhotosAccessAlert()
                    }
                }
            }
        default:
            showPhotosAccessAlert()
        }
    }

    @MainActor func showPhotosImportPanel() {
        if photosPanel == nil {
            photosPanel = makePhotosPanel()
        }
        reloadPhotosBrowser()
        if let window, let photosPanel, !photosPanel.isVisible {
            let x = min(window.frame.maxX - photosPanel.frame.width - 22, max(window.frame.minX + 22, window.frame.midX - photosPanel.frame.width / 2))
            let y = min(window.frame.maxY - photosPanel.frame.height - 46, max(window.frame.minY + 42, window.frame.midY - photosPanel.frame.height / 2))
            photosPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        photosPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func makePhotosPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add From Photos"
        panel.titleVisibility = .hidden
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 640, height: 500)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = FlowPanelBackgroundView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 760, height: 650))
        content.panelTitle = "Add From Photos"
        content.autoresizingMask = [.width, .height]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let header = PhotosImportHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 58).isActive = true
        photosHeaderView = header
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let browserRow = NSStackView()
        browserRow.orientation = .horizontal
        browserRow.alignment = .height
        browserRow.distribution = .fill
        browserRow.spacing = 10
        browserRow.translatesAutoresizingMaskIntoConstraints = false

        let collectionsScroll = NSScrollView()
        collectionsScroll.borderType = .noBorder
        collectionsScroll.hasVerticalScroller = true
        collectionsScroll.drawsBackground = false
        collectionsScroll.scrollerStyle = .overlay
        collectionsScroll.translatesAutoresizingMaskIntoConstraints = false
        collectionsScroll.widthAnchor.constraint(equalToConstant: 184).isActive = true
        let collectionsView = PhotosImportCollectionsView(frame: NSRect(x: 0, y: 0, width: 184, height: 470))
        collectionsView.autoresizingMask = [.width]
        collectionsView.selectionChanged = { [weak self] in
            self?.loadSelectedPhotosCollection()
        }
        photosCollectionsView = collectionsView
        collectionsScroll.documentView = collectionsView
        browserRow.addArrangedSubview(collectionsScroll)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        let grid = PhotosImportGridView(frame: NSRect(x: 0, y: 0, width: 534, height: 470))
        grid.autoresizingMask = [.width]
        grid.selectionChanged = { [weak self] in
            self?.syncPhotosImportControls()
        }
        photosGridView = grid
        scroll.documentView = grid
        browserRow.addArrangedSubview(scroll)
        stack.addArrangedSubview(browserRow)
        browserRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let importButton = FlowActionButton(title: "Import Selected", symbolName: "arrow.down.to.line", isAccent: true)
        importButton.target = self
        importButton.action = #selector(importSelectedPhotos)
        importButton.isEnabled = false
        importButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        photosImportButton = importButton
        buttonRow.addArrangedSubview(importButton)
        let refreshButton = FlowActionButton(title: "Refresh", symbolName: "arrow.clockwise", isAccent: false)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPhotosPanel)
        refreshButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        photosRefreshButton = refreshButton
        buttonRow.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        panel.contentView = content
        return panel
    }

    @MainActor func makePhotosFetchOptions(limit: Int = 300) -> PHFetchOptions {
        let options = PHFetchOptions()
        if limit > 0 {
            options.fetchLimit = limit
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        return options
    }

    @MainActor func fetchPhotosAssets(in collection: PHAssetCollection?) -> [PHAsset] {
        let options = makePhotosFetchOptions()
        let result = collection.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    @MainActor func fetchPhotosCollections() -> [PhotosImportCollection] {
        let countOptions = makePhotosFetchOptions(limit: 0)
        let allCount = PHAsset.fetchAssets(with: countOptions).count
        var collections = [
            PhotosImportCollection(
                id: "__all_photos__",
                title: "Photos Library",
                subtitle: photosAssetCountText(allCount),
                assetCollection: nil
            )
        ]
        var seenIDs = Set(collections.map(\.id))

        func appendCollections(type: PHAssetCollectionType) {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            result.enumerateObjects { collection, _, _ in
                guard seenIDs.insert(collection.localIdentifier).inserted else { return }
                let assets = PHAsset.fetchAssets(in: collection, options: countOptions)
                guard assets.count > 0 else { return }
                let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                collections.append(PhotosImportCollection(
                    id: collection.localIdentifier,
                    title: title?.isEmpty == false ? title! : "Untitled",
                    subtitle: self.photosAssetCountText(assets.count),
                    assetCollection: collection
                ))
            }
        }

        appendCollections(type: .smartAlbum)
        appendCollections(type: .album)
        return collections
    }

    @MainActor func photosAssetCountText(_ count: Int) -> String {
        count == 1 ? "1 asset" : "\(count) assets"
    }

    @MainActor func reloadPhotosBrowser() {
        let previousID = photosCollectionsView?.selectedCollection?.id
        let collections = fetchPhotosCollections()
        photosCollectionsView?.collections = collections
        if let previousID, let index = collections.firstIndex(where: { $0.id == previousID }) {
            photosCollectionsView?.selectedIndex = index
        } else {
            photosCollectionsView?.selectedIndex = 0
        }
        loadSelectedPhotosCollection()
    }

    @MainActor func loadSelectedPhotosCollection() {
        let collection = photosCollectionsView?.selectedCollection
        photosGridView?.assets = fetchPhotosAssets(in: collection?.assetCollection)
        syncPhotosImportControls()
    }

    @MainActor @objc func refreshPhotosPanel() {
        guard !photosImportInProgress else { return }
        reloadPhotosBrowser()
    }

    @MainActor @objc func importSelectedPhotos() {
        guard let selectedAssets = photosGridView?.selectedAssets, !selectedAssets.isEmpty else { return }
        photosImportInProgress = true
        syncPhotosImportControls(statusMessage: "Importing \(selectedAssets.count) from Photos...")
        PhotosImportStore.importAssets(selectedAssets) { [weak self] urls in
            guard let self else { return }
            self.photosImportInProgress = false
            if urls.isEmpty {
                self.syncPhotosImportControls(statusMessage: "No Photos assets were imported.")
                NSSound.beep()
            } else {
                self.canvas?.addMediaURLs(urls)
                self.photosGridView?.clearSelection(notify: false)
                self.syncPhotosImportControls()
                self.photosPanel?.close()
            }
        }
    }

    @MainActor func syncPhotosImportControls(statusMessage: String? = nil) {
        let assetCount = photosGridView?.assets.count ?? 0
        let selectedCount = photosGridView?.selectedAssets.count ?? 0
        photosHeaderView?.collectionTitle = photosCollectionsView?.selectedCollection?.title ?? "Photos Library"
        photosHeaderView?.assetCount = assetCount
        photosHeaderView?.selectedCount = selectedCount
        photosHeaderView?.statusMessage = statusMessage
        photosHeaderView?.isImporting = photosImportInProgress
        photosImportButton?.title = photosImportInProgress
            ? "Importing..."
            : (selectedCount > 0 ? "Import \(selectedCount) Selected" : "Import Selected")
        photosImportButton?.isEnabled = selectedCount > 0 && !photosImportInProgress
        photosRefreshButton?.isEnabled = !photosImportInProgress
    }

    @MainActor func showPhotosAccessAlert() {
        showFlowStyledMessage(
            panelTitle: "Photos Access",
            title: "Photos access is not available.",
            message: "Allow MediaFlow to read your Photos library in System Settings, then try Add From Photos again."
        )
    }

}
