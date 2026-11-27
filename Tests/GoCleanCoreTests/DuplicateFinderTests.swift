import Foundation
import GoCleanCore
import XCTest

final class DuplicateFinderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoCleanDupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testThreeStageDuplicateDetectionIgnoresMidFileDifferencesAndHardlinks() async throws {
        let fm = FileManager.default

        // Build 32 KB base payload
        let payloadA = Data(repeating: 0xAA, count: 32_768)
        let orig = tempDir.appendingPathComponent("photo.jpg")
        let dup1 = tempDir.appendingPathComponent("copy/photo-copy.jpg")
        let hardlink = tempDir.appendingPathComponent("photo-hardlink.jpg")
        try fm.createDirectory(at: dup1.deletingLastPathComponent(), withIntermediateDirectories: true)

        try payloadA.write(to: orig)
        try payloadA.write(to: dup1)
        try fm.linkItem(at: orig, to: hardlink)

        // Same size AND identical first 8KB + last 8KB, but different byte in the middle (byte 16384)!
        // Stage 2 partial hash collides, Stage 3 full SHA-256 MUST separate it!
        var payloadMidDiff = payloadA
        payloadMidDiff[16_384] = 0xFF
        let sneakyNonDup = tempDir.appendingPathComponent("photo-edited.jpg")
        try payloadMidDiff.write(to: sneakyNonDup)

        let finder = DuplicateFinder()
        let groups = try await finder.findDuplicates(in: tempDir, minimumBytes: 1_024)

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        // Only 2 files: orig + dup1 (hardlink excluded, sneakyNonDup excluded)
        XCTAssertEqual(group.files.count, 2)
        XCTAssertEqual(group.wastedSize, 32_768)

        // Smart Select MUST always keep 1 file and select exactly N-1 files
        for strategy in DuplicateSelectionStrategy.allCases {
            let selected = DuplicateFinder.selectDuplicates(in: groups, strategy: strategy)
            XCTAssertEqual(selected.count, 1)
        }

        // Verify keepShortestPath keeps `photo.jpg` and removes `copy/photo-copy.jpg`
        let shortestSelection = DuplicateFinder.selectDuplicates(in: groups, strategy: .keepShortestPath)
        XCTAssertEqual(shortestSelection.first?.url.lastPathComponent, "photo-copy.jpg")
    }
}
