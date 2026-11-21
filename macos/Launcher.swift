import AppKit
import UniformTypeIdentifiers

struct Selection: Decodable {
    let source: String
    let disc: String
    let prepared: String

    var discURL: URL { URL(fileURLWithPath: disc, isDirectory: true) }
    var preparedURL: URL { URL(fileURLWithPath: prepared, isDirectory: true) }
}

final class Launcher: NSObject, NSApplicationDelegate {
    private let files = FileManager.default
    private let bundle = Bundle.main
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 510, height: 188),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered, defer: false
    )
    private let sourceLabel = NSTextField(labelWithString: "Choose your PAIN disc ZIP or extracted folder.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var chooseButton: NSButton!
    private var playButton: NSButton!
    private var logButton: NSButton!
    private var fpsButton: NSButton!
    private var selection: Selection?
    private var activeProcess: Process?
    private var currentLog: URL?
    private var shaderProgressTimer: Timer?
    private var shaderProgressOffset: UInt64 = 0

    private lazy var state: URL = {
        if let override = ProcessInfo.processInfo.environment["PAIN_PREVIEW_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PainRecomp", isDirectory: true)
    }()

    private var logs: URL { state.appendingPathComponent("logs", isDirectory: true) }
    private var resources: URL { bundle.resourceURL! }
    private var helpers: URL { bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        configureWindow()
        refreshSelection()
        do {
            try files.createDirectory(at: logs, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let log = logs.appendingPathComponent("launcher.log")
            let platform = ProcessInfo.processInfo.operatingSystemVersionString
            try "PAIN launcher started on \(platform).\n".write(to: log, atomically: true, encoding: .utf8)
            updateButtons()
        } catch {
            statusLabel.stringValue = "PAIN couldn't create its log folder. \(error.localizedDescription)"
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "--import" {
            importGame(URL(fileURLWithPath: arguments[2]), playWhenReady: arguments.contains("--play"))
        } else if arguments.count == 2, arguments[1] == "--play" {
            play()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        activeProcess == nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        activeProcess?.terminate()
    }

    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit PAIN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        NSApp.mainMenu = menu
    }

    private func configureWindow() {
        window.title = "PAIN"
        window.isReleasedWhenClosed = false
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chooseButton = NSButton(title: "Choose Game…", target: self, action: #selector(chooseGame))
        playButton = NSButton(title: "Play", target: self, action: #selector(play))
        playButton.keyEquivalent = "\r"
        logButton = NSButton(title: "Show Log", target: self, action: #selector(showLog))
        fpsButton = NSButton(checkboxWithTitle: "Show FPS", target: self, action: #selector(saveFPSChoice))
        fpsButton.state = UserDefaults.standard.bool(forKey: "showFPS") ? .on : .off
        fpsButton.toolTip = "Show display and game FPS in the game window title."
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [chooseButton, logButton, spacer, progress, playButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let layout = NSStackView(views: [sourceLabel, statusLabel, fpsButton, actions])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(layout)
        window.contentView = content
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            sourceLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            actions.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }

    private func refreshSelection() {
        let url = state.appendingPathComponent("selection.json")
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        guard let decoded,
              files.fileExists(atPath: decoded.discURL.appendingPathComponent("PARAM.SFO").path),
              files.fileExists(atPath: decoded.discURL.appendingPathComponent("USRDIR/CacheData.pak").path),
              files.fileExists(atPath: decoded.preparedURL.appendingPathComponent("EBOOT.elf").path),
              files.fileExists(atPath: decoded.preparedURL.appendingPathComponent(
                "hdd0/game/BCES00548/USRDIR/CacheFlags/CacheDone.flg").path) else {
            selection = nil
            sourceLabel.stringValue = "Choose your PAIN disc ZIP or extracted folder."
            sourceLabel.toolTip = nil
            statusLabel.stringValue = decoded == nil ? "" : "The previous game location is unavailable. Choose it again."
            updateButtons()
            return
        }
        selection = decoded
        sourceLabel.stringValue = URL(fileURLWithPath: decoded.source).lastPathComponent
        sourceLabel.toolTip = decoded.source
        statusLabel.stringValue = "PAIN · BCES00548 · Ready to play"
        updateButtons()
    }

    private func updateButtons() {
        chooseButton.isEnabled = activeProcess == nil
        fpsButton.isEnabled = activeProcess == nil
        playButton.isEnabled = activeProcess == nil && selection != nil
        logButton.isEnabled = currentLog != nil || files.fileExists(atPath: logs.path)
    }

    @objc private func chooseGame() {
        let picker = NSOpenPanel()
        picker.title = "Choose PAIN Disc Files"
        picker.message = "Select your PAIN BCES00548 ZIP or an extracted disc folder."
        picker.prompt = "Check Game"
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowedContentTypes = [.zip]
        picker.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = picker.url { self?.importGame(url) }
        }
    }

    private func importGame(_ source: URL, playWhenReady: Bool = false) {
        let process = Process()
        process.executableURL = resources.appendingPathComponent("Python/bin/python3")
        process.arguments = [
            "-B", resources.appendingPathComponent("game_data.py").path, "import", source.path,
            state.path, resources.appendingPathComponent("disc.json").path,
            helpers.appendingPathComponent("RPCS3.app/Contents/MacOS/rpcs3").path,
        ]

        let log = logs.appendingPathComponent("setup.log")
        statusLabel.stringValue = "Checking and preparing the selected files…"
        start(process, loggingTo: log) { [weak self] task in
            guard let self else { return }
            if task.terminationStatus == 0 {
                self.refreshSelection()
                if playWhenReady { self.play() }
            } else {
                let detail = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") }).map(String.init)
                self.statusLabel.stringValue = detail ?? "Game setup failed. Open the log for details."
            }
        }
    }

    @objc private func play() {
        refreshSelection()
        guard let selection else { return }
        let process = Process()
        process.executableURL = helpers.appendingPathComponent("PainRecomp")
        process.arguments = [selection.preparedURL.appendingPathComponent("EBOOT.elf").path]
        process.currentDirectoryURL = state
        var environment = ProcessInfo.processInfo.environment
        // Redirected stderr otherwise enables per-wait tracing in the runtime.
        environment["PS3_VERBOSE"] = environment["PS3_VERBOSE"] ?? "0"
        // The guest's SurMixer creates its notification queue before the caller uses its key.
        environment["PS3_PRIO_START"] = environment["PS3_PRIO_START"] ?? "1"
        environment["PS3_VFS_ROOT"] = selection.discURL.deletingLastPathComponent().path
        environment["PS3_HDD0_ROOT"] = selection.preparedURL.appendingPathComponent("hdd0").path
        let recipes = resources.appendingPathComponent("shader-recipes.bin")
        let prepareShaders = files.isReadableFile(atPath: recipes.path) &&
            environment["PAIN_PREPARE_SHADERS"] != "0"
        if prepareShaders {
            environment["PS3RECOMP_SHADER_RECIPES"] = recipes.path
            environment["PS3RECOMP_SHADER_GAME_DIR"] = selection.preparedURL
                .appendingPathComponent("hdd0/game/BCES00548/USRDIR", isDirectory: true).path
            let cache = state.appendingPathComponent("Shader Cache/MSL", isDirectory: true)
            if (try? files.createDirectory(at: cache, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil {
                environment["PS3RECOMP_MSL_CACHE"] = environment["PS3RECOMP_MSL_CACHE"] ?? cache.path
            }
        }
        let hdd1 = state.appendingPathComponent("hdd1", isDirectory: true)
        do {
            try files.createDirectory(at: hdd1, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        } catch {
            statusLabel.stringValue = "PAIN couldn't create its cache folder. \(error.localizedDescription)"
            return
        }
        environment["PS3_HDD1_ROOT"] = hdd1.path
        if fpsButton.state == .on {
            environment["PS3RECOMP_METAL_FPS"] = "1"
            environment["AUDIO_RATE"] = "1"
        }
        environment["PS3_TITLE"] = "PAIN"
        environment["PAIN_BUILD"] = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        environment["PS3_GAMEDATA_ROOT"] = state.appendingPathComponent("gamedata").path
        environment["PAIN_SETTINGS_PATH"] = state.appendingPathComponent("settings.ini").path
        environment["PAIN_LEVELSCRIPT_DIR"] = selection.preparedURL.appendingPathComponent("levels").path
        process.environment = environment
        let began = Date()
        let log = logs.appendingPathComponent("game.log")
        statusLabel.stringValue = prepareShaders ? "Preparing shaders…" : "PAIN is starting…"
        start(process, loggingTo: log, showProgress: prepareShaders) { [weak self] task in
            guard let self else { return }
            if task.terminationStatus != 0 || Date().timeIntervalSince(began) < 10 {
                self.statusLabel.stringValue = "PAIN closed during launch or play (code \(task.terminationStatus)). Open the log for details."
            } else {
                self.statusLabel.stringValue = "PAIN · BCES00548 · Ready to play"
            }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if activeProcess === process {
            shaderProgressOffset = 0
            shaderProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
                [weak self] timer in
                guard let self, let handle = try? FileHandle(forReadingFrom: log) else { return }
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: self.shaderProgressOffset)
                    let data = try handle.read(upToCount: 65_536) ?? Data()
                    guard let newline = data.lastIndex(of: 10) else {
                        if data.count == 65_536 { self.shaderProgressOffset += UInt64(data.count) }
                        return
                    }
                    self.shaderProgressOffset += UInt64(newline + 1)
                    let lines = String(decoding: data[...newline], as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                    if let result = lines.first(where: { $0.hasPrefix("[rsx] Metal backend init") }) {
                        self.statusLabel.stringValue = result.contains("OK -- window open")
                            ? "PAIN is running." : "PAIN couldn't start Metal. Open the log for details."
                        self.progress.stopAnimation(nil)
                        timer.invalidate()
                        self.shaderProgressTimer = nil
                    } else if let line = lines.last(where: { $0.hasPrefix("[shader-prep] Preparing shaders") }) {
                        self.statusLabel.stringValue = String(line.dropFirst("[shader-prep] ".count)) + "…"
                    }
                } catch {
                    // The game log remains available even if reading progress fails.
                }
            }
        }
    }

    private func start(_ process: Process, loggingTo log: URL, showProgress: Bool = true,
                       finished: @escaping (Process) -> Void) {
        guard activeProcess == nil else { return }
        do {
            try files.createDirectory(at: logs, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try Data().write(to: log, options: .atomic)
            let stream = try FileHandle(forWritingTo: log)
            process.standardOutput = stream
            process.standardError = stream
            process.terminationHandler = { [weak self] task in
                if task.terminationStatus != 0 {
                    let line = "\nPAIN process exited with code \(task.terminationStatus).\n"
                    try? stream.write(contentsOf: Data(line.utf8))
                }
                try? stream.close()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeProcess = nil
                    self.shaderProgressTimer?.invalidate()
                    self.shaderProgressTimer = nil
                    self.progress.stopAnimation(nil)
                    self.updateButtons()
                    finished(task)
                }
            }
            currentLog = log
            try process.run()
            activeProcess = process
            if showProgress { progress.startAnimation(nil) }
        } catch {
            let message = "PAIN couldn't start. \(error.localizedDescription)"
            statusLabel.stringValue = message
            try? message.write(to: log, atomically: true, encoding: .utf8)
        }
        updateButtons()
    }

    @objc private func saveFPSChoice() {
        UserDefaults.standard.set(fpsButton.state == .on, forKey: "showFPS")
    }

    @objc private func showLog() {
        // Reveal the file: the game log is too large to open comfortably and
        // players need to be able to copy it somewhere.
        if let log = currentLog, files.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(logs)
        }
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.setActivationPolicy(.regular)
app.delegate = launcher
app.run()
