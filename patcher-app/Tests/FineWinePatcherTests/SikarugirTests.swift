import XCTest
@testable import FineWinePatcher

/// Exercises the Sikarugir support on fake wrapper trees: the wrapper check (engine, renderers in
/// the old and new template layouts, the libraries the engine loads, template, MSync, launch
/// flags), engine file discovery and checksum verification, and installing into an Engines folder.
final class SikarugirTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A fake wrapper laid out like a Sikarugir 1.0.23+ wrapper running the FineWine engine.
    @discardableResult
    private func makeWrapper(named name: String = "Steam Endfield",
                             settings: [String: Any] = [:],
                             renderers: [String] = ["dxmt"],
                             rendererBase: String = "SharedSupport/renderer",
                             libraries: [String] = WrapperCheck.engineLibraries,
                             engineVersion: String? = "WineCX 26.3.0 FineWine (abc1234)") throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents")
        let fm = FileManager.default
        try fm.createDirectory(at: contents.appendingPathComponent("SharedSupport/prefix"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        for r in renderers {
            try fm.createDirectory(at: contents.appendingPathComponent("\(rendererBase)/\(r)/wine"), withIntermediateDirectories: true)
        }
        for lib in libraries {
            fm.createFile(atPath: contents.appendingPathComponent("Frameworks/\(lib)").path, contents: Data())
        }
        if let engineVersion {
            let wine = contents.appendingPathComponent("SharedSupport/wine")
            try fm.createDirectory(at: wine, withIntermediateDirectories: true)
            try (engineVersion + "\n").write(to: wine.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        }
        var plist: [String: Any] = [
            "CFBundleVersion": "1.0.24",
            "WINEMSYNC": 1,
            "D3DMETAL": 0, "DXVK": 0, "D9VK": 0,
            "Program Name and Path": "/Program Files (x86)/Steam/steam.exe",
            "Program Flags": "-silent -applaunch 4732690 -force-d3d11",
        ]
        plist.merge(settings) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func check(_ app: URL, creatorTemplate: String? = "1.0.24") throws -> [String: WrapperCheckItem] {
        let wrapper = try XCTUnwrap(WrapperInfo(url: app))
        return Dictionary(uniqueKeysWithValues: WrapperCheck.run(wrapper, creatorTemplate: creatorTemplate).map { ($0.id, $0) })
    }

    // MARK: - Wrapper check

    func testHealthyWrapperPassesEveryCheck() throws {
        let items = try check(makeWrapper())
        XCTAssertEqual(Set(items.keys), ["engine", "renderers", "libraries", "template", "msync", "launch"])
        for item in items.values {
            XCTAssertEqual(item.status, .ok, "\(item.id): \(item.detail)")
        }
    }

    func testRenderersInThePreTemplate1023LocationAreFound() throws {
        let items = try check(makeWrapper(rendererBase: "Frameworks/renderer"))
        XCTAssertEqual(items["renderers"]?.status, .ok)
    }

    func testMissingRendererAfterTemplateUpdateSuggestsUpdatingAgain() throws {
        // What a single Update Wrapper from template 1.0.22 or older leaves behind.
        let items = try check(makeWrapper(renderers: []))
        XCTAssertEqual(items["renderers"]?.status, .problem)
        XCTAssertTrue(items["renderers"]?.detail.contains("DXMT") == true)
        XCTAssertTrue(items["renderers"]?.fix?.contains("Update Wrapper") == true)
    }

    func testSelectedRenderersFollowTheWrapperSettings() throws {
        XCTAssertEqual(try XCTUnwrap(WrapperInfo(url: makeWrapper(named: "a"))).selectedRenderers, ["dxmt"])
        XCTAssertEqual(try XCTUnwrap(WrapperInfo(url: makeWrapper(named: "b", settings: ["D3DMETAL": 1]))).selectedRenderers, ["d3dmetal"])
        XCTAssertEqual(try XCTUnwrap(WrapperInfo(url: makeWrapper(named: "c", settings: ["DXVK": 1, "D9VK": 1]))).selectedRenderers, ["dxvk", "d9vk"])
        // D9VK selected but not present is a problem too.
        let items = try check(makeWrapper(named: "d", settings: ["D9VK": 1], renderers: ["dxmt"]))
        XCTAssertEqual(items["renderers"]?.status, .problem)
        XCTAssertTrue(items["renderers"]?.detail.contains("D9VK") == true)
    }

    func testMissingEngineLibraryIsAProblem() throws {
        let items = try check(makeWrapper(libraries: WrapperCheck.engineLibraries.filter { $0 != "libgnutls.30.dylib" }))
        XCTAssertEqual(items["libraries"]?.status, .problem)
        XCTAssertTrue(items["libraries"]?.detail.contains("libgnutls.30.dylib") == true)
    }

    func testOtherEngineIsAProblem() throws {
        let items = try check(makeWrapper(engineVersion: "Wine 11.0 Sikarugir"))
        XCTAssertEqual(items["engine"]?.status, .problem)
        XCTAssertTrue(items["engine"]?.fix?.contains("Change Engine") == true)
        XCTAssertEqual(try check(makeWrapper(named: "none", engineVersion: nil))["engine"]?.status, .problem)
    }

    func testOlderTemplateThanCreatorsIsAWarning() throws {
        let app = try makeWrapper(settings: ["CFBundleVersion": "1.0.21"])
        XCTAssertEqual(try check(app, creatorTemplate: "1.0.24")["template"]?.status, .warning)
        XCTAssertEqual(try check(app, creatorTemplate: "1.0.21")["template"]?.status, .ok)
        XCTAssertEqual(try check(app, creatorTemplate: nil)["template"]?.status, .ok)
    }

    func testMSyncOffIsAWarning() throws {
        XCTAssertEqual(try check(makeWrapper(settings: ["WINEMSYNC": 0]))["msync"]?.status, .warning)
    }

    func testLaunchFlags() throws {
        // Steam without the flags opens Steam but not the game (and the game would run on Vulkan).
        let plainSteam = try check(makeWrapper(named: "s", settings: ["Program Flags": ""]))
        XCTAssertEqual(plainSteam["launch"]?.status, .warning)
        XCTAssertTrue(plainSteam["launch"]?.fix?.contains("-force-d3d11") == true)
        // The Steam version can't be started as Endfield.exe.
        let direct = try check(makeWrapper(named: "e", settings: [
            "Program Name and Path": "/Program Files (x86)/Steam/steamapps/common/Arknights Endfield/Endfield.exe",
            "Program Flags": "-force-d3d11"]))
        XCTAssertEqual(direct["launch"]?.status, .warning)
        // The Gryphline launcher needs D9VK off.
        let launcher = ["Program Name and Path": "/Program Files/Gryphline/Launcher.exe", "Program Flags": ""]
        XCTAssertEqual(try check(makeWrapper(named: "l1", settings: launcher.merging(["D9VK": "1"]) { $1 }, renderers: ["dxmt", "d9vk"]))["launch"]?.status, .warning)
        XCTAssertEqual(try check(makeWrapper(named: "l2", settings: launcher))["launch"]?.status, .ok)
    }

    func testNonWrapperIsRejected() throws {
        let folder = root.appendingPathComponent("Not A Wrapper.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(WrapperInfo(url: folder.deletingLastPathComponent()))
    }

    func testDetectAllListsOnlyWrappers() throws {
        try makeWrapper(named: "B wrapper")
        try makeWrapper(named: "A wrapper")
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data())
        XCTAssertEqual(WrapperInfo.detectAll(in: root).map(\.name), ["A wrapper", "B wrapper"])
    }

    // MARK: - Templates

    func testCreatorTemplateVersionPicksTheNewest() throws {
        let dir = root.appendingPathComponent("Template", isDirectory: true)
        for v in ["1.0.9", "1.0.24", "1.0.10"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Template-\(v).app"), withIntermediateDirectories: true)
        }
        XCTAssertEqual(Sikarugir.creatorTemplateVersion(in: dir), "1.0.24")
        XCTAssertNil(Sikarugir.creatorTemplateVersion(in: root.appendingPathComponent("missing")))
    }

    func testCompareVersionsIsNumeric() {
        XCTAssertEqual(Sikarugir.compareVersions("1.0.9", "1.0.24"), .orderedAscending)
        XCTAssertEqual(Sikarugir.compareVersions("1.0.24", "1.0.24"), .orderedSame)
        XCTAssertEqual(Sikarugir.compareVersions("1.1", "1.0.24"), .orderedDescending)
    }

    // MARK: - Engine file

    private func makeEngine(_ name: String = "WS12WineFineWine26.3.0_1.tar.xz", contents: String = "abc") throws -> EngineFile {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return EngineFile(url: url)
    }

    // SHA-256 of "abc" (FIPS 180-2 test vector).
    private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testSHA256OfFile() throws {
        XCTAssertEqual(try EngineFile.sha256(of: makeEngine().url), abcSHA256)
    }

    func testVerifyAcceptsOnlyTheExpectedEngine() throws {
        let engine = try makeEngine()
        XCTAssertNoThrow(try engine.verify(against: ExpectedEngine(name: "WS12WineFineWine26.3.0_1", sha256: abcSHA256)))
        XCTAssertNoThrow(try engine.verify(against: ExpectedEngine(name: nil, sha256: abcSHA256)))
        XCTAssertThrowsError(try engine.verify(against: ExpectedEngine(name: "WS12WineFineWine26.3.0_1", sha256: String(repeating: "0", count: 64))))
        XCTAssertThrowsError(try engine.verify(against: ExpectedEngine(name: "WS12WineFineWine26.3.0_2", sha256: abcSHA256)))
    }

    func testFindListsOnlyEngineArchives() throws {
        _ = try makeEngine()
        _ = try makeEngine("WS12WineSikarugir11.0_1.tar.xz")
        _ = try makeEngine("WS12WineFineWine26.3.0_1.tar.xz.sha256")
        XCTAssertEqual(EngineFile.find(in: root).map(\.engineName), ["WS12WineFineWine26.3.0_1"])
    }

    func testExpectedEngineRejectsMalformedChecksums() {
        XCTAssertTrue(ExpectedEngine.isSHA256(abcSHA256))
        XCTAssertFalse(ExpectedEngine.isSHA256("abc"))
        XCTAssertFalse(ExpectedEngine.isSHA256(String(repeating: "g", count: 64)))
    }

    // MARK: - Install

    func testInstallCopiesAndAsksBeforeReplacing() throws {
        let engines = root.appendingPathComponent("Engines", isDirectory: true)
        let engine = try makeEngine()
        let dest = try EngineInstaller.install(engine, enginesDir: engines, replace: false)
        XCTAssertEqual(try EngineFile.sha256(of: dest), abcSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.url.path), "the downloaded file stays where it was")

        XCTAssertThrowsError(try EngineInstaller.install(engine, enginesDir: engines, replace: false))

        try "new".write(to: engine.url, atomically: true, encoding: .utf8)
        try EngineInstaller.install(engine, enginesDir: engines, replace: true)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: engines.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [])
    }
}
