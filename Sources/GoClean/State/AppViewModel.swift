import AppKit
import Foundation
import GoCleanCore
import Observation

/// Left sidebar navigation destinations.
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case diskMap = "Disk Map"
    case orphanedAppData = "Orphaned App Data"
    case devAndAppCaches = "Dev & App Caches"
    case dumpAndJunk = "Dump & System Junk"
    case largeMedia = "Large Videos & Media"
    case duplicates = "Duplicate Files"
    case applications = "Applications"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .diskMap: return "circle.hexagongrid.circle.fill"
        case .orphanedAppData: return "app.dashed"
        case .devAndAppCaches: return "hammer.circle.fill"
        case .dumpAndJunk: return "doc.badge.gearshape.fill"
        case .largeMedia: return "film.stack.fill"
        case .duplicates: return "square.on.square.dashed"
        case .applications: return "square.grid.2x2.fill"
        }
    }

    public var accentColorName: String { rawValue }
}

/// Visualization modes supported inside the Disk Map view.
public enum DiskMapViewMode: String, CaseIterable, Identifiable {
    case orbital = "Orbital Map"
    case treemap = "Treemap"
    case list = "Tree List"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .orbital: return "sun.max.circle.fill"
        case .treemap: return "rectangle.3.group.fill"
        case .list: return "list.bullet.indent"
        }
    }
}

