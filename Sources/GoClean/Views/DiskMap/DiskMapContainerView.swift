import GoCleanCore
import SwiftUI

/// Container for the Disk Map feature combining breadcrumbs, view mode switcher
/// (Orbital Map / Treemap / Tree List), live scan progress bar, and bidirectional file inspector.
public struct DiskMapContainerView: View {
    @Bindable public var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()

            if let zoomNode = viewModel.currentZoomNode ?? viewModel.rootNode {
                mainWorkspace(zoomNode: zoomNode)
            } else {
                EmptyBucketStateView(
                    systemImage: "circle.hexagongrid.circle.fill",
                    title: "Ready to Map Your Storage",
                    description: "Launch a high-speed APFS-aware scan of your Home folder, Macintosh HD, or any folder to explore disk usage in the Luminous Orbital Map.",
                    actionTitle: "Scan Home Folder",
                    accentColor: GoCleanTheme.accentIndigo,
                    isLoading: viewModel.isScanningDisk
                ) {
                    viewModel.startDiskScan(url: FileManager.default.homeDirectoryForCurrentUser)
                }
            }
        }
    }

    // MARK: - Top Control Bar & Breadcrumbs

    private var topControlBar: some View {
        HStack(spacing: 12) {
            if let zoomNode = viewModel.currentZoomNode ?? viewModel.rootNode {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let chain = zoomNode.breadcrumbChain
                        ForEach(Array(chain.enumerated()), id: \.element.id) { idx, node in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                viewModel.zoomTo(node: node)
                            } label: {
                                Text(node.name)
                                    .font(.caption.weight(idx == chain.count - 1 ? .bold : .medium))
                                    .foregroundStyle(idx == chain.count - 1 ? .primary : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        idx == chain.count - 1 ? Color.primary.opacity(0.08) : Color.clear,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("Disk Map")
                    .font(.headline)
            }

            Spacer()

            if viewModel.isScanningDisk, let progress = viewModel.scanProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(progress.scannedFiles.formatted()) files • \(ByteFormatting.string(from: progress.scannedBytes))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(GoCleanTheme.accentTeal.opacity(0.12), in: Capsule())
            }

            Picker("View Mode", selection: $viewModel.diskMapMode) {
                ForEach(DiskMapViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Split Workspace

    @ViewBuilder
    private func mainWorkspace(zoomNode: FileNode) -> some View {
        switch viewModel.diskMapMode {
        case .orbital:
            HSplitView {
                OrbitalMapView(
                    rootNode: zoomNode,
                    hoveredNodeID: $viewModel.hoveredNodeID,
                    selectedNodeID: $viewModel.selectedNodeID,
                    canZoomOut: zoomNode.parent != nil,
                    onZoomIn: { viewModel.zoomTo(node: $0) },
                    onZoomOut: { viewModel.zoomOut() },
                    onStageNode: { viewModel.stageNode($0) }
                )
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)

                inspectorList(for: zoomNode)
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 480)
            }

        case .treemap:
            HSplitView {
                TreemapView(
                    rootNode: zoomNode,
                    hoveredNodeID: $viewModel.hoveredNodeID,
                    selectedNodeID: $viewModel.selectedNodeID,
                    onZoomIn: { viewModel.zoomTo(node: $0) },
                    onStageNode: { viewModel.stageNode($0) }
                )
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)

                inspectorList(for: zoomNode)
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 480)
            }

        case .list:
            inspectorList(for: zoomNode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bidirectional File Inspector List

    private func inspectorList(for zoomNode: FileNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zoomNode.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(zoomNode.children.count.formatted()) entries • \(ByteFormatting.string(from: zoomNode.physicalSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if zoomNode.parent != nil {
                    Button {
                        viewModel.zoomOut()
                    } label: {
                        Label("Up", systemImage: "arrow.up.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(zoomNode.children.prefix(250).enumerated()), id: \.element.id) { idx, child in
                        FileInspectorRow(
                            node: child,
                            parentTotal: max(1, zoomNode.physicalSize),
                            accentColor: GoCleanTheme.orbitalColor(for: child, ringDepth: 0, siblingIndex: idx),
                            isHovered: viewModel.hoveredNodeID == child.id,
                            isStaged: viewModel.isStaged(url: child.url),
                            onSelect: {
                                if child.isDirectory {
                                    viewModel.zoomTo(node: child)
                                } else {
                                    QuickLookController.shared.preview(url: child.url)
                                }
                            },
                            onToggleStage: {
                                if viewModel.isStaged(url: child.url) {
                                    viewModel.unstage(id: child.url.standardizedFileURL.path)
                                } else {
                                    viewModel.stageNode(child)
                                }
                            }
                        )
                        .onHover { hovering in
                            if hovering {
                                viewModel.hoveredNodeID = child.id
                            } else if viewModel.hoveredNodeID == child.id {
                                viewModel.hoveredNodeID = nil
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct FileInspectorRow: View {
    let node: FileNode
    let parentTotal: UInt64
    let accentColor: Color
    let isHovered: Bool
    let isStaged: Bool
    let onSelect: () -> Void
    let onToggleStage: () -> Void

    var body: some View {
        let fraction = min(1.0, Double(node.physicalSize) / Double(parentTotal))
        HStack(spacing: 10) {
            Image(systemName: node.isDirectory ? "folder.fill" : (node.isCloudPlaceholder ? "icloud" : "doc.fill"))
                .font(.system(size: 14))
                .foregroundStyle(accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if node.isCloudPlaceholder {
                        Text("iCloud")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(GoCleanTheme.accentSky.opacity(0.16), in: Capsule())
                            .foregroundStyle(GoCleanTheme.accentSky)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(accentColor.opacity(0.75))
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 4)

            Text(ByteFormatting.string(from: node.physicalSize))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)

            HStack(spacing: 4) {
                Button {
                    QuickLookController.shared.preview(url: node.url)
                } label: {
                    Image(systemName: "eye")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quick Look")

                Button {
                    QuickLookController.shared.revealInFinder(url: node.url)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")

                Button(action: onToggleStage) {
                    Image(systemName: isStaged ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isStaged ? GoCleanTheme.accentEmerald : accentColor)
                }
                .buttonStyle(.plain)
                .help(isStaged ? "Remove from Collector" : "Stage in Collector")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
