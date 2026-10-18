import Foundation
import CryptoKit

/// Sikarugir support (experimental, community-maintained; see docs/sikarugir.md).
///
/// Sikarugir runs each Windows app in its own wrapper `.app` on a Wine *engine*. This project
/// builds CrossOver 26.3 Wine with the FineWine patches as such an engine
/// (`WS12WineFineWine<version>_<n>.tar.xz`, attached to releases). Here the app only installs that
/// file into Sikarugir's Engines folder and *checks* wrappers: wrappers belong to Sikarugir, which
/// changes them through Creator (new templates) and each wrapper's Configure (Update Wrapper,
/// Change Engine). Nothing in this file writes inside a wrapper.
///
/// Kept apart from the CrossOver patch flow (PatcherEngine / ModChain) on purpose.
enum Sikarugir {
    static let creatorApp = URL(fileURLWithPath: "/Applications/Sikarugir Creator.app")

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sikarugir", isDirectory: true)
    }
    static var enginesDir: URL { supportDir.appendingPathComponent("Engines", isDirectory: true) }
    static var templateDir: URL { supportDir.appendingPathComponent("Template", isDirectory: true) }

    /// Where Creator puts the wrappers it makes.
    static var wrappersDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Sikarugir", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: creatorApp.path)
            || FileManager.default.fileExists(atPath: enginesDir.path)
    }

    /// The template Creator has downloaded (it keeps one, `Template-<version>.app`); new wrappers
    /// are made from it and Update Wrapper copies from it.
    static func creatorTemplateVersion(in dir: URL = templateDir) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasPrefix("Template-"), name.hasSuffix(".app") else { return nil }
            return String(name.dropFirst("Template-".count).dropLast(".app".count))
        }.max(by: { compareVersions($0, $1) == .orderedAscending })
    }

    /// Compares dotted version strings numerically ("1.0.9" < "1.0.24").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - The engine file

/// The engine this build of the app accepts: name and SHA-256 are baked into Info.plist by
/// scripts/build-app.sh from the release's engine. FINEWINE_SIKARUGIR_ENGINE_SHA256 (and
/// optionally FINEWINE_SIKARUGIR_ENGINE_NAME) override them for development (`swift run`).
struct ExpectedEngine: Equatable {
    static let namePrefix = "WS12WineFineWine"
    let name: String?      // e.g. "WS12WineFineWine26.3.0_1"; nil accepts any FineWine engine name
    let sha256: String

    static var current: ExpectedEngine? {
        let env = ProcessInfo.processInfo.environment
        if let sum = env["FINEWINE_SIKARUGIR_ENGINE_SHA256"], isSHA256(sum) {
            return ExpectedEngine(name: env["FINEWINE_SIKARUGIR_ENGINE_NAME"], sha256: sum.lowercased())
        }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let sum = info["FineWineSikarugirEngineSHA256"] as? String, isSHA256(sum) else { return nil }
        return ExpectedEngine(name: info["FineWineSikarugirEngineName"] as? String, sha256: sum.lowercased())
    }

    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }
}

/// A FineWine engine archive the user downloaded (or picked).
struct EngineFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    /// The engine's name as Sikarugir lists it: the file name without `.tar.xz`.
    var engineName: String { String(url.lastPathComponent.dropLast(".tar.xz".count)) }

    static func isEngineFileName(_ name: String) -> Bool {
        name.hasPrefix(ExpectedEngine.namePrefix) && name.hasSuffix(".tar.xz")
    }

    /// FineWine engine archives in `dir` (not recursive), newest first.
    static func find(in dir: URL) -> [EngineFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter(isEngineFileName).map { EngineFile(url: dir.appendingPathComponent($0)) }
            .sorted { modified($0.url) > modified($1.url) }
    }

    static var downloadsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// SHA-256 of the file, read in chunks (the engine is ~200 MB).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws unless the file is the engine this app expects.
    func verify(against expected: ExpectedEngine) throws {
        if let name = expected.name, name != engineName {
            throw PatchError("\(url.lastPathComponent) is not the engine this version of the patcher installs (\(name).tar.xz). Download the engine from the same release as the app.")
        }
        let sum = try EngineFile.sha256(of: url)
        guard sum == expected.sha256 else {
            throw PatchError("\(url.lastPathComponent) doesn't match the checksum of this release's engine (got \(sum.prefix(12))…, expected \(expected.sha256.prefix(12))…). Download it again from the release page.")
        }
    }
}

