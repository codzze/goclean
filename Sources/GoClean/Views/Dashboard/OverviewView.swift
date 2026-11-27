import GoCleanCore
import SwiftUI

/// Home Dashboard with live volume storage telemetry rings, quick scan launchers,
/// and interactive Smart Cleanup bucket summary cards.
public struct OverviewView: View {
    @Bindable public var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader

                if !viewModel.hasFullDiskAccess {
                    fullDiskAccessBanner
                }

                volumesSection

                smartBucketsGrid
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    GoCleanTheme.accentTeal.opacity(0.05),
                    GoCleanTheme.accentIndigo.opacity(0.04),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        GlassCard(padding: 22, cornerRadius: 20) {
            HStack(spacing: 20) {
                GoCleanLogoMark(size: 56)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("GoClean")
                            .font(.largeTitle.weight(.bold))
                        Text("macOS Native")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(GoCleanTheme.accentTeal.opacity(0.16), in: Capsule())
                            .foregroundStyle(GoCleanTheme.accentTeal)
                    }

                    Text("Visualize physical APFS storage with the Luminous Orbital Map, reclaim hidden developer & orphaned app bloat, and cleanly uninstall apps from App Store, Homebrew, or direct curl installs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)

                    HStack(spacing: 10) {
                        Button {
                            viewModel.startDiskScan(url: FileManager.default.homeDirectoryForCurrentUser)
                        } label: {
                            Label("Scan Home Folder", systemImage: "house.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(GoCleanTheme.accentTeal)
                        .controlSize(.large)

                        Button {
                            viewModel.startDiskScan(url: URL(fileURLWithPath: "/"))
                        } label: {
                            Label("Full Disk Scan", systemImage: "internaldrive.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            viewModel.pickCustomFolderAndScan()
                        } label: {
                            Label("Choose Folder…", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            viewModel.runSmartScanAll()
                        } label: {
                            Label("Smart Scan All", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .tint(GoCleanTheme.accentIndigo)
                        .controlSize(.large)
                    }
                    .padding(.top, 4)
                }

                Spacer()

                if viewModel.totalReclaimableSmartBytes > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Reclaimable Found")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(ByteFormatting.string(from: viewModel.totalReclaimableSmartBytes))
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [GoCleanTheme.accentTeal, GoCleanTheme.accentIndigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        Text("Across Smart Buckets")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    // MARK: - Full Disk Access Callout

    private var fullDiskAccessBanner: some View {
        GlassCard(padding: 14, cornerRadius: 14) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(GoCleanTheme.accentAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access Recommended")
                        .font(.subheadline.weight(.semibold))
                    Text("macOS doesn't auto-list local apps — click Reveal App and drag GoClean.app into System Settings → Full Disk Access (or click '+').")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.revealAppInFinder()
                } label: {
                    Label("Reveal App", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button("Open Settings") {
                    viewModel.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(GoCleanTheme.accentAmber)

                Button("Recheck") {
                    viewModel.refreshEnvironment()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Volumes Section

    private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage Volumes")
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    viewModel.refreshEnvironment()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 14)], spacing: 14) {
                ForEach(viewModel.volumes) { volume in
                    VolumeCardView(volume: volume) {
                        viewModel.startDiskScan(url: volume.url)
                    }
                }
            }
        }
    }

    // MARK: - Smart Buckets Overview Grid

    private var smartBucketsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Cleanup Modules")
                .font(.title3.weight(.bold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                SmartModuleCard(
                    title: "Orphaned App Data",
                    subtitle: "Leftover ~/Library data from uninstalled apps",
                    systemImage: "app.dashed",
                    accent: GoCleanTheme.accentViolet,
                    bytes: viewModel.totalOrphanBytes,
                    hasScanned: viewModel.hasScannedOrphans,
                    isScanning: viewModel.isScanningOrphans
                ) {
                    viewModel.selectedSection = .orphanedAppData
                    if !viewModel.hasScannedOrphans {
                        Task { await viewModel.scanOrphans() }
                    }
                }

                SmartModuleCard(
                    title: "Dev & App Caches",
                    subtitle: "node_modules, Xcode DerivedData, Rust/Go/Homebrew caches",
                    systemImage: "hammer.circle.fill",
                    accent: GoCleanTheme.accentTeal,
                    bytes: viewModel.totalDevCacheBytes,
                    hasScanned: viewModel.hasScannedDevCaches,
                    isScanning: viewModel.isScanningDevCaches
                ) {
                    viewModel.selectedSection = .devAndAppCaches
                    if !viewModel.hasScannedDevCaches {
                        Task { await viewModel.scanDevCaches() }
                    }
                }

                SmartModuleCard(
                    title: "Dump & System Junk",
                    subtitle: "Crash dumps (.ips/.dmp), old DMG/PKG installers, logs",
                    systemImage: "doc.badge.gearshape.fill",
                    accent: GoCleanTheme.accentAmber,
                    bytes: viewModel.totalDumpJunkBytes,
                    hasScanned: viewModel.hasScannedDumps,
                    isScanning: viewModel.isScanningDumps
                ) {
                    viewModel.selectedSection = .dumpAndJunk
                    if !viewModel.hasScannedDumps {
                        Task { await viewModel.scanDumpAndJunk() }
                    }
                }

                SmartModuleCard(
                    title: "Large Videos & Media",
                    subtitle: "Oversized videos & media with Quick Look preview",
                    systemImage: "film.stack.fill",
                    accent: GoCleanTheme.accentCoral,
                    bytes: viewModel.totalLargeMediaBytes,
                    hasScanned: viewModel.hasScannedLargeMedia,
                    isScanning: viewModel.isScanningLargeMedia
                ) {
                    viewModel.selectedSection = .largeMedia
                    if !viewModel.hasScannedLargeMedia {
                        Task { await viewModel.scanLargeMedia() }
                    }
                }

                SmartModuleCard(
                    title: "Duplicate Files",
                    subtitle: "Exact SHA-256 verified duplicate copies & smart select",
                    systemImage: "square.on.square.dashed",
                    accent: GoCleanTheme.accentSky,
                    bytes: viewModel.totalDuplicateWastedBytes,
                    hasScanned: viewModel.hasScannedDuplicates,
                    isScanning: viewModel.isScanningDuplicates
                ) {
                    viewModel.selectedSection = .duplicates
                    if !viewModel.hasScannedDuplicates {
                        viewModel.scanDuplicates()
                    }
                }

                SmartModuleCard(
                    title: "Application Manager",
                    subtitle: "App Store, Homebrew Casks/Formulae, Direct & Curl CLIs",
                    systemImage: "square.grid.2x2.fill",
                    accent: GoCleanTheme.accentEmerald,
                    bytes: viewModel.installedApps.reduce(0) { $0 &+ $1.totalFootprint },
                    hasScanned: viewModel.hasScannedApps,
                    isScanning: viewModel.isScanningApps,
                    customCountLabel: viewModel.hasScannedApps ? "\(viewModel.installedApps.count) installed" : nil
                ) {
                    viewModel.selectedSection = .applications
                    if !viewModel.hasScannedApps {
                        Task { await viewModel.scanApplications() }
                    }
                }
            }
        }
    }
}

private struct VolumeCardView: View {
    let volume: VolumeInfo
    let onScan: () -> Void

    var body: some View {
        GlassCard(padding: 16, cornerRadius: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: volume.usedFraction)
                        .stroke(
                            AngularGradient(
                                colors: [GoCleanTheme.accentTeal, GoCleanTheme.accentIndigo, GoCleanTheme.accentCoral],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(Int(volume.usedFraction * 100))%")
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        Text("used")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                            .foregroundStyle(GoCleanTheme.accentTeal)
                        Text(volume.name)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Text("\(ByteFormatting.string(from: volume.usedCapacity)) used of \(ByteFormatting.string(from: volume.totalCapacity))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text("\(ByteFormatting.string(from: volume.importantAvailableCapacity)) available")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(GoCleanTheme.accentEmerald)
                }

                Spacer()

                Button("Scan", action: onScan)
                    .buttonStyle(.borderedProminent)
                    .tint(GoCleanTheme.accentTeal)
                    .controlSize(.small)
            }
        }
    }
}

private struct SmartModuleCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let bytes: UInt64
    let hasScanned: Bool
    let isScanning: Bool
    var customCountLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            GlassCard(padding: 16, cornerRadius: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accent.opacity(0.16))
                                .frame(width: 38, height: 38)
                            Image(systemName: systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(accent)
                        }

                        Spacer()

                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else if hasScanned {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(ByteFormatting.string(from: bytes))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(accent)
                                if let customCountLabel {
                                    Text(customCountLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Explore")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(accent.opacity(0.12), in: Capsule())
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
