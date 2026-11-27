import GoCleanCore
import SwiftUI

/// Persistent glass bottom staging dock inspired by DaisyDisk's Collector,
/// with Move to Trash as the safe default and Permanent Erase gated by explicit confirmation.
public struct CollectorDockView: View {
    @Bindable public var viewModel: AppViewModel
    @State private var showPermanentEraseConfirm = false

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 10) {
            if viewModel.isCollectorExpanded {
                expandedQueuePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            dockBar
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: viewModel.isCollectorExpanded)
        .confirmationDialog(
            "Permanently Erase \(viewModel.stagedItems.count) Items?",
            isPresented: $showPermanentEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("Permanently Erase (\(ByteFormatting.string(from: viewModel.totalStagedBytes)))", role: .destructive) {
                Task { await viewModel.executeCollector(mode: .permanentErase) }
            }
            Button("Move to Trash Instead") {
                Task { await viewModel.executeCollector(mode: .moveToTrash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanent Erase skips the macOS Trash and cannot be undone. Move to Trash is recommended if you want the option to recover files.")
        }
    }

    private var dockBar: some View {
        GlassCard(padding: 12, cornerRadius: 18) {
            HStack(spacing: 14) {
                Button {
                    viewModel.isCollectorExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(GoCleanTheme.accentCoral.opacity(0.18))
                                .frame(width: 38, height: 38)
                            Image(systemName: "tray.full.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(GoCleanTheme.accentCoral)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text("Collector")
                                    .font(.headline)
                                Text("\(viewModel.stagedItems.count) \(viewModel.stagedItems.count == 1 ? "item" : "items")")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            Text("\(ByteFormatting.string(from: viewModel.totalStagedBytes)) staged for cleanup")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Image(systemName: viewModel.isCollectorExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Clear") {
                    viewModel.clearCollector()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExecutingCleanup)

                Button {
                    showPermanentEraseConfirm = true
                } label: {
                    Label("Erase…", systemImage: "flame.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isExecutingCleanup)
                .help("Permanently delete without moving to Trash")

                Button {
                    Task { await viewModel.executeCollector(mode: .moveToTrash) }
                } label: {
                    if viewModel.isExecutingCleanup {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Cleaning…")
                        }
                    } else {
                        Label("Move to Trash", systemImage: "trash.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(GoCleanTheme.accentCoral)
                .controlSize(.large)
                .disabled(viewModel.isExecutingCleanup)
            }
        }
    }

    private var expandedQueuePanel: some View {
        GlassCard(padding: 14, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Staged Cleanup Queue")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("Protected system paths are automatically blocked by SafetyGuard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.stagedItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(GoCleanTheme.accentCoral)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.displayName)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(item.url.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                ConfidenceBadge(level: item.confidence)

                                Text(item.bucket.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())

                                Text(ByteFormatting.string(from: item.size))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .frame(width: 72, alignment: .trailing)

                                Button {
                                    viewModel.unstage(id: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove from Collector")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
    }
}