/// Copies a verified engine into Sikarugir's Engines folder.
enum EngineInstaller {
    static func destination(for file: EngineFile, enginesDir: URL = Sikarugir.enginesDir) -> URL {
        enginesDir.appendingPathComponent(file.url.lastPathComponent)
    }

    /// Copies via a temporary name, so Creator never sees a half-written engine.
    @discardableResult
    static func install(_ file: EngineFile, enginesDir: URL = Sikarugir.enginesDir, replace: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: enginesDir, withIntermediateDirectories: true)
        let dest = destination(for: file, enginesDir: enginesDir)
        if fm.fileExists(atPath: dest.path) && !replace {
            throw PatchError("\(dest.lastPathComponent) is already in Sikarugir's Engines folder.")
        }
        let partial = enginesDir.appendingPathComponent(".\(dest.lastPathComponent).partial")
        try? fm.removeItem(at: partial)
        try fm.copyItem(at: file.url, to: partial)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: dest)
        }
        return dest
    }
}

// MARK: - Wrappers

/// A Sikarugir wrapper, read from its bundle without changing it.
struct WrapperInfo: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }

    let templateVersion: String?    // CFBundleVersion, the template it was made or updated from
    let engineVersion: String?      // Contents/SharedSupport/wine/version
    let program: String?            // "Program Name and Path"
    let programFlags: String
    let settings: [String: String]  // the wrapper's Info.plist values, as strings

    init?(url: URL) {
        let contents = url.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport").path)
        else { return nil }
        self.url = url
        var settings: [String: String] = [:]
        for (key, value) in plist {
            switch value {
            case let s as String: settings[key] = s
            case let n as NSNumber: settings[key] = n.stringValue
            default: break
            }
        }
        self.settings = settings
        templateVersion = settings["CFBundleVersion"]
        program = settings["Program Name and Path"]
        programFlags = settings["Program Flags"] ?? ""
        engineVersion = (try? String(contentsOf: contents.appendingPathComponent("SharedSupport/wine/version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The wrappers in Creator's folder (or any folder of wrappers).
    static func detectAll(in dir: URL = Sikarugir.wrappersDir) -> [WrapperInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }
            .compactMap { WrapperInfo(url: dir.appendingPathComponent($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isOn(_ key: String) -> Bool { settings[key] == "1" }

    /// The renderer folders the launcher will point Wine at, from the wrapper's settings.
    /// D3DMetal and DXVK are switched on explicitly; DXMT is used when neither is.
    var selectedRenderers: [String] {
        var names = [isOn("D3DMETAL") ? "d3dmetal" : isOn("DXVK") ? "dxvk" : "dxmt"]
        if isOn("D9VK") { names.append("d9vk") }
        return names
    }

    /// Where a renderer lives in this wrapper: `SharedSupport/renderer` since template 1.0.23,
    /// `Frameworks/renderer` before.
    func rendererFolder(_ name: String) -> URL? {
        let contents = url.appendingPathComponent("Contents")
        for base in ["SharedSupport/renderer", "Frameworks/renderer"] {
            let dir = contents.appendingPathComponent("\(base)/\(name)")
            if FileManager.default.fileExists(atPath: dir.path) { return dir }
        }
        return nil
    }

    var programIsSteam: Bool { program?.lowercased().hasSuffix("/steam.exe") == true }
    var programIsGameExe: Bool { program?.lowercased().hasSuffix("/endfield.exe") == true }
}

/// One line of a wrapper check: what was checked, how it came out, and what to do about it.
struct WrapperCheckItem: Identifiable {
    enum Status { case ok, warning, problem }
    let id: String
    let title: String
    let status: Status
    let detail: String
    var fix: String?
}

/// Checks a wrapper against what the FineWine engine needs. Read-only.
enum WrapperCheck {
    /// Libraries the engine loads from the wrapper's `Contents/Frameworks` by these exact names
    /// (Wine dlopens the first four; wpcap links the last). A template that renamed one would
    /// need an engine rebuild against it.
    static let engineLibraries = ["libgnutls.30.dylib", "libfreetype.6.dylib", "libSDL2-2.0.0.dylib",
                                  "libvulkan.1.dylib", "libpcap.A.dylib"]
    static let steamAppID = "4732690"

    static func run(_ w: WrapperInfo, creatorTemplate: String? = Sikarugir.creatorTemplateVersion()) -> [WrapperCheckItem] {
        var items: [WrapperCheckItem] = []
        let contents = w.url.appendingPathComponent("Contents")

        // Engine
        if let v = w.engineVersion, v.contains("FineWine") {
            items.append(.init(id: "engine", title: "Engine", status: .ok, detail: v))
        } else {
            items.append(.init(id: "engine", title: "Engine", status: .problem,
                               detail: w.engineVersion.map { "Runs another engine: \($0)" } ?? "No engine found in the wrapper.",
                               fix: "In the wrapper's Configure, use Change Engine and pick \(ExpectedEngine.namePrefix)… (install it here first)."))
        }

        // Renderers
        let missing = w.selectedRenderers.filter { w.rendererFolder($0) == nil }
        if missing.isEmpty {
            items.append(.init(id: "renderers", title: "Renderers", status: .ok,
                               detail: w.selectedRenderers.map { $0.uppercased() }.joined(separator: " + ") + " present"))
        } else {
            items.append(.init(id: "renderers", title: "Renderers", status: .problem,
                               detail: "Missing: " + missing.map { $0.uppercased() }.joined(separator: ", "),
                               fix: "Run Update Wrapper in the wrapper's Configure. If they're still missing, run it once more: since template 1.0.23 renderers live in SharedSupport/renderer, and the first update from an older template doesn't install them there."))
        }

        // Libraries the engine loads by name
        let lacking = engineLibraries.filter {
            !FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/\($0)").path)
        }
        if lacking.isEmpty {
            items.append(.init(id: "libraries", title: "Runtime libraries", status: .ok,
                               detail: "All \(engineLibraries.count) libraries the engine loads are present"))
        } else {
            items.append(.init(id: "libraries", title: "Runtime libraries", status: .problem,
                               detail: "Missing from Frameworks: " + lacking.joined(separator: ", "),
                               fix: "Run Update Wrapper. If this template has renamed them, the engine needs a rebuild for it; please report it."))
        }

        // Template
        if let have = w.templateVersion, let newest = creatorTemplate,
           Sikarugir.compareVersions(have, newest) == .orderedAscending {
            items.append(.init(id: "template", title: "Template", status: .warning,
                               detail: "Template \(have); Creator has \(newest)",
                               fix: "Run Update Wrapper in the wrapper's Configure (twice if updating from 1.0.22 or older)."))
        } else if let have = w.templateVersion {
            items.append(.init(id: "template", title: "Template", status: .ok, detail: "Template \(have)"))
        }

        // MSync
        items.append(w.isOn("WINEMSYNC")
            ? .init(id: "msync", title: "MSync", status: .ok, detail: "On")
            : .init(id: "msync", title: "MSync", status: .warning, detail: "Off",
                    fix: "Turn MSync on in Configure; this engine is tested with it."))

        // How the game is started
        let flags = w.programFlags.split(separator: " ").map(String.init)
        if w.programIsSteam {
            let wanted = "-silent -applaunch \(steamAppID) -force-d3d11"
            if flags.contains("-force-d3d11") && flags.contains("-applaunch") && flags.contains(steamAppID) {
                items.append(.init(id: "launch", title: "Launch", status: .ok, detail: "Steam starts the game with -force-d3d11"))
            } else {
                items.append(.init(id: "launch", title: "Launch", status: .warning,
                                   detail: w.programFlags.isEmpty ? "Steam opens without starting the game" : "Program Flags: \(w.programFlags)",
                                   fix: "To start the game directly, set Program Flags to \"\(wanted)\". Without -force-d3d11 the game runs on Vulkan and recompiles its shaders on every launch."))
            }
        } else if w.programIsGameExe {
            items.append(.init(id: "launch", title: "Launch", status: .warning,
                               detail: "Program is Endfield.exe",
                               fix: "The Steam version can't start on its own; point the wrapper at Steam's steam.exe and use Program Flags \"-silent -applaunch \(steamAppID) -force-d3d11\"."))
        } else if let program = w.program {
            let isLauncher = program.lowercased().hasSuffix("/launcher.exe")
            items.append(.init(id: "launch", title: "Launch", status: isLauncher && w.isOn("D9VK") ? .warning : .ok,
                               detail: "Program: \((program as NSString).lastPathComponent)",
                               fix: isLauncher && w.isOn("D9VK")
                                   ? "Turn D9VK off for the Gryphline launcher (it stays blank with D9VK). In the launcher, choose \"Launch with DirectX 11\" from the dropdown next to Start."
                                   : nil))
        }
        return items
    }
}
