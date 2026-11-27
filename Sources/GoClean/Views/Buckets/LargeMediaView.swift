import GoCleanCore
import SwiftUI

/// Surfaces large videos and oversized media files with live Quick Look thumbnails,
/// configurable byte thresholds, and instant Quick Look playback/preview.
public struct LargeMediaView: View {
    @Bindable public var viewModel: AppViewModel
    @State private var selectedSafety: ConfidenceLevel? = nil
    private let thresholds = [25, 50, 100, 250, 500, 1024]

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredItems: [CleanupItem] {
        viewModel.largeMediaItems.filter { item in
            guard let selectedSafety else { return true }
            return item.confidence == selectedSafety
        }
    }

    public var body: some View {
        VStack(spacing: 16) {
            BucketHeaderView(
                title: "Large Videos & Media",
                subtitle: "User videos, recordings, raw footage & large files — macOS system & Library files excluded by default",
                systemImage: "film.stack.fill",
                accentColor: GoCleanTheme.accentCoral,
                totalBytes: filteredItems.reduce(0) { $0 &+ $1.size },
                itemCount: filteredItems.count,
                isLoading: viewModel.isScanningLargeMedia,
                onScan: { Task { await viewModel.scanLargeMedia() } }
            )

            controlStrip

            if !viewModel.hasScannedLargeMedia && viewModel.largeMediaItems.isEmpty {
                EmptyBucketStateView(
                    systemImage: "film.stack.fill",
                    title: "Find Space-Hungry Videos & Files",
                    description: "Scans your personal folders while hiding macOS system files by default. Every item is badged Safe, Review, or Danger with instant Quick Look preview.",
                    actionTitle: "Scan Large Media",
                    accentColor: GoCleanTheme.accentCoral,
                    isLoading: viewModel.isScanningLargeMedia
                ) {
                    Task { await viewModel.scanLargeMedia() }
                }
            } else if filteredItems.isEmpty {
                EmptyBucketStateView(
                    systemImage: "checkmark.circle.fill",
                    title: "No Matching Files Over \(viewModel.largeMediaThresholdMB) MB",
                    description: "Try lowering the minimum file size threshold, clearing the safety filter, or toggling off 'Videos Only'.",
                    actionTitle: "Scan Again",
                    accentColor: GoCleanTheme.accentEmerald,
                    isLoading: viewModel.isScanningLargeMedia
                ) {
                    Task { await viewModel.scanLargeMedia() }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            mediaRow(item)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
    }

    private var controlStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Toggle("Videos Only", isOn: $viewModel.largeMediaVideosOnly)
                    .toggleStyle(.switch)
                    .onChange(of: viewModel.largeMediaVideosOnly) { _, _ in
                        Task { await viewModel.scanLargeMedia() }
                    }

                Divider().frame(height: 18)

                Toggle("Show System Files", isOn: $viewModel.largeMediaIncludeSystemFiles)
                    .toggleStyle(.switch)
                    .help("Off by default. When enabled, system & Library files appear flagged with a red Danger badge.")
                    .onChange(of: viewModel.largeMediaIncludeSystemFiles) { _, _ in
                        Task { await viewModel.scanLargeMedia() }
                    }

                Divider().frame(height: 18)

                HStack(spacing: 8) {
                    Text("Min Size:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Min Size", selection: $viewModel.largeMediaThresholdMB) {
                        ForEach(thresholds, id: \.self) { mb in
                            Text(mb >= 1024 ? "1 GB" : "\(mb) MB").tag(mb)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 310)
                    .onChange(of: viewModel.largeMediaThresholdMB) { _, _ in
                        Task { await viewModel.scanLargeMedia() }
                    }
                }

                Spacer()
            }

            if !viewModel.largeMediaItems.isEmpty {
                HStack(spacing: 6) {
                    safetyFilterPill(title: "All", level: nil, count: viewModel.largeMediaItems.count)
                    ForEach([ConfidenceLevel.high, .review, .danger], id: \.self) { lvl in
                        let count = viewModel.largeMediaItems.filter { $0.confidence == lvl }.count
                        if count > 0 {
                            safetyFilterPill(title: lvl.rawValue, level: lvl, count: count)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func safetyFilterPill(title: String, level: ConfidenceLevel?, count: Int) -> some View {
        let active = selectedSafety == level
        let color = level.map { GoCleanTheme.color(for: $0) } ?? GoCleanTheme.accentCoral
        return Button {
            selectedSafety = level
        } label: {
            Text("\(title) (\(count))")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? color : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func mediaRow(_ item: CleanupItem) -> some View {
        let staged = viewModel.isStaged(url: item.url)
        let isDanger = item.confidence == .danger
        return GlassCard(padding: 10, cornerRadius: 12) {
            HStack(spacing: 12) {
                AsyncThumbnailView(url: item.url, size: CGSize(width: 64, height: 42))
                    .onTapGesture {
                        QuickLookController.shared.preview(url: item.url)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        ConfidenceBadge(level: item.confidence)
                        if let tag = item.tag {
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(GoCleanTheme.accentCoral.opacity(0.14), in: Capsule())
                                .foregroundStyle(GoCleanTheme.accentCoral)
                        }
                    }
                    Text(isDanger ? item.rationale : item.url.path)
                        .font(.caption2)
                        .foregroundStyle(isDanger ? GoCleanTheme.accentDanger : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(ByteFormatting.relativeDateString(from: item.lastModified))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(ByteFormatting.string(from: item.size))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(isDanger ? GoCleanTheme.accentDanger : GoCleanTheme.accentCoral)
                    .frame(width: 88, alignment: .trailing)

                Button {
                    QuickLookController.shared.preview(url: item.url)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Preview with Quick Look")

                Button {
                    QuickLookController.shared.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "folder")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    viewModel.toggleStage(item: item)
                } label: {
                    Image(systemName: staged ? "checkmark.circle.fill" : (isDanger ? "exclamationmark.shield" : "plus.circle.fill"))
                        .font(.title3)
                        .foregroundStyle(staged ? GoCleanTheme.accentEmerald : (isDanger ? GoCleanTheme.accentDanger : GoCleanTheme.accentCoral))
                }
                .buttonStyle(.plain)
                .help(isDanger ? "System/Danger file — verify carefully before staging" : (staged ? "Remove from Collector" : "Stage in Collector"))
            }
        }
    }
}
