import Foundation
import GoCleanCore
import XCTest

final class ApplicationDiscoveryTests: XCTestCase {
    private var tempRoot: URL!
    private var fakeHome: URL!
    private var fakeApps: URL!
    private var fakeBin: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoCleanAppDisc-\(UUID().uuidString)", isDirectory: true)
        fakeHome = tempRoot.appendingPathComponent("Home", isDirectory: true)
        fakeApps = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        fakeBin = fakeHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testParsesHomebrewJSONWithReverseDependenciesAndCaskArtifacts() throws {
        let sampleJSON = """
        {
          "formulae": [
            {
              "name": "openssl@3",
              "desc": "Cryptography and SSL/TLS Toolkit",
              "dependencies": [],
              "installed": [
                {
                  "version": "3.4.0",
                  "installed_on_request": false,
                  "installed_as_dependency": true
                }
              ]
            },
            {
              "name": "curl",
              "desc": "Get a file from an HTTP, HTTPS or FTP server",
              "dependencies": ["openssl@3"],
              "installed": [
                {
                  "version": "8.11.0",
                  "installed_on_request": true,
                  "installed_as_dependency": false
                }
              ]
            }
          ],
          "casks": [
            {
              "token": "visual-studio-code",
              "name": ["Microsoft Visual Studio Code"],
              "desc": "Open-source code editor",
              "installed": "1.96.0",
              "artifacts": [
                { "app": ["Visual Studio Code.app"] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = ApplicationDiscoveryEngine.parseHomebrewJSON(
            sampleJSON,
            cellarPrefix: tempRoot.appendingPathComponent("Cellar"),
            caskroomPrefix: tempRoot.appendingPathComponent("Caskroom")
        )

        XCTAssertEqual(parsed.formulae.count, 2)
        let openssl = try XCTUnwrap(parsed.formulae.first { $0.name == "openssl@3" })
        XCTAssertTrue(openssl.isDependencyOnly)
        XCTAssertEqual(openssl.reverseDependencies, ["curl"])

        let curl = try XCTUnwrap(parsed.formulae.first { $0.name == "curl" })
        XCTAssertFalse(curl.isDependencyOnly)
        XCTAssertEqual(curl.reverseDependencies, [])

        XCTAssertEqual(parsed.casks.count, 1)
        XCTAssertNotNil(parsed.caskAppBundleNames["visual studio code.app"])
    }

    func testDiscoversAppStoreDirectAndCurlCLITools() async throws {
        let fm = FileManager.default

        // 1. App Store app (_MASReceipt/receipt)
        let masApp = fakeApps.appendingPathComponent("StoreNotes.app/Contents", isDirectory: true)
        try fm.createDirectory(at: masApp.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: masApp.appendingPathComponent("_MASReceipt/receipt"))
        (["CFBundleIdentifier": "com.store.notes", "CFBundleName": "StoreNotes", "CFBundleShortVersionString": "2.1"] as NSDictionary)
            .write(to: masApp.appendingPathComponent("Info.plist"), atomically: true)

        // Associated Library data for StoreNotes
        let masSupport = fakeHome.appendingPathComponent("Library/Application Support/com.store.notes", isDirectory: true)
        try fm.createDirectory(at: masSupport, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 16_384).write(to: masSupport.appendingPathComponent("notes.db"))

        // 2. Direct DMG app
        let directApp = fakeApps.appendingPathComponent("MyTool.app/Contents", isDirectory: true)
        try fm.createDirectory(at: directApp, withIntermediateDirectories: true)
        (["CFBundleIdentifier": "io.indie.mytool", "CFBundleName": "MyTool", "CFBundleShortVersionString": "1.0"] as NSDictionary)
            .write(to: directApp.appendingPathComponent("Info.plist"), atomically: true)

        // 3. Direct curl standalone CLI binary in ~/.local/bin + config dir
        let cliBin = fakeBin.appendingPathComponent("mycurlcli")
        try "#!/bin/sh\necho hello\n".write(to: cliBin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliBin.path)
        let cliCfg = fakeHome.appendingPathComponent(".config/mycurlcli", isDirectory: true)
        try fm.createDirectory(at: cliCfg, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cliCfg.appendingPathComponent("config.toml"))

        let engine = ApplicationDiscoveryEngine(
            homeDirectory: fakeHome,
            applicationDirectories: [fakeApps],
            brewExecutablePath: nil,
            cliBinaryDirectories: [fakeBin]
        )
        let apps = await engine.discoverAll()

        let store = try XCTUnwrap(apps.first { $0.name == "StoreNotes" })
        XCTAssertEqual(store.source, .appStore)
        XCTAssertEqual(store.associatedFiles.count, 1)

        let direct = try XCTUnwrap(apps.first { $0.name == "MyTool" })
        XCTAssertEqual(direct.source, .directDownload)

        let cli = try XCTUnwrap(apps.first { $0.name == "mycurlcli" })
        XCTAssertEqual(cli.source, .curlCLI)
        XCTAssertEqual(cli.associatedFiles.count, 1)
    }
}
