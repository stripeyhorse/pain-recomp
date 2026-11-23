import AppKit

/// The Settings sheet: the player-facing keys of settings.ini, plus Show FPS
/// (a launcher preference). Only the controls the player changed are written.
final class SettingsSheet: NSObject {
    private struct Choice {
        let title: String
        let value: String
    }

    private final class Menu {
        let setting: Setting
        let base: [Choice]
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        var choices: [Choice] = []
        var shown = 0
        init(_ setting: Setting, _ base: [Choice]) {
            self.setting = setting
            self.base = base
        }
    }

    private final class Toggle {
        let setting: Setting
        let button: NSButton
        var shown = false
        init(_ setting: Setting, _ title: String) {
            self.setting = setting
            button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        }
    }

    let url: URL
    let panel = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

    private let resolution = Menu(.resScale, [
        Choice(title: "1280 × 720", value: "1"), Choice(title: "1920 × 1080", value: "1.5"),
        Choice(title: "2560 × 1440", value: "2"), Choice(title: "3840 × 2160", value: "3"),
    ])
    private let frameRate = Menu(.frameRate, [Choice(title: "30 FPS", value: "30"), Choice(title: "60 FPS", value: "60")])
    private let vsync = Toggle(.vsync, "V-Sync")
    private let fullscreen = Toggle(.fullscreen, "Full screen")
    private let aspect = Menu(.aspect, [Choice(title: "Fit", value: "fit"), Choice(title: "Stretch", value: "stretch")])
    private let antialiasing = Menu(.aa, [
        Choice(title: "Off", value: "off"), Choice(title: "FXAA", value: "fxaa"), Choice(title: "SMAA", value: "smaa"),
    ])
    private let upscale = Menu(.upscale, [Choice(title: "Off", value: "off"), Choice(title: "MetalFX", value: "metalfx")])
    private let anisotropic = Menu(.anisotropic, [
        Choice(title: "Off", value: "0"), Choice(title: "2×", value: "2"), Choice(title: "4×", value: "4"),
        Choice(title: "8×", value: "8"), Choice(title: "16×", value: "16"),
    ])
    private let language = Menu(.language, [
        ("Automatic", "auto"), ("English (US)", "en"), ("English (UK)", "en-gb"), ("French", "fr"),
        ("Spanish", "es"), ("German", "de"), ("Italian", "it"), ("Dutch", "nl"),
        ("Portuguese (Portugal)", "pt"), ("Portuguese (Brazil)", "pt-br"), ("Russian", "ru"),
        ("Japanese", "ja"), ("Korean", "ko"), ("Chinese (Traditional)", "zh-t"),
        ("Chinese (Simplified)", "zh-s"), ("Finnish", "fi"), ("Swedish", "sv"), ("Danish", "da"),
        ("Norwegian", "no"), ("Polish", "pl"), ("Turkish", "tr"),
    ].map { Choice(title: $0.0, value: $0.1) })
    private let audio = Toggle(.audio, "Sound")
    private let fpsButton = NSButton(checkboxWithTitle: "Show FPS", target: nil, action: nil)
    private var shownFPS = false

    private let warning = NSTextField(wrappingLabelWithString:
        "On a Mac that can't hold 60 FPS the game plays in slow motion.")
    private var grid: NSGridView!
    private var warningRow: NSGridRow!
    private let message = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!

    private var menus: [Menu] { [resolution, frameRate, aspect, antialiasing, upscale, anisotropic, language] }
    private var toggles: [Toggle] { [vsync, fullscreen, audio] }

    init(url: URL) {
        self.url = url
        super.init()
        build()
    }

    /// Re-reads the file, because the game's own menu also writes it.
    func present(on window: NSWindow) {
        reload()
        window.beginSheet(panel)
        panel.makeFirstResponder(resolution.button)
    }

    func reload() {
        let file: SettingsFile
        do {
            file = try SettingsFile(contentsOf: url)
            show(nil)
            saveButton.isEnabled = true
        } catch {
            file = SettingsFile()
            show("PAIN couldn't read settings.ini. \(error.localizedDescription)", announce: false)
            saveButton.isEnabled = false
        }
        for menu in menus { select(menu, file.value(menu.setting)) }
        for toggle in toggles {
            toggle.shown = file.value(toggle.setting) == "on"
            toggle.button.state = toggle.shown ? .on : .off
        }
        shownFPS = UserDefaults.standard.bool(forKey: "showFPS")
        fpsButton.state = shownFPS ? .on : .off
        updateWarning(announce: false)
    }

    // MARK: - Layout

