// ImagePreviewView.swift
// Athena — read-only preview for image-file tabs (plan.md item 26, "G1").
// Swift 6, strict concurrency.

import SwiftUI
@preconcurrency import AppKit

// MARK: - ImagePreviewView

/// Renders an image file tab as a centered, scaled-to-fit preview instead of
/// the plain-text `CodeEditorView` — `EditorPaneView` branches to this view
/// whenever the active tab's `language == .image` (see `Language
/// .fileExtensions`'s `.image` case). Purely a viewer: image tabs never
/// become dirty and have no `content` to edit, so there's no save path here.
struct ImagePreviewView: View {
    let fileURL: URL?

    @State private var image: NSImage?
    @State private var info: ImagePreviewView.LoadedInfo?
    @State private var failedToLoad = false

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            if image != nil || failedToLoad {
                Divider()
                infoBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: fileURL) {
            load()
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failedToLoad {
            ContentUnavailableView(
                "Couldn't Load Image",
                systemImage: "photo.badge.exclamationmark",
                description: Text(fileURL?.lastPathComponent ?? "")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Info bar

    private var infoBar: some View {
        HStack(spacing: 14) {
            if let info {
                Label(
                    "\(Int(info.pixelSize.width.rounded())) × \(Int(info.pixelSize.height.rounded()))",
                    systemImage: "aspectratio"
                )
                if let fileSize = info.fileSizeBytes {
                    Label(Self.byteCountFormatter.string(fromByteCount: fileSize), systemImage: "doc")
                }
            }
            Spacer()
            if let fileURL {
                Text(fileURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 26)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - Loading

    /// Dimensions + file size for the currently displayed image — kept as one
    /// bundle rather than two separate optionals so the info bar can't ever
    /// show a stale size paired with a freshly loaded image (both are always
    /// set together by `load()`).
    struct LoadedInfo: Equatable {
        var pixelSize: CGSize
        var fileSizeBytes: Int64?
    }

    /// Loads (or reloads, on a new `fileURL`) the preview image and its
    /// display info synchronously — image files opened in an editor tab are
    /// small enough (icons, screenshots, diagrams) that a brief main-thread
    /// decode is an acceptable trade-off against introducing a dedicated
    /// actor/service purely for this one read.
    private func load() {
        image = nil
        info = nil
        failedToLoad = false
        guard let fileURL, let loaded = NSImage(contentsOf: fileURL) else {
            failedToLoad = true
            return
        }
        image = loaded
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes?[.size] as? Int64
        info = LoadedInfo(pixelSize: loaded.size, fileSizeBytes: fileSize)
    }
}
