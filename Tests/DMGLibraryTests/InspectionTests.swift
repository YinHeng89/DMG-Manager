import XCTest
@testable import DMGLibrary

/// 端到端验证 DMG 解析：真实挂载、真实读 plist 与 Mach-O。
final class InspectionTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DMGLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("DMGLIBRARY_ROOT", sandbox.appendingPathComponent("Data").path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        unsetenv("DMGLIBRARY_ROOT")
    }

    func testParseRealDMG() throws {
        let bundle = try TestDMGFactory.makeDMG(in: sandbox, name: "Test_1.2.3.dmg")

        let result = DMGInspectionService.inspect(fileURL: bundle.dmgURL)

        XCTAssertEqual(result.status, .parsed)
        XCTAssertEqual(result.appInfo?.name, "TestApp")
        XCTAssertEqual(result.appInfo?.version, "1.2.3")
        XCTAssertEqual(result.appInfo?.build, "456")
        XCTAssertEqual(result.appInfo?.bundleID, "com.example.testapp")
        XCTAssertEqual(result.appInfo?.minimumOS, "12.0")
        XCTAssertEqual(result.appInfo?.relativePath, "TestApp.app")
        XCTAssertNotNil(result.iconFilename, "应提取出 App 图标")

        let iconURL = IconStore.shared.url(named: result.iconFilename)
        XCTAssertNotNil(iconURL)
        XCTAssertGreaterThan(try Data(contentsOf: iconURL!).count, 100)
    }

    func testParseDMGWithoutApp() throws {
        // 只放一个 txt，镜像里没有 .app
        let root = sandbox.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let dmgURL = sandbox.appendingPathComponent("plain.dmg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-srcfolder", root.path, "-format", "UDZO", "-quiet", "-ov", dmgURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let result = DMGInspectionService.inspect(fileURL: dmgURL)
        XCTAssertEqual(result.status, .noApp)
    }

    func testParseMissingFile() {
        let result = DMGInspectionService.inspect(
            fileURL: sandbox.appendingPathComponent("no-such-file.dmg")
        )
        XCTAssertEqual(result.status, .missing)
    }

    func testArchitectureDetection() {
        // 当前系统上的 /usr/bin/true 一定是本机原生架构
        let arch = ArchitectureDetector.architecture(at: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertNotEqual(arch, .unknown)

        // /usr/bin/true 在 Apple Silicon 上通常是通用二进制
        let types = ArchitectureDetector.cpuTypes(at: URL(fileURLWithPath: "/usr/bin/true"))
        XCTAssertFalse(types.isEmpty)
        XCTAssertTrue(types.contains(CPU_TYPE_ARM64) || types.contains(CPU_TYPE_X86_64))
    }

    func testArchitectureFromRawHeader() throws {
        // 手工构造一个 fat 头：arm64 + x86_64
        var data = Data()
        func append(_ value: UInt32) {
            var big = value.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &big) { Array($0) })
        }
        append(0xCAFE_BABE)      // FAT_MAGIC
        append(2)                // nfat_arch
        append(CPU_TYPE_ARM64)   // arch 0
        append(0)
        append(0)
        append(0)
        append(0)
        append(CPU_TYPE_X86_64)  // arch 1
        append(0)
        append(0)
        append(0)
        append(0)

        let url = sandbox.appendingPathComponent("fat-binary")
        try data.write(to: url)
        XCTAssertEqual(ArchitectureDetector.architecture(at: url), .universal)
    }
}
