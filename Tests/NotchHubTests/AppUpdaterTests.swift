import XCTest
import Foundation
import AppKit
import CryptoKit
import zlib
@testable import NotchHub

final class AppUpdaterTests: XCTestCase {
    private let config = AppUpdater.Configuration(repository: "DmitryBarmin/NotchHub", appName: "Fixture", bundleIdentifier: "local.test.updater-fixture", relaunchArguments: [])
    func testVersionOrderingRejectsNonStableAndEqualOrOlderRelease() throws {
        XCTAssertLessThan(try AppUpdateVersion("v1.9.9"), try AppUpdateVersion("1.10.0"))
        XCTAssertEqual(try AppUpdateVersion("1.3"), try AppUpdateVersion("1.3.0"))
        for invalid in ["1.2-beta", "1", "1.2.3.4", "1.-2", "1..2"] { XCTAssertThrowsError(try AppUpdateVersion(invalid)) }
        let release = metadata(version: "1.4.0", bytes: Data([1, 2]))
        XCTAssertEqual(try AppUpdateCore.selectedAsset(release, appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: "1.3.8").0, "1.4.0")
        for installed in ["1.4.0", "1.5.0"] { XCTAssertThrowsError(try AppUpdateCore.selectedAsset(release, appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: installed)) }
        XCTAssertThrowsError(try AppUpdateCore.selectedAsset(Data("{}".utf8), appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: "1.0"))
    }
    func testDigestSizeAndAssetOriginFailClosed() throws {
        let bytes = Data("zip bytes".utf8)
        let (_, asset) = try AppUpdateCore.selectedAsset(metadata(version: "2.0", bytes: bytes), appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: "1.0")
        XCTAssertNoThrow(try AppUpdateCore.verifyDownload(bytes, asset: asset))
        XCTAssertThrowsError(try AppUpdateCore.verifyDownload(Data("bad".utf8), asset: asset))
        for replacement in ["https://evil.test/NotchHub-2.0-macOS-arm64.zip", "https://github.com/Other/NotchHub/releases/download/v2.0/NotchHub-2.0-macOS-arm64.zip"] {
            let data = metadata(version: "2.0", bytes: bytes, url: replacement)
            XCTAssertThrowsError(try AppUpdateCore.selectedAsset(data, appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: "1.0"))
        }
        XCTAssertThrowsError(try AppUpdateCore.selectedAsset(metadata(version: "2.0", bytes: bytes, digest: ""), appName: "NotchHub", repository: "DmitryBarmin/NotchHub", installed: "1.0"))
    }
    func testZIPRejectsTraversalLinksDuplicatesAndAdvertisedBomb() throws {
        for name in ["../outside", "/NotchHub.app/file", "NotchHub.app/../outside", "NotchHub.app\\file", "NotchHub.app/Contents/./file", "Other.app/file"] {
            XCTAssertThrowsError(try AppUpdateCore.zipEntries(zip([(name, Data([1]), 0o100644)]), appName: "NotchHub"), name)
        }
        XCTAssertThrowsError(try AppUpdateCore.zipEntries(zip([("NotchHub.app/link", Data("/tmp".utf8), 0o120777)]), appName: "NotchHub"))
        XCTAssertThrowsError(try AppUpdateCore.zipEntries(zip([("NotchHub.app/File", Data(), 0o100644), ("NotchHub.app/file", Data(), 0o100644)]), appName: "NotchHub"))
        XCTAssertThrowsError(try AppUpdateCore.zipEntries(zip([("NotchHub.app/file", Data(), 0o100644)], advertised: AppUpdateCore.expandedLimit + 1), appName: "NotchHub"))
    }
    func testZIPExtractionChecksActualBytesCRCAndPreservesExecutable() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = zip([("NotchHub.app/Contents/MacOS/NotchHub", Data("fixture".utf8), 0o100755)])
        let app = try AppUpdateCore.extract(archive, appName: "NotchHub", to: root.appendingPathComponent("good"))
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Contents/MacOS/NotchHub")), "fixture")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/NotchHub").path))
        let badSize = zip([("NotchHub.app/file", Data("larger than declared".utf8), 0o100644)], advertised: 1)
        XCTAssertThrowsError(try AppUpdateCore.extract(badSize, appName: "NotchHub", to: root.appendingPathComponent("bad")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
        var badCRC = archive; badCRC[30 + "NotchHub.app/Contents/MacOS/NotchHub".utf8.count] ^= 1
        XCTAssertThrowsError(try AppUpdateCore.extract(badCRC, appName: "NotchHub", to: root.appendingPathComponent("crc")))
    }
    func testSignedBundleIdentityCompatibilityAndAtomicRollback() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try fixture(at: root.appendingPathComponent("current.app"), version: "1.0")
        let staged = try fixture(at: root.appendingPathComponent("new.app"), version: "2.0")
        try AppUpdateCore.validateBundle(staged, configuration: config, version: "2.0", installed: current)
        XCTAssertThrowsError(try AppUpdateCore.validateBundle(staged, configuration: config, version: "3.0", installed: current))
        let wrong = AppUpdater.Configuration(repository: config.repository, appName: config.appName, bundleIdentifier: "wrong.identifier", relaunchArguments: [])
        XCTAssertThrowsError(try AppUpdateCore.validateBundle(staged, configuration: wrong, version: "2.0", installed: current))
        XCTAssertThrowsError(try AppUpdateCore.install(current: current, staged: staged) { app in
            XCTAssertEqual(try AppUpdateCore.bundleVersion(app, identifier: config.bundleIdentifier), "2.0")
            throw AppUpdateFailure("injected launch failure")
        })
        XCTAssertEqual(try AppUpdateCore.bundleVersion(current, identifier: config.bundleIdentifier), "1.0")
        XCTAssertEqual(try AppUpdateCore.bundleVersion(staged, identifier: config.bundleIdentifier), "2.0")
        try AppUpdateCore.install(current: current, staged: staged) { app in
            XCTAssertEqual(try AppUpdateCore.bundleVersion(app, identifier: config.bundleIdentifier), "2.0")
        }
        XCTAssertEqual(try AppUpdateCore.bundleVersion(current, identifier: config.bundleIdentifier), "2.0")
        XCTAssertEqual(try AppUpdateCore.bundleVersion(staged, identifier: config.bundleIdentifier), "1.0")
        try FileManager.default.removeItem(at: staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testUnsafeRollbackRetainsOldSignedBundleForRecovery() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try fixture(at: root.appendingPathComponent("current.app"), version: "1.0")
        let staged = try fixture(at: root.appendingPathComponent("new.app"), version: "2.0")
        XCTAssertThrowsError(try AppUpdateCore.install(current: current, staged: staged, canRollback: { false }) { _ in throw AppUpdateFailure("running new process") })
        XCTAssertEqual(try AppUpdateCore.bundleVersion(staged, identifier: config.bundleIdentifier), "1.0")
    }
    @MainActor func testNativeHiddenFixtureLaunchAndCrashReadinessUsesRunLoop() throws {
        _ = NSApplication.shared
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let normal = try fixture(at: root.appendingPathComponent("normal.app"), version: "1.0", lifecycle: "normal")
        defer {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: config.bundleIdentifier)
            apps.forEach { _ = $0.terminate() }
            let limit = Date().addingTimeInterval(3)
            while apps.contains(where: { !$0.isTerminated }) && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        try AppUpdateCore.launchAndWait(normal, identifier: config.bundleIdentifier, arguments: [], timeout: 5, stability: 0.4)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: config.bundleIdentifier)
        XCTAssertTrue(running.contains { $0.isFinishedLaunching && !$0.isTerminated })
        running.forEach { _ = $0.terminate() }
        let limit = Date().addingTimeInterval(3)
        while running.contains(where: { !$0.isTerminated }) && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(running.contains { !$0.isTerminated })
        let crashing = try fixture(at: root.appendingPathComponent("crashing.app"), version: "2.0", lifecycle: "crash")
        XCTAssertThrowsError(try AppUpdateCore.launchAndWait(crashing, identifier: config.bundleIdentifier, arguments: [], timeout: 2, stability: 0.5))
    }
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("updater-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func fixture(at app: URL, version: String, lifecycle: String? = nil) throws -> URL {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let source = app.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + (lifecycle == nil ? ".c" : ".m"))
        let code: String
        if let lifecycle {
            code = """
            #import <AppKit/AppKit.h>
            @interface FixtureDelegate : NSObject<NSApplicationDelegate> @end
            @implementation FixtureDelegate
            - (void)applicationDidFinishLaunching:(NSNotification *)note {
                \(lifecycle == "crash" ? "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150000000), dispatch_get_main_queue(), ^{ exit(9); });" : "")
            }
            @end
            int main(void) { @autoreleasepool {
                NSApplication *app = [NSApplication sharedApplication];
                [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
                FixtureDelegate *delegate = [FixtureDelegate new]; app.delegate = delegate;
                [app run]; return 0;
            } }
            """
        } else { code = "int main(void) { return 0; }" }
        try code.write(to: source, atomically: true, encoding: .utf8)
        var arguments = ["clang", "-target", "arm64-apple-macos14.0", "-isysroot", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk", source.path, "-o", contents.appendingPathComponent("MacOS/Fixture").path]
        if lifecycle != nil { arguments += ["-fobjc-arc", "-framework", "AppKit"] }
        try AppUpdateCore.command("/usr/bin/xcrun", arguments)
        let info: [String: Any] = ["LSUIElement": true, "CFBundleVersion": version, "CFBundleIdentifier": config.bundleIdentifier, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try AppUpdateCore.command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", config.bundleIdentifier, app.path])
        return app
    }
    private func metadata(version: String, bytes: Data, url: String? = nil, digest: String? = nil) -> Data {
        let name = "NotchHub-\(version)-macOS-arm64.zip"
        return try! JSONSerialization.data(withJSONObject: ["tag_name": "v" + version, "draft": false, "prerelease": false, "assets": [["name": name, "size": bytes.count, "digest": digest ?? "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "browser_download_url": url ?? "https://github.com/DmitryBarmin/NotchHub/releases/download/v\(version)/\(name)"]]])
    }
    private func zip(_ files: [(String, Data, UInt32)], advertised: Int? = nil) -> Data {
        var data = Data(), central = Data()
        func put16(_ value: UInt16, _ output: inout Data) { output.append(UInt8(value & 255)); output.append(UInt8(value >> 8)) }
        func put32(_ value: UInt32, _ output: inout Data) { put16(UInt16(value & 65535), &output); put16(UInt16(value >> 16), &output) }
        for (name, bytes, mode) in files {
            let nameData = Data(name.utf8), offset = data.count
            let crc = bytes.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count))) }
            put32(0x04034b50, &data); put16(20, &data); put16(0, &data); put16(0, &data); put32(0, &data); put32(crc, &data)
            put32(UInt32(bytes.count), &data); put32(UInt32(advertised ?? bytes.count), &data); put16(UInt16(nameData.count), &data); put16(0, &data); data.append(nameData); data.append(bytes)
            put32(0x02014b50, &central); put16(0x0314, &central); put16(20, &central); put16(0, &central); put16(0, &central); put32(0, &central); put32(crc, &central)
            put32(UInt32(bytes.count), &central); put32(UInt32(advertised ?? bytes.count), &central); put16(UInt16(nameData.count), &central)
            put16(0, &central); put16(0, &central); put16(0, &central); put16(0, &central); put32(mode << 16, &central); put32(UInt32(offset), &central); central.append(nameData)
        }
        let start = data.count; data.append(central); put32(0x06054b50, &data); put16(0, &data); put16(0, &data); put16(UInt16(files.count), &data); put16(UInt16(files.count), &data); put32(UInt32(central.count), &data); put32(UInt32(start), &data); put16(0, &data)
        return data
    }
}
