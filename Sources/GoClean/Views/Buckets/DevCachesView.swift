import GoCleanCore
import SwiftUI

/// Displays Developer & App Caches including `node_modules` (with project dormancy age),
/// Xcode DerivedData, SwiftPM `.build`, Rust `target/`, Python venvs, and global package caches.
public struct DevCachesView: View {
    @Bindable public var viewModel: AppViewModel
    @State private var selectedCategory: DevCacheCategory? = nil
    @State private var searchText = ""

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredItems: [CleanupItem] {
        viewModel.devCacheItems.filter { item in
            if let selectedCategory, item.tag != selectedCategory.rawValue {
                return false
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return item.displayName.lowercased().contains(q) ||
                    item.url.path.lowercased().contains(q)
            }
            return true
        }
    }

    private var filteredBytes: UInt64 {
        filteredItems.reduce(0) { $0 &+ $1.size }
    }

    public var body: some View {
        VStack(spacing: 16) {
            BucketHeaderView(
                title: "Dev & App Caches",
                subtitle: "node_modules, Xcode DerivedData, Rust/Swift/Gradle artifacts, Homebrew/npm/pip/cargo caches & app caches",
                systemImage: "hammer.circle.fill",
                accentColor: GoCleanTheme.accentTeal,
                totalBytes: viewModel.totalDevCacheBytes,
                itemCount: viewModel.devCacheItems.count,
                isLoading: viewModel.isScanningDevCaches,
                onScan: { Task { await viewModel.scanDevCaches() } },
                extraActionTitle: "Collect Filtered (\(ByteFormatting.string(from: filteredBytes)))",
                onExtraAction: {
                    viewModel.stageItems(filteredItems)
                }
            )

            if !viewModel.hasScannedDevCaches && viewModel.devCacheItems.isEmpty {
                EmptyBucketStateView(
                    systemImage: "hammer.circle.fill",
                    title: "Reclaim Developer & Cache Bloat",
                    description: "Find dormant node_modules folders, Xcode DerivedData, Rust target directories, SwiftPM .build caches, and global npm/Homebrew/pip/Cargo caches.",
                    actionTitle: "Scan Dev & App Caches",
                    accentColor: GoCleanTheme.accentTeal,
                    isLoading: viewModel.isScanningDevCaches
                ) {
                    Task { await viewModel.scanDevCaches() }
                }
            } else {
                filterBar

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            devCacheRow(item)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryPill(title: "All", category: nil, count: viewModel.devCacheItems.count)
                    ForEach(DevCacheCategory.allCases, id: \.self) { cat in
                        let count = viewModel.devCacheItems.filter { $0.tag == cat.rawValue }.count
                        if count > 0 {
                            categoryPill(title: cat.rawValue, category: cat, count: count)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search project or cache…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: 220)
        }
    }

    private func categoryPill(title: String, category: DevCacheCategory?, count: Int) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? GoCleanTheme.accentTeal : Color.primary.opacity(0.07),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func devCacheRow(_ item: CleanupItem) -> some View {
        let staged = viewModel.isStaged(url: item.url)
        return GlassCard(padding: 12, cornerRadius: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GoCleanTheme.accentTeal.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconForDevTag(item.tag))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GoCleanTheme.accentTeal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        ConfidenceBadge(level: item.confidence)

                        if let tag = item.tag {
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(GoCleanTheme.accentTeal.opacity(0.12), in: Capsule())
                                .foregroundStyle(GoCleanTheme.accentTeal)
                        }

                        if let days = item.dormantDays, days >= 14 {
                            Text("Dormant \(days)d")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(GoCleanTheme.accentAmber.opacity(0.16), in: Capsule())
                                .foregroundStyle(GoCleanTheme.accentAmber)
                        }
                    }

                    Text(item.url.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(ByteFormatting.string(from: item.size))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 82, alignment: .trailing)

                Button {
                    QuickLookController.shared.revealInFinder(url: item.url)
                } label: {
                    Image(systemName: "folder")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")

                Button {
                    viewModel.toggleStage(item: item)
                } label: {
                    Image(systemName: staged ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(staged ? GoCleanTheme.accentEmerald : GoCleanTheme.accentTeal)
                }
                .buttonStyle(.plain)
                .help(staged ? "Remove from Collector" : "Stage in Collector")
            }
        }
    }

    private func iconForDevTag(_ tag: String?) -> String {
        switch tag {
        case DevCacheCategory.nodeModules.rawValue: return "shippingbox.fill"
        case DevCacheCategory.xcodeAndSwift.rawValue: return "swift"
        case DevCacheCategory.packageManagers.rawValue: return "archivebox.fill"
        case DevCacheCategory.appCaches.rawValue: return "bolt.horizontal.circle.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }
}
