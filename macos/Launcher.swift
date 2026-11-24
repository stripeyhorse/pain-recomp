import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Selection: Decodable {
    let source: String
    let disc: String
    let prepared: String

    var discURL: URL { URL(fileURLWithPath: disc, isDirectory: true) }
    var preparedURL: URL { URL(fileURLWithPath: prepared, isDirectory: true) }
}

/// What the space under the art says: one of these at a time, in a space of
/// fixed height, so the window keeps its size whatever happens.
enum LauncherStatus: Equatable {
    /// The title, with the disc ID or "No game chosen" under it.
    case title
    /// Work under way; a bar with a count once `total` is known.
    case progress(String, done: Int = 0, total: Int = 0)
    case problem(String)

    /// "[shader-prep] Preparing shaders (96 of 163)" as (96, 163).
    static func shaderCount(_ line: Substring) -> (done: Int, total: Int)? {
        let prefix = "[shader-prep] Preparing shaders ("
        guard line.hasPrefix(prefix), line.hasSuffix(")") else { return nil }
        let numbers = line.dropFirst(prefix.count).dropLast().split(separator: " ")
        guard numbers.count == 3, numbers[1] == "of", let done = Int(numbers[0]), let total = Int(numbers[2]),
              total > 0 else { return nil }
        return (min(done, total), total)
    }
}

/// The player's own disc art (never shipped with the app), drawn under a
/// transparent title bar. No text is drawn over it.
final class BannerView: NSView {
    /// PIC1 fills the banner; ICON0, a logo, is shown whole.
    var art: (image: CGImage, fills: Bool)? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let art, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = CGSize(width: art.image.width, height: art.image.height)
        let rect: CGRect
        if art.fills {
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            // Cut 70% of the excess from the top: PAIN's figure stands low in PIC1.
            rect = CGRect(x: (bounds.width - drawn.width) / 2, y: -(drawn.height - bounds.height) * 0.3,
                          width: drawn.width, height: drawn.height)
        } else {
            let scale = min(1, (bounds.height - 48) / size.height)
            rect = CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2,
                          width: size.width * scale, height: size.height * scale)
        }
        context.interpolationQuality = .high
        context.draw(art.image, in: rect)
    }
}

