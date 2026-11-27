import GoCleanCore
import SwiftUI

/// Primary application window featuring a translucent left feature sidebar,
/// live detail workspace, and persistent bottom Collector Dock.
public struct MainSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable public var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 234, ideal: 258, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                detailBackdrop
                    .ignoresSafeArea()

                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, viewModel.stagedItems.isEmpty ? 0 : 78)

                if !viewModel.stagedItems.isEmpty {
                    CollectorDockView(viewModel: viewModel)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: viewModel.stagedItems.isEmpty)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                cautionFooterBanner
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Appearance", selection: $viewModel.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help("\(mode.rawValue) Mode")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
                .help("Switch between Dark, Light, and System macOS appearance")
                .onChange(of: viewModel.appearance) { _, _ in
                    viewModel.applyAppearance()
                }

                if viewModel.isScanningDisk {
                    Button {
                        viewModel.cancelDiskScan()
                    } label: {
                        Label("Stop Scan", systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                } else {
                    Menu {
                        Button("Scan Home Folder (~)") {
                            viewModel.startDiskScan(url: FileManager.default.homeDirectoryForCurrentUser)
                        }
                        Button("Full Disk Scan (Macintosh HD)") {
                            viewModel.startDiskScan(url: URL(fileURLWithPath: "/"))
                        }
                        Divider()
                        Button("Choose Folder…") {
                            viewModel.pickCustomFolderAndScan()
                        }
                        Divider()
                        Button("Scan All Smart Buckets") {
                            viewModel.runSmartScanAll()
                        }
                    } label: {
                        Label("Scan", systemImage: "sparkle.magnifyingglass")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showFullDiskAccessSheet) {
            FullDiskAccessGuideSheet(viewModel: viewModel)
        }
        .alert("GoClean Notice", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                viewModel.alertMessage = nil
            }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .overlay(alignment: .topTrailing) {
            if let result = viewModel.lastCleanupResult {
                CleanupToastView(result: result) {
                    viewModel.lastCleanupResult = nil
                }
                .padding(18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.lastCleanupResult != nil)
    }

    // MARK: - Persistent Caution Footer

    private var cautionFooterBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(GoCleanTheme.accentAmber)

                Text("Caution: Deleting system, Library, or application files can cause macOS instability or data loss. Review Safe / Danger badges carefully — clean at your own risk.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text("Move to Trash is default")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GoCleanTheme.accentEmerald)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    // MARK: - Ambient Backdrop

    @ViewBuilder
    private var detailBackdrop: some View {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.070, blue: 0.105),
                    Color(red: 0.040, green: 0.048, blue: 0.072)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(
                RadialGradient(
                    colors: [
                        GoCleanTheme.accentTeal.opacity(0.08),
                        GoCleanTheme.accentIndigo.opacity(0.05),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 680
                )
            )
        } else {
            LinearGradient(
                colors: [
                    GoCleanTheme.accentTeal.opacity(0.04),
                    GoCleanTheme.accentIndigo.opacity(0.03),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(selection: $viewModel.selectedSection) {
            Section("Explore") {
                sidebarRow(.overview, accent: GoCleanTheme.accentTeal)
                sidebarRow(.diskMap, accent: GoCleanTheme.accentIndigo, isBusy: viewModel.isScanningDisk)
            }

            Section("Smart Cleanup") {
                sidebarRow(.orphanedAppData, accent: GoCleanTheme.accentViolet, isBusy: viewModel.isScanningOrphans)
                sidebarRow(.devAndAppCaches, accent: GoCleanTheme.accentTeal, isBusy: viewModel.isScanningDevCaches)
                sidebarRow(.dumpAndJunk, accent: GoCleanTheme.accentAmber, isBusy: viewModel.isScanningDumps)
                sidebarRow(.largeMedia, accent: GoCleanTheme.accentCoral, isBusy: viewModel.isScanningLargeMedia)
                sidebarRow(.duplicates, accent: GoCleanTheme.accentSky, isBusy: viewModel.isScanningDuplicates)
            }

            Section("Software") {
                sidebarRow(.applications, accent: GoCleanTheme.accentEmerald, isBusy: viewModel.isScanningApps)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                GoCleanLogoMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("GoClean")
                        .font(.headline.weight(.bold))
                    Text("macOS Storage Studio")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    private func sidebarRow(_ section: SidebarSection, accent: Color, isBusy: Bool = false) -> some View {
        let badgeBytes = viewModel.sidebarBadgeBytes(for: section)
        return HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20)

            Text(section.rawValue)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else if badgeBytes > 0 {
                Text(ByteFormatting.string(from: badgeBytes))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .tag(section)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !viewModel.hasFullDiskAccess {
                Button {
                    viewModel.showFullDiskAccessSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(GoCleanTheme.accentAmber)
                        Text("Enable Full Disk Access…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GoCleanTheme.accentAmber)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(GoCleanTheme.accentAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if let rootVol = viewModel.volumes.first(where: \.isRootVolume) ?? viewModel.volumes.first {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(GoCleanTheme.accentTeal)
                    Text(rootVol.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ByteFormatting.string(from: rootVol.importantAvailableCapacity)) free")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [GoCleanTheme.accentTeal, GoCleanTheme.accentIndigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, geo.size.width * rootVol.usedFraction))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.selectedSection {
        case .overview:
            OverviewView(viewModel: viewModel)
        case .diskMap:
            DiskMapContainerView(viewModel: viewModel)
        case .orphanedAppData:
            OrphanedAppDataView(viewModel: viewModel)
        case .devAndAppCaches:
            DevCachesView(viewModel: viewModel)
        case .dumpAndJunk:
            DumpAndJunkView(viewModel: viewModel)
        case .largeMedia:
            LargeMediaView(viewModel: viewModel)
        case .duplicates:
            DuplicateFilesView(viewModel: viewModel)
        case .applications:
            ApplicationsView(viewModel: viewModel)
        }
    }
}

/// Floating summary toast shown after Move to Trash / Uninstall operations complete.
private struct CleanupToastView: View {
    let result: CleanupExecutionResult
    let onDismiss: () -> Void

    var body: some View {
        GlassCard(padding: 14, cornerRadius: 14) {
            HStack(spacing: 12) {
                Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(result.failures.isEmpty ? GoCleanTheme.accentEmerald : GoCleanTheme.accentAmber)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.mode == .moveToTrash ? "Moved to Trash" : "Permanently Erased")
                        .font(.subheadline.weight(.semibold))
                    Text("\(result.succeededURLs.count) items • \(ByteFormatting.string(from: result.freedBytes)) freed\(result.failures.isEmpty ? "" : " • \(result.failures.count) failed")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 380)
    }
}

/// Guided modal helping users add locally-built `GoClean.app` into macOS Full Disk Access.
private struct FullDiskAccessGuideSheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                GoCleanLogoMark(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant Full Disk Access to GoClean")
                        .font(.title3.weight(.bold))
                    Text("Allows accurate scanning of ~/Library containers, Mail/Safari caches, and system volumes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                stepRow(
                    number: "1",
                    title: "Reveal GoClean.app in Finder",
                    detail: "macOS doesn't always auto-list locally built apps in Privacy settings. Click below to highlight GoClean.app in Finder."
                )
                stepRow(
                    number: "2",
                    title: "Add GoClean.app in System Settings",
                    detail: "Open Full Disk Access Settings, click the '+' button (or drag GoClean.app from Finder straight into the list), and toggle it ON."
                )
                stepRow(
                    number: "3",
                    title: "Recheck or Relaunch",
                    detail: "macOS may prompt you to Quit & Reopen GoClean for the new permission to take effect."
                )
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.revealAppInFinder()
                } label: {
                    Label("Reveal GoClean.app", systemImage: "folder.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.openFullDiskAccessSettings()
                } label: {
                    Label("Open Full Disk Access", systemImage: "gearshape.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(GoCleanTheme.accentAmber)

                Spacer()

                Button("Recheck") {
                    viewModel.refreshEnvironment()
                    if viewModel.hasFullDiskAccess {
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 520)
    }

    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(GoCleanTheme.accentAmber.opacity(0.18), in: Circle())
                .foregroundStyle(GoCleanTheme.accentAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