/// Root `@Observable` state coordinator driving GoClean's UI and background engines.
@MainActor
@Observable
public final class AppViewModel {
    // MARK: - Navigation & Environment
    public var selectedSection: SidebarSection = .overview
    public var volumes: [VolumeInfo] = []
    public var hasFullDiskAccess: Bool = false
    public var showFullDiskAccessSheet: Bool = false
    public var appearance: AppAppearance = {
        if let saved = UserDefaults.standard.string(forKey: "GoClean.appearance"),
           let parsed = AppAppearance(rawValue: saved) {
            return parsed
        }
        return .system
    }() {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "GoClean.appearance")
            applyAppearance()
        }
    }

    public func applyAppearance() {
        let targetAppearance = appearance.nsAppearance
        NSApp?.appearance = targetAppearance
        // Clear any per-window overrides so titlebar, toolbar, sidebar, and SwiftUI stay 100% synced
        for window in NSApp?.windows ?? [] {
            window.appearance = targetAppearance
            window.invalidateShadow()
        }
    }

    // MARK: - Disk Scanner & Orbital Map State
    public var scanTargetURL: URL = FileManager.default.homeDirectoryForCurrentUser
    public var isScanningDisk: Bool = false
    public var scanProgress: ScanProgress?
    public var rootNode: FileNode?
    public var currentZoomNode: FileNode?
    public var hoveredNodeID: UUID?
    public var selectedNodeID: UUID?
    public var diskMapMode: DiskMapViewMode = .orbital
    public var scanErrorMessage: String?

    private var diskScanTask: Task<Void, Never>?

    // MARK: - Smart Cleanup Buckets State
    public var orphanGroups: [OrphanAppGroup] = []
    public var isScanningOrphans: Bool = false
    public var hasScannedOrphans: Bool = false

    public var devCacheItems: [CleanupItem] = []
    public var isScanningDevCaches: Bool = false
    public var hasScannedDevCaches: Bool = false

    public var dumpJunkItems: [CleanupItem] = []
    public var isScanningDumps: Bool = false
    public var hasScannedDumps: Bool = false

    public var largeMediaItems: [CleanupItem] = []
    public var isScanningLargeMedia: Bool = false
    public var hasScannedLargeMedia: Bool = false
    public var largeMediaThresholdMB: Int = 50
    public var largeMediaVideosOnly: Bool = true
    public var largeMediaIncludeSystemFiles: Bool = false

    public var duplicateGroups: [DuplicateGroup] = []
    public var isScanningDuplicates: Bool = false
    public var hasScannedDuplicates: Bool = false
    public var duplicateMinSizeMB: Int = 1
    public var duplicateProgress: DuplicateScanProgress?
    public var duplicateScanRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    private var duplicateScanTask: Task<Void, Never>?

    // MARK: - Applications Manager State
    public var installedApps: [InstalledApplication] = []
    public var isScanningApps: Bool = false
    public var hasScannedApps: Bool = false

    // MARK: - Collector Staging Tray State
    public var stagedItems: [CleanupItem] = []
    public var isCollectorExpanded: Bool = false
    public var isExecutingCleanup: Bool = false
    public var lastCleanupResult: CleanupExecutionResult?
    public var alertMessage: String?

    // MARK: - Engines
    private let scanEngine = ConcurrentScanEngine()
    private let safetyGuard = SafetyGuard()
    private let executor = CleanupExecutor()
    private let permissionMonitor = PermissionMonitor()

    public init() {
        refreshEnvironment()
    }

    public func refreshEnvironment() {
        volumes = ConcurrentScanEngine.mountedVolumes()
        hasFullDiskAccess = permissionMonitor.hasFullDiskAccess()
    }

    // MARK: - Aggregated Telemetry

    public var totalOrphanBytes: UInt64 { orphanGroups.reduce(0) { $0 &+ $1.totalSize } }
    public var totalDevCacheBytes: UInt64 { devCacheItems.reduce(0) { $0 &+ $1.size } }
    public var totalDumpJunkBytes: UInt64 { dumpJunkItems.reduce(0) { $0 &+ $1.size } }
    public var totalLargeMediaBytes: UInt64 { largeMediaItems.reduce(0) { $0 &+ $1.size } }
    public var totalDuplicateWastedBytes: UInt64 { duplicateGroups.reduce(0) { $0 &+ $1.wastedSize } }
    public var totalStagedBytes: UInt64 { stagedItems.reduce(0) { $0 &+ $1.size } }

    public var totalReclaimableSmartBytes: UInt64 {
        totalOrphanBytes &+ totalDevCacheBytes &+ totalDumpJunkBytes &+ totalDuplicateWastedBytes
    }

    public func sidebarBadgeBytes(for section: SidebarSection) -> UInt64 {
        switch section {
        case .overview, .diskMap, .applications: return 0
        case .orphanedAppData: return totalOrphanBytes
        case .devAndAppCaches: return totalDevCacheBytes
        case .dumpAndJunk: return totalDumpJunkBytes
        case .largeMedia: return totalLargeMediaBytes
        case .duplicates: return totalDuplicateWastedBytes
        }
    }

    // MARK: - Disk Scanner Controls

    public func startDiskScan(url: URL? = nil, navigateToMap: Bool = true) {
        let target = (url ?? scanTargetURL).standardizedFileURL
        scanTargetURL = target
        diskScanTask?.cancel()
        scanErrorMessage = nil
        isScanningDisk = true
        hoveredNodeID = nil
        selectedNodeID = nil

        if navigateToMap {
            selectedSection = .diskMap
        }

        let engine = scanEngine
        diskScanTask = Task {
            do {
                for try await progress in engine.scan(url: target) {
                    self.scanProgress = progress
                    if let node = progress.rootNode {
                        self.rootNode = node
                        if progress.isComplete || self.currentZoomNode == nil {
                            self.currentZoomNode = node
                        } else if !progress.isComplete {
                            self.currentZoomNode = node
                        }
                    }
                    if progress.isComplete {
                        self.isScanningDisk = false
                    }
                }
                self.isScanningDisk = false
                self.refreshEnvironment()
            } catch is CancellationError {
                self.isScanningDisk = false
            } catch {
                self.isScanningDisk = false
                self.scanErrorMessage = error.localizedDescription
            }
        }
    }

    public func cancelDiskScan() {
        diskScanTask?.cancel()
        diskScanTask = nil
        isScanningDisk = false
    }

    public func pickCustomFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        panel.message = "Choose a folder or drive to map in GoClean"
        if panel.runModal() == .OK, let url = panel.url {
            startDiskScan(url: url, navigateToMap: true)
        }
    }

    public func zoomTo(node: FileNode) {
        guard node.isDirectory else {
            selectedNodeID = node.id
            return
        }
        currentZoomNode = node
        hoveredNodeID = nil
        selectedNodeID = nil
    }

    public func zoomOut() {
        if let parent = currentZoomNode?.parent {
            currentZoomNode = parent
            hoveredNodeID = nil
            selectedNodeID = nil
        }
    }

    // MARK: - Smart Buckets Orchestration

    public func runSmartScanAll() {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.scanOrphans() }
                group.addTask { await self.scanDevCaches() }
                group.addTask { await self.scanDumpAndJunk() }
                group.addTask { await self.scanLargeMedia() }
                group.addTask { await self.scanApplications() }
            }
        }
    }

    public func scanOrphans() async {
        guard !isScanningOrphans else { return }
        isScanningOrphans = true
        let analyzer = OrphanAppAnalyzer()
        let results = await analyzer.analyze()
        orphanGroups = results
        hasScannedOrphans = true
        isScanningOrphans = false
    }

    public func scanDevCaches() async {
        guard !isScanningDevCaches else { return }
        isScanningDevCaches = true
        let analyzer = DevCacheAnalyzer()
        let results = await analyzer.analyze(existingTree: rootNode)
        devCacheItems = results
        hasScannedDevCaches = true
        isScanningDevCaches = false
    }

    public func scanDumpAndJunk() async {
        guard !isScanningDumps else { return }
        isScanningDumps = true
        let analyzer = DumpAndJunkAnalyzer()
        let results = await analyzer.analyze(existingTree: rootNode)
        dumpJunkItems = results
        hasScannedDumps = true
        isScanningDumps = false
    }

    public func scanLargeMedia() async {
        guard !isScanningLargeMedia else { return }
        isScanningLargeMedia = true
        let thresholdBytes = UInt64(max(1, largeMediaThresholdMB)) * 1024 * 1024
        let analyzer = LargeMediaAnalyzer(rootDirectory: scanTargetURL)
        let results = await analyzer.analyze(
            existingTree: rootNode,
            minimumBytes: thresholdBytes,
            videosOnly: largeMediaVideosOnly,
            includeSystemFiles: largeMediaIncludeSystemFiles
        )
        largeMediaItems = results
        hasScannedLargeMedia = true
        isScanningLargeMedia = false
    }

    public func scanDuplicates(root: URL? = nil) {
        let target = (root ?? duplicateScanRoot).standardizedFileURL
        duplicateScanRoot = target
        duplicateScanTask?.cancel()
        isScanningDuplicates = true
        duplicateProgress = DuplicateScanProgress(
            stage: "Starting duplicate scan…",
            filesInspected: 0,
            candidateGroups: 0,
            verifiedGroups: 0
        )

        let minBytes = UInt64(max(1, duplicateMinSizeMB)) * 1024 * 1024
        let finder = DuplicateFinder()
        duplicateScanTask = Task {
            do {
                let groups = try await finder.findDuplicates(
                    in: target,
                    minimumBytes: minBytes,
                    onProgress: { progress in
                        Task { @MainActor in
                            self.duplicateProgress = progress
                        }
                    }
                )
                self.duplicateGroups = groups
                self.hasScannedDuplicates = true
                self.isScanningDuplicates = false
            } catch is CancellationError {
                self.isScanningDuplicates = false
            } catch {
                self.isScanningDuplicates = false
                self.alertMessage = "Duplicate scan failed: \(error.localizedDescription)"
            }
        }
    }

    public func cancelDuplicateScan() {
        duplicateScanTask?.cancel()
        duplicateScanTask = nil
        isScanningDuplicates = false
    }

    public func smartStageDuplicates(strategy: DuplicateSelectionStrategy) {
        let selected = DuplicateFinder.selectDuplicates(in: duplicateGroups, strategy: strategy)
        stageItems(selected)
    }

    public func scanApplications() async {
        guard !isScanningApps else { return }
        isScanningApps = true
        let engine = ApplicationDiscoveryEngine()
        let apps = await engine.discoverAll()
        installedApps = apps
        hasScannedApps = true
        isScanningApps = false
    }

    // MARK: - Collector Staging Tray

    public func isStaged(url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return stagedItems.contains { $0.id == key }
    }

    public func toggleStage(item: CleanupItem) {
        if isStaged(url: item.url) {
            unstage(id: item.id)
        } else {
            stageItems([item])
        }
    }

    public func stageNode(_ node: FileNode) {
        let classifier = FileSafetyClassifier()
        let evaluated = classifier.classify(
            url: node.url,
            defaultConfidence: .review,
            defaultRationale: "Selected from Disk Map"
        )
        let item = CleanupItem(
            url: node.url,
            displayName: node.name,
            subtitle: node.url.deletingLastPathComponent().path,
            size: max(node.physicalSize, node.logicalSize),
            bucket: .diskMap,
            confidence: evaluated.confidence,
            rationale: evaluated.rationale,
            lastModified: node.modificationDate,
            tag: node.dominantCategory.rawValue,
            isDirectory: node.isDirectory
        )
        stageItems([item])
    }

    public func stageItems(_ items: [CleanupItem]) {
        var existingIDs = Set(stagedItems.map(\.id))
        var blockedReasons: [String] = []

        for item in items {
            if existingIDs.contains(item.id) { continue }
            switch safetyGuard.validate(url: item.url) {
            case .allowed:
                stagedItems.append(item)
                existingIDs.insert(item.id)
            case .blocked(let reason):
                blockedReasons.append(reason)
            }
        }

        stagedItems.sort { $0.size > $1.size }

        if let firstBlock = blockedReasons.first {
            alertMessage = "Protected path skipped: \(firstBlock)"
        }
    }

    public func unstage(id: String) {
        stagedItems.removeAll { $0.id == id }
    }

    public func clearCollector() {
        stagedItems.removeAll()
        isCollectorExpanded = false
    }

    public func executeCollector(mode: DeletionMode) async {
        guard !stagedItems.isEmpty, !isExecutingCleanup else { return }
        isExecutingCleanup = true
        let batch = stagedItems
        let result = await executor.execute(items: batch, mode: mode)

        let succeededSet = Set(result.succeededURLs.map { $0.standardizedFileURL.path })
        stagedItems.removeAll { succeededSet.contains($0.id) }
        pruneDeletedPaths(succeededSet)

        lastCleanupResult = result
        isExecutingCleanup = false
        if stagedItems.isEmpty {
            isCollectorExpanded = false
        }
        refreshEnvironment()
    }

    public func uninstallApplication(
        _ app: InstalledApplication,
        includeAssociatedFiles: Bool,
        mode: DeletionMode = .moveToTrash
    ) async -> CleanupExecutionResult {
        isExecutingCleanup = true
        let result = await executor.uninstall(
            application: app,
            includeAssociatedFiles: includeAssociatedFiles,
            mode: mode
        )

        let succeededSet = Set(result.succeededURLs.map { $0.standardizedFileURL.path })
        if succeededSet.contains(app.installPath.standardizedFileURL.path) {
            installedApps.removeAll { $0.id == app.id }
        }
        pruneDeletedPaths(succeededSet)
        lastCleanupResult = result
        isExecutingCleanup = false
        refreshEnvironment()
        return result
    }

    private func pruneDeletedPaths(_ deletedPaths: Set<String>) {
        guard !deletedPaths.isEmpty else { return }

        // Prune disk tree
        if let rootNode {
            for path in deletedPaths {
                rootNode.removeNode(at: URL(fileURLWithPath: path))
            }
        }

        // Prune bucket results
        orphanGroups = orphanGroups.compactMap { group in
            let remaining = group.items.filter { !deletedPaths.contains($0.id) }
            guard !remaining.isEmpty else { return nil }
            return OrphanAppGroup(
                id: group.id,
                appName: group.appName,
                bundleHint: group.bundleHint,
                confidence: group.confidence,
                rationale: group.rationale,
                items: remaining
            )
        }
        devCacheItems.removeAll { deletedPaths.contains($0.id) }
        dumpJunkItems.removeAll { deletedPaths.contains($0.id) }
        largeMediaItems.removeAll { deletedPaths.contains($0.id) }
        duplicateGroups = duplicateGroups.compactMap { group in
            let remaining = group.files.filter { !deletedPaths.contains($0.id) }
            guard remaining.count >= 2 else { return nil }
            return DuplicateGroup(sha256: group.sha256, fileSize: group.fileSize, files: remaining)
        }
    }

    public func openFullDiskAccessSettings() {
        // Trigger a fresh TCC probe first, then open System Settings -> Full Disk Access
        _ = permissionMonitor.hasFullDiskAccess()
        NSWorkspace.shared.open(PermissionMonitor.fullDiskAccessSettingsURL)
    }

    /// Reveals the running GoClean.app bundle in Finder so the user can drag it into
    /// System Settings -> Privacy & Security -> Full Disk Access (or select it via '+').
    public func revealAppInFinder() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension.lowercased() == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        } else {
            // Fallback when launched directly via `swift run`
            let fallbackApp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/GoClean.app")
            if FileManager.default.fileExists(atPath: fallbackApp.path) {
                NSWorkspace.shared.activateFileViewerSelecting([fallbackApp])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            }
        }
    }
}
