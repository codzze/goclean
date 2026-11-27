import Foundation
import GoCleanCore
import XCTest

final class SmartAnalyzersTests: XCTestCase {
    private var fakeHome: URL!
    private var fakeApps: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoCleanAnalyzers-\(UUID().uuidString)", isDirectory: true)
        fakeHome = base.appendingPathComponent("Home", isDirectory: true)
        fakeApps = base.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeApps, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base = fakeHome?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    func testOrphanAppAnalyzerFlagsDeletedAppAndPreservesInstalledAndAppleData() async throws {
        let fm = FileManager.default

        // Create an installed app: ActiveApp.app with bundle ID com.acme.activeapp
        let installedApp = fakeApps.appendingPathComponent("ActiveApp.app/Contents", isDirectory: true)
        try fm.createDirectory(at: installedApp, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.activeapp",
            "CFBundleName": "ActiveApp"
        ]
        (infoPlist as NSDictionary).write(to: installedApp.appendingPathComponent("Info.plist"), atomically: true)

        // Create ~/Library/Application Support entries
        let appSupport = fakeHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // 1. Installed app data (must NOT be flagged)
        let activeData = appSupport.appendingPathComponent("com.acme.activeapp", isDirectory: true)
        try fm.createDirectory(at: activeData, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16_384).write(to: activeData.appendingPathComponent("db.sqlite"))

        // 2. Apple system data (must NOT be flagged)
        let appleData = appSupport.appendingPathComponent("com.apple.CloudDocs", isDirectory: true)
        try fm.createDirectory(at: appleData, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16_384).write(to: appleData.appendingPathComponent("meta.bin"))

        // 3. Orphaned deleted app data (MUST be flagged with high confidence)
        let orphanData = appSupport.appendingPathComponent("com.ghostcorp.deletedwidget", isDirectory: true)
        try fm.createDirectory(at: orphanData, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 32_768).write(to: orphanData.appendingPathComponent("cache.dat"))

        let analyzer = OrphanAppAnalyzer(
            homeDirectory: fakeHome,
            applicationDirectories: [fakeApps],
            includeCLIToolNames: false
        )
        let groups = await analyzer.analyze()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.bundleHint, "com.ghostcorp.deletedwidget")
        XCTAssertEqual(groups.first?.confidence, .high)
    }

    func testDevCacheAnalyzerDetectsNodeModulesRustTargetAndSwiftBuild() async throws {
        let fm = FileManager.default
        let projects = fakeHome.appendingPathComponent("Projects", isDirectory: true)

        // JS project with node_modules
        let jsNM = projects.appendingPathComponent("webapp/node_modules", isDirectory: true)
        try fm.createDirectory(at: jsNM, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 32_768).write(to: jsNM.appendingPathComponent("bundle.js"))

        // Rust project with Cargo.toml + target/
        let rustProj = projects.appendingPathComponent("ferris", isDirectory: true)
        let rustTarget = rustProj.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: rustTarget, withIntermediateDirectories: true)
        try "[package]\nname = \"ferris\"\n".write(
            to: rustProj.appendingPathComponent("Cargo.toml"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 0x22, count: 32_768).write(to: rustTarget.appendingPathComponent("debug.bin"))

        // Non-Rust folder named "target" (no Cargo.toml/pom.xml) -> must NOT be flagged
        let unrelatedTarget = projects.appendingPathComponent("docs/target", isDirectory: true)
        try fm.createDirectory(at: unrelatedTarget, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 32_768).write(to: unrelatedTarget.appendingPathComponent("notes.pdf"))

        // Swift project with Package.swift + .build/
        let swiftProj = projects.appendingPathComponent("swiftcli", isDirectory: true)
        let swiftBuild = swiftProj.appendingPathComponent(".build", isDirectory: true)
        try fm.createDirectory(at: swiftBuild, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: swiftProj.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Data(repeating: 0x44, count: 32_768).write(to: swiftBuild.appendingPathComponent("artifact.o"))

        let analyzer = DevCacheAnalyzer(homeDirectory: fakeHome, customProjectRoots: [projects])
        let items = await analyzer.analyze()

        let paths = Set(items.map(\.id))
        XCTAssertTrue(paths.contains(jsNM.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(rustTarget.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(swiftBuild.standardizedFileURL.path))
        XCTAssertFalse(paths.contains(unrelatedTarget.standardizedFileURL.path))
    }

    func testDumpAndLargeMediaAnalyzers() async throws {
        let fm = FileManager.default
        let diagDir = fakeHome.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let downloads = fakeHome.appendingPathComponent("Downloads", isDirectory: true)
        let movies = fakeHome.appendingPathComponent("Movies", isDirectory: true)
        try fm.createDirectory(at: diagDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: movies, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 8_192).write(to: diagDir.appendingPathComponent("Crash-2026.ips"))
        try Data(repeating: 2, count: 16_384).write(to: downloads.appendingPathComponent("AppInstaller.dmg"))
        try Data(repeating: 3, count: 120_000).write(to: movies.appendingPathComponent("DemoRecording.mov"))
        try Data(repeating: 4, count: 120_000).write(to: movies.appendingPathComponent("BigArchive.zip"))

        let dumpAnalyzer = DumpAndJunkAnalyzer(homeDirectory: fakeHome)
        let dumps = await dumpAnalyzer.analyze()
        XCTAssertTrue(dumps.contains { $0.displayName == "Crash-2026.ips" })
        XCTAssertTrue(dumps.contains { $0.displayName == "AppInstaller.dmg" })

        let mediaAnalyzer = LargeMediaAnalyzer(rootDirectory: fakeHome, homeDirectory: fakeHome)
        let videosOnly = await mediaAnalyzer.analyze(minimumBytes: 64_000, videosOnly: true)
        XCTAssertEqual(videosOnly.map(\.displayName), ["DemoRecording.mov"])
        XCTAssertEqual(videosOnly.first?.confidence, .high)

        let allLarge = await mediaAnalyzer.analyze(minimumBytes: 64_000, videosOnly: false)
        XCTAssertEqual(Set(allLarge.map(\.displayName)), ["DemoRecording.mov", "BigArchive.zip"])

        // Create a large system-style file inside ~/Library to verify it's hidden by default and flagged Danger when shown
        let libAssetDir = fakeHome.appendingPathComponent("Library/Application Support/SomeCore", isDirectory: true)
        try fm.createDirectory(at: libAssetDir, withIntermediateDirectories: true)
        let libVideo = libAssetDir.appendingPathComponent("SystemPreview.mov")
        try Data(repeating: 5, count: 120_000).write(to: libVideo)

        let defaultScan = await mediaAnalyzer.analyze(minimumBytes: 64_000, videosOnly: true, includeSystemFiles: false)
        XCTAssertEqual(defaultScan.map(\.displayName), ["DemoRecording.mov"])

        let withSystemScan = await mediaAnalyzer.analyze(minimumBytes: 64_000, videosOnly: true, includeSystemFiles: true)
        let sysItem = try XCTUnwrap(withSystemScan.first { $0.displayName == "SystemPreview.mov" })
        XCTAssertEqual(sysItem.confidence, .danger)

        // Verify FileSafetyClassifier directly
        let classifier = FileSafetyClassifier(homeDirectory: fakeHome)
        XCTAssertEqual(
            classifier.classify(
                url: URL(fileURLWithPath: "/System/Library/AssetsV2/sample.mov"),
                defaultConfidence: .high,
                defaultRationale: "test"
            ).confidence,
            .danger
        )
    }
}
