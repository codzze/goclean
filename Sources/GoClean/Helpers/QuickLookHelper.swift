import AppKit
import GoCleanCore
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// Bridge to native macOS Quick Look (`QLPreviewPanel`) so users can preview videos, images, and files instantly.
@MainActor
public final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookController()

    private var previewURL: URL?

    public func preview(url: URL) {
        self.previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURL == nil ? 0 : 1
        }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            previewURL as NSURL?
        }
    }
}

/// Async thumbnail view powered by `QLThumbnailGenerator` (great for Large Videos & Media).
public struct AsyncThumbnailView: View {
    public let url: URL
    public let size: CGSize

    @State private var image: NSImage?

    public init(url: URL, size: CGSize = CGSize(width: 56, height: 40)) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                self.image = rep.nsImage
            }
        }
    }
}

/// Displays native macOS app bundle icon or semantic CLI icon.
public struct AppBundleIconView: View {
    public let app: InstalledApplication
    public let size: CGFloat

    public init(app: InstalledApplication, size: CGFloat = 34) {
        self.app = app
        self.size = size
    }

    public var body: some View {
        if app.installPath.pathExtension.lowercased() == "app" &&
            FileManager.default.fileExists(atPath: app.installPath.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.installPath.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            let color = GoCleanTheme.color(for: app.source)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(color.gradient.opacity(0.20))
                    .frame(width: size, height: size)
                Image(systemName: GoCleanTheme.icon(for: app.source))
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
    }
}
