import GoCleanCore
import SwiftUI

/// Unified Application Manager & Deep Uninstaller covering:
/// - Mac App Store apps (`_MASReceipt`)
/// - Homebrew Casks & Formulae (with reverse-dependency checks & `brew uninstall --zap`)
/// - Direct / DMG `.app` bundles
/// - Direct `curl` & standalone user CLI tools/toolchains
public struct ApplicationsView: View {
    @Bindable public var viewModel: AppViewModel

    @State private var selectedSource: AppInstallSource? = nil
    @State private var searchText = ""
    @State private var selectedAppID: String? = nil
    @State private var includeAssociatedLeftovers = true
    @State private var appPendingUninstall: InstalledApplication? = nil

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    private var filteredApps: [InstalledApplication] {
        viewModel.installedApps.filter { app in
            if let selectedSource, app.source != selectedSource {
                return false
            }
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                return app.name.lowercased().contains(q) ||
                    (app.bundleIdentifier?.lowercased().contains(q) ?? false) ||
                    (app.descriptionText?.lowercased().contains(q) ?? false) ||
                    app.installPath.path.lowercased().contains(q)
            }
            return true
        }
    }

    private var selectedApp: InstalledApplication? {
        filteredApps.first { $0.id == selectedAppID } ?? filteredApps.first
    }

    public var body: some View {
        VStack(spacing: 14) {
            BucketHeaderView(
                title: "Application Manager",
                subtitle: "Inspect & deeply uninstall Mac App Store apps, Homebrew Casks & Formulae, Direct downloads, and curl-installed CLI tools",
                systemImage: "square.grid.2x2.fill",
                accentColor: GoCleanTheme.accentEmerald,
                totalBytes: filteredApps.reduce(0) { $0 &+ $1.totalFootprint },
                itemCount: filteredApps.count,
                isLoading: viewModel.isScanningApps,
                onScan: { Task { await viewModel.scanApplications() } }
            )

            if !viewModel.hasScannedApps && viewModel.installedApps.isEmpty {
                EmptyBucketStateView(
                    systemImage: "square.grid.2x2.fill",
                    title: "Discover Installed Apps & CLI Tools",
                    description: "GoClean categorizes every app by install source (App Store, Homebrew Cask/Formula, Direct DMG, or curl CLI) and maps all associated ~/Library leftovers.",
                    actionTitle: "Scan Applications",
                    accentColor: GoCleanTheme.accentEmerald,
                    isLoading: viewModel.isScanningApps
                ) {
                    Task { await viewModel.scanApplications() }
                }
            } else {
                sourceFilterBar

                HSplitView {
                    appListPane
                        .frame(minWidth: 360, maxWidth: .infinity)

                    if let app = selectedApp {
                        appDetailInspector(app)
                            .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                    } else {
                        ContentUnavailableView(
                            "Select an Application",
                            systemImage: "app.badge.checkmark",
                            description: Text("Inspect total disk footprint, Homebrew dependencies, and associated ~/Library leftovers.")
                        )
                        .frame(minWidth: 360, idealWidth: 420)
                    }
                }
            }
        }
        .padding(20)
        .confirmationDialog(
            "Uninstall \(appPendingUninstall?.name ?? "Application")?",
            isPresented: Binding(
                get: { appPendingUninstall != nil },
                set: { if !$0 { appPendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = appPendingUninstall {
                let buttonLabel: String = {
                    switch app.source {
                    case .homebrewCask: return "Run brew uninstall --cask --zap"
                    case .homebrewFormula: return "Run brew uninstall \(app.homebrewToken ?? app.name)"
                    case .appStore, .directDownload, .curlCLI:
                        return includeAssociatedLeftovers
                            ? "Move App & \(app.associatedFiles.count) Leftovers to Trash"
                            : "Move \(app.name) to Trash"
                    }
                }()

                Button(buttonLabel, role: .destructive) {
                    let target = app
                    let removeLeftovers = includeAssociatedLeftovers
                    appPendingUninstall = nil
                    Task {
                        _ = await viewModel.uninstallApplication(target, includeAssociatedFiles: removeLeftovers)
                    }
                }
                Button("Cancel", role: .cancel) {
                    appPendingUninstall = nil
                }
            }
        } message: {
            if let app = appPendingUninstall {
                if !app.reverseDependencies.isEmpty {
                    Text("Warning: This Homebrew formula is required by: \(app.reverseDependencies.joined(separator: ", ")). Uninstalling it may break those packages.")
                } else {
                    Text("Total space to reclaim: \(ByteFormatting.string(from: includeAssociatedLeftovers ? app.totalFootprint : app.appSize)).")
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var sourceFilterBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    sourcePill(title: "All", source: nil, count: viewModel.installedApps.count)
                    ForEach(AppInstallSource.allCases, id: \.self) { src in
                        let count = viewModel.installedApps.filter { $0.source == src }.count
                        sourcePill(title: src.rawValue, source: src, count: count)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps, casks, formulae, CLIs…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: 240)
        }
    }

    private func sourcePill(title: String, source: AppInstallSource?, count: Int) -> some View {
        let active = selectedSource == source
        let color = source.map { GoCleanTheme.color(for: $0) } ?? GoCleanTheme.accentEmerald
        return Button {
            selectedSource = source
        } label: {
            HStack(spacing: 5) {
                if let source {
                    Image(systemName: GoCleanTheme.icon(for: source))
                        .font(.caption2)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? color : Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - App List

    private var appListPane: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredApps) { app in
                    let isSelected = selectedApp?.id == app.id
                    Button {
                        selectedAppID = app.id
                    } label: {
                        HStack(spacing: 12) {
                            AppBundleIconView(app: app, size: 34)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(app.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let ver = app.version {
                                        Text(ver)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                HStack(spacing: 6) {
                                    SourceBadge(source: app.source)
                                    ConfidenceBadge(level: app.reverseDependencies.isEmpty ? .high : .danger)
                                    if !app.associatedFiles.isEmpty {
                                        Text("+\(app.associatedFiles.count) data")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ByteFormatting.string(from: app.totalFootprint))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                if app.associatedSize > 0 {
                                    Text("App \(ByteFormatting.string(from: app.appSize))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? GoCleanTheme.accentEmerald.opacity(0.14) : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? GoCleanTheme.accentEmerald.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Detail Inspector

    private func appDetailInspector(_ app: InstalledApplication) -> some View {
        GlassCard(padding: 18, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    AppBundleIconView(app: app, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title3.weight(.bold))
                        HStack(spacing: 6) {
                            SourceBadge(source: app.source)
                            if let ver = app.version {
                                Text("v\(ver)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }

                if let desc = app.descriptionText, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Footprint Summary
                HStack(spacing: 12) {
                    metricPill(title: "Binary / App", value: ByteFormatting.string(from: app.appSize))
                    metricPill(title: "Library Data", value: ByteFormatting.string(from: app.associatedSize))
                    metricPill(title: "Total", value: ByteFormatting.string(from: app.totalFootprint), highlight: true)
                }

                // Install Path + Reveal
                HStack {
                    Text(app.installPath.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        QuickLookController.shared.revealInFinder(url: app.installPath)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Reverse dependency warning for Homebrew formulae
                if !app.reverseDependencies.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GoCleanTheme.accentAmber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dependency Warning")
                                .font(.caption.weight(.bold))
                            Text("Required by: \(app.reverseDependencies.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GoCleanTheme.accentAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Divider()

                // Associated Library / Config Leftovers
                HStack {
                    Text("Associated Data & Leftovers (\(app.associatedFiles.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !app.associatedFiles.isEmpty {
                        Toggle("Include", isOn: $includeAssociatedLeftovers)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                if app.associatedFiles.isEmpty {
                    Text("No additional ~/Library caches, containers, or config directories matched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(app.associatedFiles) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                        .font(.caption)
                                        .foregroundStyle(GoCleanTheme.accentEmerald)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayName)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        Text(item.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(ByteFormatting.string(from: item.size))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Button {
                                        viewModel.toggleStage(item: item)
                                    } label: {
                                        Image(systemName: viewModel.isStaged(url: item.url) ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundStyle(GoCleanTheme.accentEmerald)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Stage only this data item")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                Spacer(minLength: 4)

                // Uninstall Action Buttons
                HStack(spacing: 10) {
                    if !app.associatedFiles.isEmpty {
                        Button("Stage Data Only") {
                            viewModel.stageItems(app.associatedFiles)
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        appPendingUninstall = app
                    } label: {
                        Label(
                            app.source == .homebrewCask || app.source == .homebrewFormula
                                ? "Brew Uninstall…"
                                : "Deep Uninstall…",
                            systemImage: "trash.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(viewModel.isExecutingCleanup)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func metricPill(title: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(highlight ? GoCleanTheme.accentEmerald : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
