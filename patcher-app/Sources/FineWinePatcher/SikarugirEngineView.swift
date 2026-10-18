import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Installs the FineWine engine into Sikarugir and runs the read-only wrapper check.
/// Separate from PatcherEngine: the CrossOver patch flow doesn't know about any of this.
@MainActor
final class SikarugirEngineModel: ObservableObject {
    @Published private(set) var steps: [PatcherEngine.Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var installed: URL?
    @Published var error: String?

    private static let stepLabels = [
        "Checking the engine file",
        "Copying it into Sikarugir's Engines folder",
        "Checking the installed copy",
    ]

    func install(_ file: EngineFile, expected: ExpectedEngine, replace: Bool) {
        guard !isRunning else { return }
        steps = Self.stepLabels.enumerated().map { PatcherEngine.Step(id: $0.offset, label: $0.element) }
        error = nil
        installed = nil
        isRunning = true

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ i: Int) async { current = i; await MainActor.run { self.steps[i].status = .running } }
            func finish(_ i: Int) async { await MainActor.run { self.steps[i].status = .done } }
            do {
                await begin(0)
                try file.verify(against: expected)
                await finish(0)

                await begin(1)
                let dest = try EngineInstaller.install(file, replace: replace)
                await finish(1)

                await begin(2)
                try EngineFile(url: dest).verify(against: expected)
                await finish(2)

                await MainActor.run { self.installed = dest; self.isRunning = false }
            } catch {
                let failed = current
                await MainActor.run {
                    self.steps[failed].status = .failed
                    self.error = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }
}

/// The Sikarugir Engine window: Tools → Sikarugir Engine…
struct SikarugirEngineView: View {
    @StateObject private var model = SikarugirEngineModel()

    @State private var expected = ExpectedEngine.current
    @State private var engineFiles: [EngineFile] = []
    @State private var selectedFile: EngineFile?
    @State private var confirmReplace = false

    @State private var wrappers: [WrapperInfo] = []
    @State private var selectedWrapper: WrapperInfo?
    @State private var checkItems: [WrapperCheckItem] = []

    static let releasesPage = URL(string: "https://github.com/stoicswe/Endfield_FineWine/releases")!
    static let sikarugirPage = URL(string: "https://github.com/Sikarugir-App/Sikarugir")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !Sikarugir.isInstalled { notInstalled }
            engineBox
            if !model.steps.isEmpty { StepsListView(steps: model.steps) }
            if let error = model.error { ErrorBox(message: error) }
            wrapperBox
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refreshEngineFiles(); refreshWrappers() }
        .onChange(of: model.installed) { _ in refreshWrappers() }
        .confirmationDialog("Replace the installed engine?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { startInstall(replace: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedFile?.url.lastPathComponent ?? "This engine") is already in Sikarugir's Engines folder. Wrappers already using it keep their own copy until you change their engine again in Configure.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sikarugir Engine")
                    .font(.title2.weight(.semibold))
                Text("Experimental")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            Text("Runs Endfield without CrossOver, in a Sikarugir wrapper: installs this release's Wine engine into Sikarugir and checks your wrappers. It never changes a wrapper; Sikarugir's Creator and Configure do that. Community-maintained; see docs/sikarugir.md.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notInstalled: some View {
        HStack {
            Label("Sikarugir isn't installed (no Sikarugir Creator in /Applications).", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("Get Sikarugir…") { NSWorkspace.shared.open(Self.sikarugirPage) }
        }
    }

    private var engineBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Engine", systemImage: "shippingbox")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let installed = model.installed {
                        Label("installed · \(installed.deletingPathExtension().deletingPathExtension().lastPathComponent)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text("Download the engine (\(expected?.name ?? ExpectedEngine.namePrefix + "…").tar.xz) from the same release as this app. It's found in Downloads automatically, checked against this release's checksum, and copied into Sikarugir's Engines folder. Then pick it for a wrapper in Creator, or in the wrapper's Configure → Change Engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if engineFiles.isEmpty {
                        Text("No engine file found in Downloads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Engine file:", selection: $selectedFile) {
                            ForEach(engineFiles) { file in
                                Text(file.url.lastPathComponent).tag(Optional(file))
                            }
                        }
                        .labelsHidden()
                    }
                    Spacer()
                    Button("Choose…", action: chooseEngineFile).disabled(model.isRunning)
                    Button("Rescan", action: refreshEngineFiles).disabled(model.isRunning)
                    Button("Download…") { NSWorkspace.shared.open(Self.releasesPage) }
                }

                if expected == nil {
                    Label("This build of the patcher has no engine checksum, so it can't verify engine files. Use an app from a release, or set FINEWINE_SIKARUGIR_ENGINE_SHA256 for development.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(model.isRunning ? "Installing…" : "Install Engine") { installTapped() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFile == nil || expected == nil || model.isRunning || !Sikarugir.isInstalled)
                    Spacer()
                    Button("Show Engines Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Sikarugir.enginesDir])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: Sikarugir.enginesDir.path))
                }
            }
            .padding(4)
        }
    }

    private var wrapperBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Wrapper check", systemImage: "stethoscope")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                Text("Checks a wrapper against what the engine needs. Fixes are done in Sikarugir: Update Wrapper and Change Engine in the wrapper's Configure, new templates through Creator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if wrappers.isEmpty {
                        Text("No wrappers found in ~/Applications/Sikarugir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Wrapper:", selection: $selectedWrapper) {
                            ForEach(wrappers) { w in Text(w.name).tag(Optional(w)) }
                        }
                        .labelsHidden()
                        .onChange(of: selectedWrapper) { _ in runCheck() }
                    }
                    Spacer()
                    Button("Choose Wrapper…", action: chooseWrapper)
                    Button("Check Again", action: refreshWrappers)
                }

                ForEach(checkItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        checkIcon(item.status).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.title): \(item.detail)")
                                .font(.caption)
                                .textSelection(.enabled)
                            if let fix = item.fix {
                                Text(fix)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func checkIcon(_ status: WrapperCheckItem.Status) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .problem: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Engine actions

    private func refreshEngineFiles() {
        expected = ExpectedEngine.current
        var files = EngineFile.find(in: EngineFile.downloadsDir)
        if let chosen = selectedFile, !files.contains(chosen), FileManager.default.fileExists(atPath: chosen.url.path) {
            files.insert(chosen, at: 0)
        }
        engineFiles = files
        // Prefer the file this release expects, then the newest.
        if selectedFile == nil || !files.contains(where: { $0 == selectedFile }) {
            selectedFile = files.first { $0.engineName == expected?.name } ?? files.first
        }
    }

    private func chooseEngineFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose the FineWine engine"
        panel.message = "The \(ExpectedEngine.namePrefix)….tar.xz file from this release."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = EngineFile.downloadsDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard EngineFile.isEngineFileName(url.lastPathComponent) else {
            model.error = "\(url.lastPathComponent) isn't a FineWine engine (expected \(ExpectedEngine.namePrefix)….tar.xz)."
            return
        }
        model.error = nil
        let file = EngineFile(url: url)
        if !engineFiles.contains(file) { engineFiles.insert(file, at: 0) }
        selectedFile = file
    }

    private func installTapped() {
        guard let file = selectedFile else { return }
        if FileManager.default.fileExists(atPath: EngineInstaller.destination(for: file).path) {
            confirmReplace = true
        } else {
            startInstall(replace: false)
        }
    }

    private func startInstall(replace: Bool) {
        guard let file = selectedFile, let expected else { return }
        model.install(file, expected: expected, replace: replace)
    }

    // MARK: - Wrapper actions

    private func refreshWrappers() {
        let chosen = selectedWrapper
        var found = WrapperInfo.detectAll()
        // Keep a wrapper picked from elsewhere, re-read so the check sees its current state.
        if let chosen, !found.contains(where: { $0.url == chosen.url }), let reread = WrapperInfo(url: chosen.url) {
            found.insert(reread, at: 0)
        }
        wrappers = found
        selectedWrapper = found.first { $0.url == chosen?.url } ?? found.first
        runCheck()
    }

    private func runCheck() {
        checkItems = selectedWrapper.map { WrapperCheck.run($0) } ?? []
    }

    private func chooseWrapper() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sikarugir wrapper"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Sikarugir.wrappersDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let wrapper = WrapperInfo(url: url) else {
            checkItems = [WrapperCheckItem(id: "notwrapper", title: url.lastPathComponent, status: .problem,
                                           detail: "Doesn't look like a Sikarugir wrapper (no Info.plist settings or SharedSupport folder).")]
            return
        }
        if !wrappers.contains(where: { $0.url == wrapper.url }) { wrappers.insert(wrapper, at: 0) }
        selectedWrapper = wrapper
        runCheck()
    }
}