final class Launcher: NSObject, NSApplicationDelegate {
    static let width: CGFloat = 560
    static let bannerHeight: CGFloat = 240
    static let margin: CGFloat = 24
    /// labelColor at 70% of its opacity: quieter, and still at least 4.5:1 on
    /// the window background in both appearances, where secondaryLabelColor
    /// is 3.95:1 in light. Resolved per appearance; withAlphaComponent alone isn't.
    static let secondaryText = NSColor(name: nil) { appearance in
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor.usingColorSpace(.sRGB)!
            color = label.withAlphaComponent(label.alphaComponent * 0.7)
        }
        return color
    }

    /// The default button's bezel: the accent, darkened toward black only as
    /// far as its white title needs for 4.5:1 (the blue accent is 4.02:1).
    static let defaultBezel = NSColor(name: nil) { appearance in
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)! }
        return darkened(accent).color
    }

    static func darkened(_ accent: NSColor) -> (color: NSColor, fraction: CGFloat) {
        let c = accent.usingColorSpace(.sRGB)!
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var fraction: CGFloat = 0
        while true {
            let k = 1 - fraction
            let color = NSColor(srgbRed: c.redComponent * k, green: c.greenComponent * k, blue: c.blueComponent * k, alpha: 1)
            let luminance = 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) +
                0.0722 * channel(color.blueComponent)
            if 1.05 / (luminance + 0.05) >= 4.5 || fraction >= 1 { return (color, fraction) }
            fraction += 0.01
        }
    }

    private let files = FileManager.default
    private let bundle = Bundle.main
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: Launcher.width, height: 200),
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    private let banner = BannerView()
    private let titleBlock = NSView()
    private let titleLabel = NSTextField(labelWithString: "PAIN")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let controllerRow = NSStackView()
    private let controllerLabel = NSTextField(labelWithString: "")
    private let progressBlock = NSStackView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    /// Two bars, as one that has ever been indeterminate draws its value as a stub.
    private let progress = NSProgressIndicator()
    private let activity = NSProgressIndicator()
    private let problemBlock = NSStackView()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private var bannerHeight: NSLayoutConstraint!
    private var bandTop: NSLayoutConstraint!
    private var chooseButton: NSButton!
    private var playButton: NSButton!
    private var logButton: NSButton!
    private var settingsButton: NSButton!
    private var selection: Selection?
    private(set) var status = LauncherStatus.title
    private var artDisc: URL?
    /// The Dock icon made from the chosen disc's ICON0, handed to the game too.
    private var dockIcon: URL?
    private var announcedAt = Date.distantPast
    private var activeProcess: Process?
    /// Set while the launcher waits for the game before quitting itself.
    private var quitting = false
    private var currentLog: URL?
    private var shaderProgressTimer: Timer?
    private var shaderProgressOffset: UInt64 = 0
    let navigator = ControllerNavigator()
    private var controllerInput: ControllerInput?

    /// Speaks a status change; `urgent` for errors.
    lazy var announce: (String, Bool) -> Void = { [weak self] text, urgent in
        guard let window = self?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (urgent ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
    }

    private lazy var state: URL = {
        if let override = ProcessInfo.processInfo.environment["PAIN_PREVIEW_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PainRecomp", isDirectory: true)
    }()

    private var logs: URL { state.appendingPathComponent("logs", isDirectory: true) }
    private var settingsFile: URL { state.appendingPathComponent("settings.ini") }
    private lazy var settingsSheet = SettingsSheet(url: settingsFile)
    private var resources: URL { bundle.resourceURL! }
    private var helpers: URL { bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        configureWindow()
        navigator.isBusy = { [weak self] in self?.activeProcess != nil }
        navigator.screen = { [weak self] in self?.controllerScreen() }
        controllerInput = ControllerInput(navigator: navigator) { [weak self] in self?.showController($0) }
        refreshSelection()
        do {
            try files.createDirectory(at: logs, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let log = logs.appendingPathComponent("launcher.log")
            let platform = ProcessInfo.processInfo.operatingSystemVersionString
            try "PAIN launcher started on \(platform).\n".write(to: log, atomically: true, encoding: .utf8)
            updateButtons()
        } catch {
            show(.problem("PAIN couldn't create its log folder. \(error.localizedDescription)"))
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

    /// The window is hidden, and the app out of the Dock, while the game's own
    /// window is open; the app stays until the game ends, which brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        activeProcess == nil
    }

    /// Quitting while the game runs asks it to quit as its close button does
    /// (SIGTERM: REQUEST_EXITGAME, up to 3 s, longer for a save in flight) and
    /// waits up to 6 s off the main thread, so a visible window stays live;
    /// SIGKILL is the last resort.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let process = activeProcess, process.isRunning, !quitting else { return .terminateNow }
        quitting = true
        process.terminate()
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(6)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit PAIN", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        NSApp.mainMenu = menu
    }

    private func label(_ field: NSTextField, size: CGFloat = NSFont.systemFontSize, secondary: Bool = false) {
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? Self.secondaryText : .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureWindow() {
        window.title = "PAIN"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        banner.clipsToBounds = true

        // The title block: PAIN, the disc ID under it, the controller at the right.
        label(titleLabel)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        label(subtitleLabel, secondary: true)
        label(controllerLabel, size: NSFont.smallSystemFontSize, secondary: true)
        controllerLabel.lineBreakMode = .byTruncatingTail
        controllerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controllerLabel.setAccessibilityElement(true)
        let pad = NSImageView(image: NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)!)
        pad.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        pad.contentTintColor = Self.secondaryText
        pad.setAccessibilityElement(false)
        controllerRow.setViews([pad, controllerLabel], in: .leading)
        controllerRow.spacing = 4
        controllerRow.isHidden = true
        controllerRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, subtitleLabel, controllerRow] { titleBlock.addSubview(view) }

        // Progress: what is happening at the left, the count at the right, the bar under both.
        label(progressLabel)
        label(countLabel, secondary: true)
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // The bar carries both as its label and value.
        progressLabel.setAccessibilityElement(false)
        countLabel.setAccessibilityElement(false)
        progress.style = .bar
        progress.isIndeterminate = false
        activity.style = .bar
        activity.isIndeterminate = true
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let counts = NSStackView(views: [progressLabel, gap, countLabel])
        counts.alignment = .firstBaseline
        progressBlock.setViews([counts, progress, activity], in: .top)
        progressBlock.orientation = .vertical
        progressBlock.alignment = .leading
        progressBlock.spacing = 8

        // A problem: a warning sign and up to three lines.
        label(problemLabel)
        problemLabel.maximumNumberOfLines = 3
        problemLabel.cell?.truncatesLastVisibleLine = true
        problemLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 18 - 8
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                 accessibilityDescription: "Error")!)
        warning.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        warning.contentTintColor = .systemRed
        warning.widthAnchor.constraint(equalToConstant: 18).isActive = true
        problemBlock.setViews([warning, problemLabel], in: .leading)
        problemBlock.alignment = .top
        problemBlock.spacing = 8

        chooseButton = NSButton(title: "Choose Game…", target: self, action: #selector(chooseGame))
        settingsButton = NSButton(title: "Settings…", target: self, action: #selector(showSettings))
        logButton = NSButton(title: "Show Log", target: self, action: #selector(showLog))
        playButton = NSButton(title: "Play", target: self, action: #selector(play))
        playButton.controlSize = .large
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [chooseButton, settingsButton, logButton, spacer, playButton])
        actions.alignment = .centerY
        actions.spacing = 8
        // Play first, then the row left to right.
        window.autorecalculatesKeyViewLoop = false
        window.initialFirstResponder = playButton
        playButton.nextKeyView = chooseButton
        chooseButton.nextKeyView = settingsButton
        settingsButton.nextKeyView = logButton
        logButton.nextKeyView = playButton

        let band = NSView()
        let content = NSView()
        for view in [titleBlock, progressBlock, problemBlock] as [NSView] { band.addSubview(view) }
        for view in [banner, band, actions] as [NSView] { content.addSubview(view) }
        for view in [banner, band, actions, titleBlock, progressBlock, problemBlock, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        window.contentView = content
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        bandTop = band.topAnchor.constraint(equalTo: banner.bottomAnchor)
        // The window sizes itself to the content (layOut), so this one gives way to it.
        let bottom = actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin)
        bottom.priority = NSLayoutConstraint.Priority(490)
        var constraints: [NSLayoutConstraint] = [
            content.widthAnchor.constraint(equalToConstant: Self.width),
            banner.topAnchor.constraint(equalTo: content.topAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bannerHeight!, bandTop!, bottom,
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            // Three lines of text or two of title; the same in every state.
            band.heightAnchor.constraint(equalToConstant: 48),
            actions.topAnchor.constraint(equalTo: band.bottomAnchor, constant: 16),
            actions.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            titleLabel.topAnchor.constraint(equalTo: titleBlock.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleBlock.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleBlock.leadingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: titleBlock.bottomAnchor),
            controllerLabel.lastBaselineAnchor.constraint(equalTo: subtitleLabel.lastBaselineAnchor),
            controllerRow.trailingAnchor.constraint(equalTo: titleBlock.trailingAnchor),
            controllerRow.leadingAnchor.constraint(greaterThanOrEqualTo: subtitleLabel.trailingAnchor, constant: 16),
            counts.widthAnchor.constraint(equalTo: progressBlock.widthAnchor),
            progress.widthAnchor.constraint(equalTo: progressBlock.widthAnchor),
            activity.widthAnchor.constraint(equalTo: progressBlock.widthAnchor),
        ]
        for block in [titleBlock, progressBlock, problemBlock] as [NSView] {
            constraints += [
                block.leadingAnchor.constraint(equalTo: band.leadingAnchor),
                block.trailingAnchor.constraint(equalTo: band.trailingAnchor),
                block.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        layOut(banner: false, animate: false)
    }

    /// Shows the banner or not, keeping the window's top edge where it is.
    private func layOut(banner visible: Bool, animate: Bool) {
        banner.isHidden = !visible
        bannerHeight.constant = visible ? Self.bannerHeight : 0
        let titlebar = window.frame.height - window.contentLayoutRect.height
        bandTop.constant = visible ? 20 : titlebar + 8
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = window.frame
        let height = content.fittingSize.height
        guard height != frame.height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: animate && window.isVisible &&
                        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// PIC1, else ICON0, from the player's disc, decoded off the main thread.
    /// The banner's space is kept from the start when either file is there.
    private func loadArt(_ disc: URL?) {
        guard disc != artDisc else { return }
        artDisc = disc
        banner.art = nil
        // Known now, written in a moment: --play starts the game before the icon is drawn,
        // and the game reads it only when its window opens.
        NSApp.applicationIconImage = nil
        let icon0 = disc.map { $0.appendingPathComponent("ICON0.PNG") }.flatMap { files.isReadableFile(atPath: $0.path) ? $0 : nil }
        let iconFile = state.appendingPathComponent("Dock Icon.png")
        dockIcon = icon0 == nil ? nil : iconFile
        if icon0 == nil { try? files.removeItem(at: iconFile) }
        let candidates = disc.map { [($0.appendingPathComponent("PIC1.PNG"), true),
                                     ($0.appendingPathComponent("ICON0.PNG"), false)] } ?? []
        let present = candidates.filter { files.isReadableFile(atPath: $0.0.path) }
        layOut(banner: !present.isEmpty, animate: true)
        guard !present.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let art = present.lazy.compactMap { url, fills -> (CGImage, Bool)? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1280,
                          kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return nil }
                return (image, fills)
            }.first
            let icon = icon0.flatMap { Self.writeDockIcon(from: $0, to: iconFile) }
            DispatchQueue.main.async {
                guard let self, self.artDisc == disc else { return }
                if let art { self.banner.art = (art.0, art.1) } else { self.layOut(banner: false, animate: true) }
                if let icon {
                    NSApp.applicationIconImage = NSImage(cgImage: icon, size: NSSize(width: 512, height: 512))
                }
            }
        }
    }

    /// A 512 px Dock icon: ICON0 fitted, 10% in, on a dark tile in the macOS
    /// icon shape. Written to the state folder for the game to use as well.
    static func writeDockIcon(from icon0: URL, to file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(icon0 as CFURL, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Apple's grid: an 824 pt tile on a 1024 pt canvas, leaving room for the shadow.
        let tile = CGRect(x: 50, y: 50, width: 412, height: 412)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 92, cornerHeight: 92, transform: nil))
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        context.fillPath()
        context.restoreGState()
        let inner = tile.insetBy(dx: tile.width * 0.1, dy: tile.height * 0.1)
        let scale = min(inner.width / CGFloat(logo.width), inner.height / CGFloat(logo.height))
        let size = CGSize(width: CGFloat(logo.width) * scale, height: CGFloat(logo.height) * scale)
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2,
                                      width: size.width, height: size.height))
        guard let icon = context.makeImage(),
              let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, icon, nil)
        return CGImageDestinationFinalize(out) ? icon : nil
    }

    /// Shows one status in the space under the art and tells VoiceOver:
    /// errors at once, new work when it starts, counts at most every 10 s.
    func show(_ new: LauncherStatus) {
        let old = status
        status = new
        activity.stopAnimation(nil)
        titleBlock.isHidden = true
        progressBlock.isHidden = true
        problemBlock.isHidden = true
        switch new {
        case .title:
            titleBlock.isHidden = false
            subtitleLabel.stringValue = selection == nil ? "No game chosen" : "BCES00548"
        case let .progress(text, done, total):
            progressBlock.isHidden = false
            progressLabel.stringValue = text
            countLabel.stringValue = total > 0 ? "\(done) of \(total)" : ""
            progress.isHidden = total == 0
            activity.isHidden = total > 0
            progress.maxValue = Double(max(total, 1))
            progress.doubleValue = Double(done)
            progress.setAccessibilityValueDescription(countLabel.stringValue)
            for bar in [progress, activity] {
                bar.setAccessibilityLabel(text.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
            }
        case let .problem(text):
            problemBlock.isHidden = false
            problemLabel.stringValue = text
            problemLabel.toolTip = text
        }
        if !progressBlock.isHidden && !activity.isHidden { activity.startAnimation(nil) }

        switch new {
        case let .problem(text):
            announce(text, true)
        case let .progress(text, done, total):
            if case let .progress(previous, _, _) = old, previous == text,
               Date().timeIntervalSince(announcedAt) < 10 { return }
            let name = text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            announce(total > 0 ? "\(name), \(done) of \(total)" : name, false)
        case .title:
            return
        }
        announcedAt = Date()
    }

    /// The connected controller beside the disc ID; nothing when none is connected.
    func showController(_ status: (text: String, label: String)?) {
        controllerLabel.stringValue = status?.text ?? ""
        controllerLabel.setAccessibilityLabel(status?.label)
        controllerRow.isHidden = status == nil
    }

    private func controllerScreen() -> ControllerNavigator.Screen? {
        if let sheet = window.attachedSheet {
            if sheet === settingsSheet.panel { return settingsSheet.controllerScreen }
            // The game picker: Circle backs out of it; choosing needs a mouse or keyboard.
            return ControllerNavigator.Screen(window: sheet, controls: [],
                                              cancel: { [weak self] in self?.window.endSheet(sheet, returnCode: .cancel) })
        }
        return ControllerNavigator.Screen(window: window, controls: [chooseButton, settingsButton, logButton, playButton],
                                          initial: playButton, play: playButton)
    }

    func refreshSelection() {
        let url = state.appendingPathComponent("selection.json")
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        guard let decoded,
              files.fileExists(atPath: decoded.discURL.appendingPathComponent("PARAM.SFO").path),
              files.fileExists(atPath: decoded.discURL.appendingPathComponent("USRDIR/CacheData.pak").path),
              files.fileExists(atPath: decoded.preparedURL.appendingPathComponent("EBOOT.elf").path),
              files.fileExists(atPath: decoded.preparedURL.appendingPathComponent(
                "hdd0/game/BCES00548/USRDIR/CacheFlags/CacheDone.flg").path) else {
            selection = nil
            chooseButton.toolTip = nil
            chooseButton.setAccessibilityHelp(nil)
            loadArt(nil)
            show(decoded == nil ? .title : .problem("The previous game location is unavailable. Choose it again."))
            updateButtons()
            return
        }
        selection = decoded
        // The chosen file matters when changing it, so it is on the button that does.
        chooseButton.toolTip = decoded.source
        chooseButton.setAccessibilityHelp("Current game: " + URL(fileURLWithPath: decoded.source).lastPathComponent)
        loadArt(decoded.discURL)
        show(.title)
        updateButtons()
    }

    private func updateButtons() {
        chooseButton.isEnabled = activeProcess == nil
        settingsButton.isEnabled = activeProcess == nil
        playButton.isEnabled = activeProcess == nil && selection != nil
        logButton.isEnabled = currentLog != nil || files.fileExists(atPath: logs.path)
        // Return, and with it the default button's accent, goes to the next
        // step: Play, or Choose Game… when there is nothing to play.
        let choose = selection == nil
        playButton.keyEquivalent = choose ? "" : "\r"
        chooseButton.keyEquivalent = choose ? "\r" : ""
        playButton.bezelColor = choose ? nil : Self.defaultBezel
        chooseButton.bezelColor = choose ? Self.defaultBezel : nil
        // A child starting or ending changes whether the controller counts.
        navigator.refresh()
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

    func importGame(_ source: URL, playWhenReady: Bool = false) {
        let process = Process()
        process.executableURL = resources.appendingPathComponent("Python/bin/python3")
        process.arguments = [
            "-B", resources.appendingPathComponent("game_data.py").path, "import", source.path,
            state.path, resources.appendingPathComponent("disc.json").path,
            helpers.appendingPathComponent("RPCS3.app/Contents/MacOS/rpcs3").path,
        ]

        let log = logs.appendingPathComponent("setup.log")
        start(process, loggingTo: log, as: .progress("Checking and preparing the selected files…")) { [weak self] task in
            guard let self else { return }
            if task.terminationStatus == 0 {
                self.refreshSelection()
                if playWhenReady { self.play() }
            } else {
                let detail = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("Error:") })
                    // The warning sign says it is an error; the log keeps the prefix.
                    .map { $0.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces) }
                self.show(.problem(detail ?? "Game setup failed. Open the log for details."))
            }
        }
    }

    @objc private func play() {
        refreshSelection()
        guard let selection else { return }
        let process = Process()
        process.executableURL = helpers.appendingPathComponent("PAIN.app/Contents/MacOS/PainRecomp")
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
            // Pipelines built during play are recorded here and prepared before Play on the next
            // start, and the prepared ones are kept as a Metal binary archive for this Mac.
            let pipelines = state.appendingPathComponent("Shader Cache/Pipelines", isDirectory: true)
            if (try? files.createDirectory(at: pipelines, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil {
                environment["PS3RECOMP_PIPELINE_CACHE"] = environment["PS3RECOMP_PIPELINE_CACHE"] ?? pipelines.path
            }
        }
        let hdd1 = state.appendingPathComponent("hdd1", isDirectory: true)
        do {
            try files.createDirectory(at: hdd1, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        } catch {
            show(.problem("PAIN couldn't create its cache folder. \(error.localizedDescription)"))
            return
        }
        environment["PS3_HDD1_ROOT"] = hdd1.path
        if UserDefaults.standard.bool(forKey: "showFPS") {
            environment["PS3RECOMP_METAL_FPS"] = "1"
            environment["AUDIO_RATE"] = "1"
        }
        environment["PS3_TITLE"] = "PAIN"
        if let dockIcon { environment["PS3RECOMP_APP_ICON"] = dockIcon.path }
        environment["PAIN_BUILD"] = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        environment["PS3_GAMEDATA_ROOT"] = state.appendingPathComponent("gamedata").path
        environment["PAIN_SETTINGS_PATH"] = settingsFile.path
        environment["PAIN_LEVELSCRIPT_DIR"] = selection.preparedURL.appendingPathComponent("levels").path
        process.environment = environment
        let began = Date()
        let log = logs.appendingPathComponent("game.log")
        start(process, loggingTo: log, as: .progress("Starting…")) { [weak self] task in
            guard let self else { return }
            if task.terminationStatus != 0 || Date().timeIntervalSince(began) < 10 {
                self.show(.problem("PAIN closed during launch or play (code \(task.terminationStatus)). Open the log for details."))
            } else {
                self.show(.title)
            }
            NSApp.setActivationPolicy(.regular)
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if activeProcess === process { followGameLog(log) }
    }

    /// Reads the game log as it grows: shader progress, then whether the
    /// game's window opened. The launcher hides while that window is open.
    private func followGameLog(_ log: URL) {
        shaderProgressOffset = 0
        shaderProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
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
                for line in String(decoding: data[...newline], as: UTF8.self).split(whereSeparator: \.isNewline) {
                    if line.hasPrefix("[rsx] Metal backend init") {
                        timer.invalidate()
                        self.shaderProgressTimer = nil
                        if line.contains("OK -- window open") {
                            // One Dock icon while the game plays: the game's.
                            self.window.orderOut(nil)
                            NSApp.setActivationPolicy(.accessory)
                        } else {
                            self.show(.problem("PAIN couldn't start Metal. Open the log for details."))
                        }
                        return
                    } else if let count = LauncherStatus.shaderCount(line) {
                        self.show(.progress("Preparing shaders", done: count.done, total: count.total))
                    } else if line.hasPrefix("[shader-prep] Prepared ") {
                        self.show(.progress("Starting…"))
                    }
                }
            } catch {
                // The game log remains available even if reading progress fails.
            }
        }
    }

    private func start(_ process: Process, loggingTo log: URL, as working: LauncherStatus,
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
                let line = task.terminationReason == .uncaughtSignal
                    ? "\nPAIN process ended by signal \(task.terminationStatus).\n"
                    : "\nPAIN process exited with code \(task.terminationStatus).\n"
                try? stream.write(contentsOf: Data(line.utf8))
                try? stream.close()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeProcess = nil
                    self.shaderProgressTimer?.invalidate()
                    self.shaderProgressTimer = nil
                    self.updateButtons()
                    // Quitting: the window must not come back on the way out.
                    if !self.quitting { finished(task) }
                }
            }
            currentLog = log
            try process.run()
            activeProcess = process
            show(working)
        } catch {
            let message = "PAIN couldn't start. \(error.localizedDescription)"
            show(.problem(message))
            try? message.write(to: log, atomically: true, encoding: .utf8)
        }
        updateButtons()
    }

    @objc private func showSettings() {
        settingsSheet.present(on: window)
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