    private func build() {
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true

        for menu in menus {
            menu.button.target = self
            menu.button.action = #selector(choiceChanged(_:))
        }

        let rows: [[NSView]] = [
            labelled("Resolution:", resolution.button),
            labelled("Frame rate:", frameRate.button),
            [NSGridCell.emptyContentView, warning],
            [NSGridCell.emptyContentView, vsync.button],
            [NSGridCell.emptyContentView, fullscreen.button],
            labelled("Picture shape:", aspect.button),
            labelled("Anti-aliasing:", antialiasing.button),
            labelled("Upscaling:", upscale.button),
            labelled("Texture filtering:", anisotropic.button),
            labelled("Language:", language.button),
            [NSGridCell.emptyContentView, audio.button],
            [NSGridCell.emptyContentView, fpsButton],
        ]
        grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        warningRow = grid.row(at: 2)
        warningRow.topPadding = -4
        for menu in menus where menu !== language {
            menu.button.widthAnchor.constraint(equalTo: language.button.widthAnchor).isActive = true
        }

        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.isHidden = true

        let reveal = NSButton(title: "Show Settings File", target: self, action: #selector(revealFile))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [reveal, spacer, cancel, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 12

        let layout = NSStackView(views: [grid, message, actions])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 20
        layout.setCustomSpacing(12, after: message)
        layout.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(layout)
        panel.contentView = content
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            actions.widthAnchor.constraint(equalTo: layout.widthAnchor),
            message.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
    }

    /// A label and its pop-up; the label is the pop-up's accessible title.
    private func labelled(_ title: String, _ control: NSPopUpButton) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        control.setAccessibilityTitleUIElement(label)
        return [label, control]
    }

    // MARK: - Values

    private func select(_ menu: Menu, _ value: String) {
        var choices = menu.base
        var index = choices.firstIndex { same(menu.setting, $0.value, value) }
        if index == nil {
            // A valid value the pop-up doesn't list keeps its own item.
            switch menu.setting {
            case .anisotropic:
                let level = Int(SettingsFile.integer(value) ?? 0)
                let at = choices.firstIndex { Int(SettingsFile.integer($0.value) ?? 0) > level } ?? choices.count
                choices.insert(Choice(title: "\(level)×", value: value), at: at)
                index = at
            default:
                choices.append(Choice(title: "Custom (\(value)×)", value: value))
                index = choices.count - 1
            }
        }
        menu.choices = choices
        menu.shown = index!
        menu.button.removeAllItems()
        menu.button.addItems(withTitles: choices.map(\.title))
        menu.button.selectItem(at: menu.shown)
    }

    private func same(_ setting: Setting, _ a: String, _ b: String) -> Bool {
        switch setting {
        case .resScale: return SettingsFile.real(a) == SettingsFile.real(b)
        case .anisotropic: return SettingsFile.integer(a) == SettingsFile.integer(b)
        case .language: return languageID(a) == languageID(b)
        default: return a == b
        }
    }

    private var sixty: Bool { frameRate.choices[frameRate.button.indexOfSelectedItem].value == "60" }

    private func updateWarning(announce: Bool) {
        // Wrap within the pop-ups' column, which the longest language sets.
        warning.preferredMaxLayoutWidth = language.button.intrinsicContentSize.width
        warningRow.isHidden = !sixty
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        if announce && sixty {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: warning.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func show(_ text: String?, announce: Bool = true) {
        message.stringValue = text ?? ""
        message.preferredMaxLayoutWidth = grid.fittingSize.width
        message.isHidden = text == nil
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        if let text, announce {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: - Actions

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        if sender === frameRate.button { updateWarning(announce: true) }
    }

    @objc private func save() {
        var changes: [(Setting, String)] = []
        for menu in menus where menu.button.indexOfSelectedItem != menu.shown {
            changes.append((menu.setting, menu.choices[menu.button.indexOfSelectedItem].value))
        }
        for toggle in toggles where (toggle.button.state == .on) != toggle.shown {
            changes.append((toggle.setting, toggle.button.state == .on ? "on" : "off"))
        }
        if !changes.isEmpty {
            do {
                // Apply to the file as it is now, in case the game wrote it.
                try SettingsFile(contentsOf: url).applying(changes).write(to: url)
            } catch {
                show("PAIN couldn't save settings.ini. \(error.localizedDescription)")
                return
            }
        }
        if (fpsButton.state == .on) != shownFPS {
            UserDefaults.standard.set(fpsButton.state == .on, forKey: "showFPS")
        }
        close()
    }

    @objc private func cancel() { close() }

    private func close() {
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func revealFile() {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // withoutOverwriting: never replace a file the game created meanwhile.
                try Data("[settings]\n".utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                show("PAIN couldn't create settings.ini. \(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
