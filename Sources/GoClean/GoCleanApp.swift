import AppKit
import SwiftUI

final class GoCleanAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app behaves as a proper foreground GUI macOS app even when launched via `swift run`
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GoCleanApp: App {
    @NSApplicationDelegateAdaptor(GoCleanAppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("GoClean") {
            MainSplitView(viewModel: viewModel)
                .frame(minWidth: 1120, minHeight: 720)
                .onAppear {
                    viewModel.applyAppearance()
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Appearance") {
                ForEach(AppAppearance.allCases) { mode in
                    Button {
                        viewModel.appearance = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                }
            }
            CommandMenu("Scan") {
                Button("Scan Home Folder") {
                    viewModel.startDiskScan(url: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Scan Macintosh HD") {
                    viewModel.startDiskScan(url: URL(fileURLWithPath: "/"))
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Scan Custom Folder…") {
                    viewModel.pickCustomFolderAndScan()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Run All Smart Cleanup Scans") {
                    viewModel.runSmartScanAll()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                if viewModel.isScanningDisk {
                    Button("Stop Active Scan") {
                        viewModel.cancelDiskScan()
                    }
                    .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
    }
}
