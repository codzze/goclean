import Foundation
import GoCleanCore
import XCTest

final class DiskScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoCleanScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testScanCalculatesHierarchyHardlinksAndSkipsSymlinkLoops() async throws {
        let fm = FileManager.default
        let subA = tempDir.appendingPathComponent("Alpha", isDirectory: true)
        let subB = tempDir.appendingPathComponent("Beta", isDirectory: true)
        try fm.createDirectory(at: subA, withIntermediateDirectories: true)
        try fm.createDirectory(at: subB, withIntermediateDirectories: true)

        // Create a 64 KB file in Alpha
        let file1 = subA.appendingPathComponent("video.mp4")
        let data64K = Data(repeating: 0xAB, count: 65_536)
        try data64K.write(to: file1)

        // Create a hard link to file1 in Beta — should only be counted ONCE physically
        let hardlink = subB.appendingPathComponent("video-hardlink.mp4")
        try fm.linkItem(at: file1, to: hardlink)

        // Create a unique 32 KB file in Beta
        let file2 = subB.appendingPathComponent("notes.txt")
        let data32K = Data(repeating: 0xCD, count: 32_768)
        try data32K.write(to: file2)

        // Create a recursive symlink loop pointing back to tempDir — must not loop!
        let symlinkLoop = subA.appendingPathComponent("loop-to-root")
        try fm.createSymbolicLink(at: symlinkLoop, withDestinationURL: tempDir)

        let engine = ConcurrentScanEngine()
        var finalProgress: ScanProgress?
        for try await progress in engine.scan(url: tempDir, maxConcurrency: 4) {
            if progress.isComplete {
                finalProgress = progress
            }
        }

        let root = try XCTUnwrap(finalProgress?.rootNode)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.children.count, 2) // Alpha and Beta (symlink skipped)

        // Physical size should reflect ~96 KB (64 KB + 32 KB), NOT 160 KB (which would mean hardlink double-counted)
        XCTAssertGreaterThanOrEqual(root.physicalSize, 98_304)
        XCTAssertLessThan(root.physicalSize, 140_000)

        // Verify URL reconstruction from compact parent links
        let alphaNode = try XCTUnwrap(root.children.first { $0.name == "Alpha" })
        XCTAssertEqual(alphaNode.url.standardizedFileURL.path, subA.standardizedFileURL.path)

        // Verify live tree pruning updates root physical size cleanly
        let beforeRemove = root.physicalSize
        let removed = root.removeNode(at: file2)
        XCTAssertTrue(removed)
        XCTAssertLessThan(root.physicalSize, beforeRemove)
    }
}
