import GoCleanCore
import SwiftUI

/// Displays crash dumps, heap/core dumps, old DMG/PKG installers, Xcode Archives/DeviceSupport, and log bloat.
public struct DumpAndJunkView: View {
    @Bindable public var viewModel: AppViewModel
    @State private var selectedCategory: DumpJunkCategory? = nil

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredItems: [CleanupItem] {
        viewModel.dumpJunkItems.filter { item in
            guard let selectedCategory else { return true }
            return item.tag == selectedCategory.rawValue
        }
    }

    public var body: some View {
        VStack(spacing: 16) {
            BucketHeaderView(
                title: "Dump & System Junk",
                subtitle: "Crash dumps (.ips, .crash, .dmp, .core), old .dmg/.pkg installers, Xcode DeviceSupport & logs",
                systemImage: "doc.badge.gearshape.fill",
                accentColor: GoCleanTheme.accentAmber,
                totalBytes: viewModel.totalDumpJunkBytes,
                itemCount: viewModel.dumpJunkItems.count,
                isLoading: viewModel.isScanningDumps,
                onScan: { Task { await viewModel.scanDumpAndJunk() } },
                extraActionTitle: "Collect Safe Items",
                onExtraAction: {
                    let safe = filteredItems.filter { $0.confidence == .high }
                    viewModel.stageItems(safe)
                }
            )

            if !viewModel.hasScannedDumps && viewModel.dumpJunkItems.isEmpty {
                EmptyBucketStateView(
                    systemImage: "doc.badge.gearshape.fill",
                    title: "Clean Crash Dumps & Old Installers",
                    description: "Locate diagnostic crash reports, heap dumps, leftover DMG/PKG installers in Downloads, and bulky application logs.",
                    actionTitle: "Scan Dumps & Junk",
                    accentColor: GoCleanTheme.accentAmber,
                    isLoading: viewModel.isScanningDumps
                ) {
                    Task { await viewModel.scanDumpAndJunk() }
                }
            } else if viewModel.dumpJunkItems.isEmpty {
                EmptyBucketStateView(
                    systemImage: "sparkles",
                    title: "No Dump Files or System Junk Found",
                    description: "No crash dumps, leftover installers, or large log files were detected.",
                    actionTitle: "Rescan",
                    accentColor: GoCleanTheme.accentEmerald,
                    isLoading: viewModel.isScanningDumps
                ) {
                    Task { await viewModel.scanDumpAndJunk() }
                }
            } else {
                HStack(spacing: 6) {
                    pill(title: "All", category: nil, count: viewModel.dumpJunkItems.count)
                    ForEach(DumpJunkCategory.allCases, id: \.self) { cat in
                        let count = viewModel.dumpJunkItems.filter { $0.tag == cat.rawValue }.count
                        if count > 0 {
                            pill(title: cat.rawValue, category: cat, count: count)
                        }
                    }
                    Spacer()
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            dumpRow(item)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
    }

    private func pill(title: String, category: DumpJunkCategory?, count: Int) -> some View {
        let active = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            Text("\(title) (\(count))")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? GoCleanTheme.accentAmber : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func dumpRow(_ item: CleanupItem) -> some View {
        let staged = viewModel.isStaged(url: item.url)
        return GlassCard(padding: 12, cornerRadius: 12) {
            HStack(spacing: 12) {
                Image(systemName: item.isDirectory ? "folder.badge.gearshape" : "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(GoCleanTheme.accentAmber)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        ConfidenceBadge(level: item.confidence)
                        if let tag = item.tag {
                            Text(tag)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(ByteFormatting.relativeDateString(from: item.lastModified))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(ByteFormatting.string(from: item.size))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 82, alignment: .trailing)

                Button {
                    QuickLookController.shared.preview(url: item.url)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    QuickLookController.shared.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    viewModel.toggleStage(item: item)
                } label: {
                    Image(systemName: staged ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(staged ? GoCleanTheme.accentEmerald : GoCleanTheme.accentAmber)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
