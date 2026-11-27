import AppKit
import GoCleanCore
import SwiftUI

/// Exact SHA-256 duplicate file finder with 3-stage progress telemetry and
/// Smart Auto-Select strategies that always guarantee at least one copy is preserved.
public struct DuplicateFilesView: View {
    @Bindable public var viewModel: AppViewModel
    private let minSizes = [1, 5, 10, 50]

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            BucketHeaderView(
                title: "Duplicate Files",
                subtitle: "3-stage verified (Size → Partial Hash → Full SHA-256), automatically skipping APFS hard links",
                systemImage: "square.on.square.dashed",
                accentColor: GoCleanTheme.accentSky,
                totalBytes: viewModel.totalDuplicateWastedBytes,
                itemCount: viewModel.duplicateGroups.count,
                isLoading: viewModel.isScanningDuplicates,
                onScan: { viewModel.scanDuplicates() }
            )

            controlsBar

            if viewModel.isScanningDuplicates, let prog = viewModel.duplicateProgress {
                GlassCard(padding: 18, cornerRadius: 14) {
                    HStack(spacing: 14) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prog.stage)
                                .font(.headline)
                            Text("\(prog.filesInspected.formatted()) files inspected • \(prog.candidateGroups.formatted()) candidate groups")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") {
                            viewModel.cancelDuplicateScan()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if !viewModel.hasScannedDuplicates && viewModel.duplicateGroups.isEmpty {
                EmptyBucketStateView(
                    systemImage: "square.on.square.dashed",
                    title: "Find Byte-Identical Duplicates",
                    description: "Choose your Home folder or any specific directory (e.g. Downloads, Pictures) to find exact SHA-256 duplicates and reclaim wasted space safely.",
                    actionTitle: "Scan for Duplicates",
                    accentColor: GoCleanTheme.accentSky,
                    isLoading: viewModel.isScanningDuplicates
                ) {
                    viewModel.scanDuplicates()
                }
            } else if viewModel.duplicateGroups.isEmpty && !viewModel.isScanningDuplicates {
                EmptyBucketStateView(
                    systemImage: "checkmark.seal.fill",
                    title: "No Duplicates Found",
                    description: "No identical files above \(viewModel.duplicateMinSizeMB) MB were found in \(viewModel.duplicateScanRoot.lastPathComponent).",
                    actionTitle: "Scan Another Folder",
                    accentColor: GoCleanTheme.accentEmerald,
                    isLoading: false
                ) {
                    chooseFolderAndScan()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.duplicateGroups) { group in
                            duplicateGroupCard(group)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Button {
                chooseFolderAndScan()
            } label: {
                Label("Folder: \(viewModel.duplicateScanRoot.lastPathComponent)", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 6) {
                Text("Min Size:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Min Size", selection: $viewModel.duplicateMinSizeMB) {
                    ForEach(minSizes, id: \.self) { mb in
                        Text("\(mb) MB").tag(mb)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Spacer()

            if !viewModel.duplicateGroups.isEmpty {
                Menu {
                    ForEach(DuplicateSelectionStrategy.allCases, id: \.self) { strategy in
                        Button(strategy.rawValue) {
                            viewModel.smartStageDuplicates(strategy: strategy)
                        }
                    }
                } label: {
                    Label("Smart Select Duplicates", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderedButton)
                .tint(GoCleanTheme.accentSky)
            }
        }
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        GlassCard(padding: 14, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(GoCleanTheme.accentSky)
                    Text(group.files.first?.fileName ?? "Duplicate Group")
                        .font(.headline)
                        .lineLimit(1)

                    Text("\(group.files.count) copies • \(ByteFormatting.string(from: group.fileSize)) each")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("SHA-256 \(group.sha256.prefix(10))…")
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(.secondary)

                    Text("Save \(ByteFormatting.string(from: group.wastedSize))")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(GoCleanTheme.accentSky)
                }

                Divider()

                let stagedInGroup = group.files.filter { viewModel.isStaged(url: $0.url) }.count
                let classifier = FileSafetyClassifier()

                VStack(spacing: 6) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { idx, entry in
                        let isStaged = viewModel.isStaged(url: entry.url)
                        let wouldDeleteLastCopy = !isStaged && (stagedInGroup + 1 >= group.files.count)
                        let isSystem = classifier.isSystemOrProtectedPath(entry.url)

                        HStack(spacing: 10) {
                            if idx == 0 && !isStaged {
                                Text("Original")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(GoCleanTheme.accentEmerald.opacity(0.16), in: Capsule())
                                    .foregroundStyle(GoCleanTheme.accentEmerald)
                            } else {
                                Text("Copy #\(idx + 1)")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }

                            ConfidenceBadge(level: isSystem ? .danger : .high)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.fileName)
                                    .font(.caption.weight(.semibold))
                                Text(entry.parentPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Text(ByteFormatting.relativeDateString(from: entry.modificationDate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Button {
                                QuickLookController.shared.preview(url: entry.url)
                            } label: {
                                Image(systemName: "eye").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Button {
                                QuickLookController.shared.revealInFinder(url: entry.url)
                            } label: {
                                Image(systemName: "folder").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Button {
                                if wouldDeleteLastCopy {
                                    viewModel.alertMessage = "At least one copy in a duplicate group must remain unstaged to prevent accidental data loss."
                                } else {
                                    viewModel.toggleStage(item: entry.asCleanupItem())
                                }
                            } label: {
                                Image(systemName: isStaged ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(
                                        isStaged ? GoCleanTheme.accentEmerald :
                                            (wouldDeleteLastCopy ? Color.secondary.opacity(0.4) : GoCleanTheme.accentSky)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(wouldDeleteLastCopy ? "Keep at least one copy" : (isStaged ? "Unstage copy" : "Stage duplicate copy"))
                        }
                    }
                }
            }
        }
    }

    private func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan for Duplicates"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.scanDuplicates(root: url)
        }
    }
}
