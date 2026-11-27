import Foundation
import GoCleanCore
import XCTest

final class SafetyGuardTests: XCTestCase {
    private var fakeHome: URL!

    override func setUpWithError() throws {
        fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoCleanSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fakeHome {
            try? FileManager.default.removeItem(at: fakeHome)
        }
    }

    func testBlocksCriticalSystemAndTopLevelUserPaths() {
        let guardEngine = SafetyGuard(homeDirectory: fakeHome)

        let blockedPaths = [
            "/",
            "/System",
            "/System/Library/CoreServices",
            "/usr/bin/ls",
            "/bin",
            "/Applications",
            fakeHome.path,
            fakeHome.appendingPathComponent("Library").path,
            fakeHome.appendingPathComponent("Library/Application Support").path,
            fakeHome.appendingPathComponent("Documents").path,
            fakeHome.appendingPathComponent(".ssh/id_ed25519").path
        ]

        for path in blockedPaths {
            let result = guardEngine.validate(url: URL(fileURLWithPath: path))
            XCTAssertFalse(result.isAllowed, "Expected path to be blocked: \(path)")
        }
    }

    func testAllowsSpecificInnerCacheAndTempPaths() {
        let guardEngine = SafetyGuard(homeDirectory: fakeHome)

        let allowedPaths = [
            fakeHome.appendingPathComponent("Library/Caches/com.example.oldapp"),
            fakeHome.appendingPathComponent("Library/Application Support/OldDeletedApp"),
            fakeHome.appendingPathComponent("Projects/demo/node_modules"),
            fakeHome.appendingPathComponent("Downloads/OldInstaller.dmg")
        ]

        for url in allowedPaths {
            let result = guardEngine.validate(url: url)
            XCTAssertTrue(result.isAllowed, "Expected path to be allowed: \(url.path)")
        }
    }

    func testBlocksSymlinkEscapingToSystemPath() throws {
        let guardEngine = SafetyGuard(homeDirectory: fakeHome)
        let escapeLink = fakeHome.appendingPathComponent("sneaky-link")
        try FileManager.default.createSymbolicLink(
            at: escapeLink,
            withDestinationURL: URL(fileURLWithPath: "/System")
        )

        let result = guardEngine.validate(url: escapeLink)
        XCTAssertFalse(result.isAllowed, "Symlink pointing to /System must be blocked")
    }

    func testPermanentEraseDeletesSafeFixtureAndSkipsProtectedPath() async throws {
        let guardEngine = SafetyGuard(homeDirectory: fakeHome)
        let executor = CleanupExecutor(safetyGuard: guardEngine)

        let safeFile = fakeHome.appendingPathComponent("disposable.tmp")
        try Data(repeating: 0x42, count: 4_096).write(to: safeFile)

        let safeItem = CleanupItem(url: safeFile, size: 4_096, bucket: .dumpAndJunk)
        let blockedItem = CleanupItem(url: URL(fileURLWithPath: "/System"), size: 100, bucket: .diskMap)

        let result = await executor.execute(items: [safeItem, blockedItem], mode: .permanentErase)

        XCTAssertEqual(result.succeededURLs.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.freedBytes, 4_096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: safeFile.path))
    }
}
