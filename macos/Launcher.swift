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
    private var selection: Selection?
    private var activeProcess: Process?
    private var currentLog: URL?

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
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [chooseButton, logButton, spacer, progress, playButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let layout = NSStackView(views: [sourceLabel, statusLabel, actions])
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
        environment["PS3_VFS_ROOT"] = selection.discURL.deletingLastPathComponent().path
        environment["PS3_HDD0_ROOT"] = selection.preparedURL.appendingPathComponent("hdd0").path
        environment["PS3_HDD1_ROOT"] = state.appendingPathComponent("hdd1").path
        environment["PS3_GAMEDATA_ROOT"] = state.appendingPathComponent("gamedata").path
        environment["PAIN_SETTINGS_PATH"] = state.appendingPathComponent("settings.ini").path
        environment["PAIN_LEVELSCRIPT_DIR"] = selection.preparedURL.appendingPathComponent("levels").path
        process.environment = environment
        let began = Date()
        let log = logs.appendingPathComponent("game.log")
        statusLabel.stringValue = "PAIN is running."
        start(process, loggingTo: log, showProgress: false) { [weak self] task in
            guard let self else { return }
            if task.terminationStatus != 0 || Date().timeIntervalSince(began) < 10 {
                self.statusLabel.stringValue = "PAIN closed during launch or play (code \(task.terminationStatus)). Open the log for details."
            } else {
                self.statusLabel.stringValue = "PAIN · BCES00548 · Ready to play"
            }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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

    @objc private func showLog() {
        NSWorkspace.shared.open(currentLog ?? logs)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.setActivationPolicy(.regular)
app.delegate = launcher
app.run()
