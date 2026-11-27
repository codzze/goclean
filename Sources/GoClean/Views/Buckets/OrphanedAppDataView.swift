import GoCleanCore
import SwiftUI

/// Displays leftover `~/Library` files belonging to uninstalled macOS applications,
/// grouped by inferred app with confidence badges and expandable paths.
public struct OrphanedAppDataView: View {
    @Bindable public var viewModel: AppViewModel
    @State private var expandedGroupIDs: Set<String> = []
    @State private var filterConfidence: ConfidenceLevel? = nil
    @State private var searchText = ""

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredGroups: [OrphanAppGroup] {
        viewModel.orphanGroups.filter { group in
            if let filterConfidence, group.confidence != filterConfidence {
                return false
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return group.appName.lowercased().contains(q) ||
                    (group.bundleHint?.lowercased().contains(q) ?? false) ||
                    group.items.contains { $0.displayName.lowercased().contains(q) }
            }
            return true
        }
    }

    public var body: some View {
        VStack(spacing: 16) {
            BucketHeaderView(
                title: "Orphaned App Data",
                subtitle: "Leftover Application Support, Caches, Containers, Preferences & LaunchAgents from deleted apps",
                systemImage: "app.dashed",
                accentColor: GoCleanTheme.accentViolet,
                totalBytes: viewModel.totalOrphanBytes,
                itemCount: viewModel.orphanGroups.reduce(0) { $0 + $1.items.count },
                isLoading: viewModel.isScanningOrphans,
                onScan: { Task { await viewModel.scanOrphans() } },
                extraActionTitle: "Stage All Safe",
                onExtraAction: {
                    let safeItems = viewModel.orphanGroups
                        .filter { $0.confidence == .high }
                        .flatMap(\.items)
                    viewModel.stageItems(safeItems)
                }
            )

            if !viewModel.hasScannedOrphans && viewModel.orphanGroups.isEmpty {
                EmptyBucketStateView(
                    systemImage: "app.dashed",
                    title: "Find Leftovers from Deleted Apps",
                    description: "GoClean indexes every currently installed app bundle and CLI tool, then safely highlights unmatched ~/Library leftovers with confidence scores.",
                    actionTitle: "Scan for Orphaned Data",
                    accentColor: GoCleanTheme.accentViolet,
                    isLoading: viewModel.isScanningOrphans
                ) {
                    Task { await viewModel.scanOrphans() }
                }
            } else if viewModel.orphanGroups.isEmpty {
                EmptyBucketStateView(
                    systemImage: "checkmark.seal.fill",
                    title: "No Orphaned App Data Found",
                    description: "Your ~/Library folders look tidy — all detected data matches installed applications or macOS system services.",
                    actionTitle: "Scan Again",
                    accentColor: GoCleanTheme.accentEmerald,
                    isLoading: viewModel.isScanningOrphans
                ) {
                    Task { await viewModel.scanOrphans() }
                }
            } else {
                filterBar

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredGroups) { group in
                            orphanGroupCard(group)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter orphaned apps or bundle IDs…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 320)

            Spacer()

            Picker("Confidence", selection: $filterConfidence) {
                Text("All (\(viewModel.orphanGroups.count))").tag(ConfidenceLevel?.none)
                Text("Safe").tag(ConfidenceLevel?.some(.high))
                Text("Review").tag(ConfidenceLevel?.some(.review))
                Text("Danger").tag(ConfidenceLevel?.some(.danger))
            }
            .pickerStyle(.segmented)
            .frame(width: 290)
        }
    }

    private func orphanGroupCard(_ group: OrphanAppGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        let allStaged = group.items.allSatisfy { viewModel.isStaged(url: $0.url) }

        return GlassCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        if isExpanded {
                            expandedGroupIDs.remove(group.id)
                        } else {
                            expandedGroupIDs.insert(group.id)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(group.appName)
                                .font(.headline)
                            ConfidenceBadge(level: group.confidence)
                            if let hint = group.bundleHint {
                                Text(hint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(group.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormatting.string(from: group.totalSize))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(GoCleanTheme.accentViolet)
                        Text("\(group.items.count) \(group.items.count == 1 ? "location" : "locations")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if allStaged {
                            for item in group.items { viewModel.unstage(id: item.id) }
                        } else {
                            viewModel.stageItems(group.items)
                        }
                    } label: {
                        Label(allStaged ? "Staged" : "Collect All", systemImage: allStaged ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(allStaged ? GoCleanTheme.accentEmerald : GoCleanTheme.accentViolet)
                    .controlSize(.small)
                }

                if isExpanded {
                    Divider()
                    VStack(spacing: 6) {
                        ForEach(group.items) { item in
                            let staged = viewModel.isStaged(url: item.url)
                            HStack(spacing: 10) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.caption)
                                    .foregroundStyle(GoCleanTheme.accentViolet.opacity(0.8))

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.displayName)
                                        .font(.caption.weight(.semibold))
                                    Text(item.url.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                if let tag = item.tag {
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }

                                Text(ByteFormatting.string(from: item.size))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .frame(width: 72, alignment: .trailing)

                                Button {
                                    QuickLookController.shared.revealInFinder(url: item.url)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Button {
                                    viewModel.toggleStage(item: item)
                                } label: {
                                    Image(systemName: staged ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(staged ? GoCleanTheme.accentEmerald : GoCleanTheme.accentViolet)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 24)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }
}
