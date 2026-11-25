// Test-only harness, not shipped: renders the launcher window and the
// Settings sheet to PNG in light and dark appearance, and drives the sheet's
// controls to check what Save writes and how the controls are labelled. The
// controller checks drive ControllerNavigator with synthetic pad input.
// Build and run: macos/tests/render.sh OUTPUT_DIR
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAIN_PREVIEW_DATA_DIR"]!, isDirectory: true)
let settings = state.appendingPathComponent("settings.ini")
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "ok   \(name)" : "FAIL \(name) \(detail())")
    if !ok { failures += 1 }
}

func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

func render(_ view: NSView, _ appearance: NSAppearance, _ name: String) {
    view.window!.appearance = appearance
    view.needsDisplay = true
    view.layoutSubtreeIfNeeded()
    let scale: CGFloat = 2
    let size = view.bounds.size
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    image.size = size
    let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    cached.size = size
    view.cacheDisplay(in: view.bounds, to: cached)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    appearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
    }
    cached.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try! image.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
    print("wrote \(name).png (\(Int(size.width))x\(Int(size.height)) pt)")
}

/// The pop-up whose accessible title is the label with this text.
func popUp(_ panel: NSWindow, _ label: String) -> NSPopUpButton {
    views(in: panel.contentView!).compactMap { $0 as? NSPopUpButton }
        .first { ($0.accessibilityTitleUIElement() as? NSTextField)?.stringValue == label }!
}

func button(_ panel: NSWindow, _ title: String) -> NSButton {
    views(in: panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }!
}

func choose(_ control: NSPopUpButton, _ title: String) {
    control.selectItem(withTitle: title)
    NSApp.sendAction(control.action!, to: control.target, from: control)
}

func contents() -> String? { try? String(contentsOf: settings, encoding: .utf8) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appearances: [(String, NSAppearance)] = [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)]

// MARK: - The launcher window in each state

let launcher = Launcher()

/// A stand-in prepared game. Its disc art is the player's own, copied from
/// PAIN_RENDER_ART (a PS3_GAME folder) into the temporary state, or a plain
/// stand-in image when that is not set; the repository holds no game art.
func makeGame(_ name: String, art: [String]) -> URL {
    let game = state.appendingPathComponent(name, isDirectory: true)
    for file in ["disc/PARAM.SFO", "disc/USRDIR/CacheData.pak", "prepared/EBOOT.elf",
                 "prepared/hdd0/game/BCES00548/USRDIR/CacheFlags/CacheDone.flg"] {
        let url = game.appendingPathComponent(file)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    for file in art {
        let target = game.appendingPathComponent("disc/" + file)
        if let dir = ProcessInfo.processInfo.environment["PAIN_RENDER_ART"] {
            try! FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(file), to: target)
        } else {
            let size = file == "PIC1.PNG" ? NSSize(width: 1920, height: 1080) : NSSize(width: 320, height: 176)
            let image = NSImage(size: size, flipped: false) { rect in
                NSGradient(starting: .darkGray, ending: .lightGray)!.draw(in: rect, angle: -90)
                return true
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try! bitmap.representation(using: .png, properties: [:])!.write(to: target)
        }
    }
    return game
}

func select(_ game: URL?, source: String = "/Users/player/Downloads/PAIN BCES00548.zip") {
    let file = state.appendingPathComponent("selection.json")
    if let game {
        let selection = ["source": source, "disc": game.appendingPathComponent("disc").path,
                         "prepared": game.appendingPathComponent("prepared").path]
        try! JSONSerialization.data(withJSONObject: selection).write(to: file)
    } else {
        try? FileManager.default.removeItem(at: file)
    }
    launcher.refreshSelection()
}

/// Visible text and buttons that don't fit their frames.
func clipped(_ root: NSView) -> [String] {
    views(in: root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { view in
        guard let control = view as? NSControl else { return nil }
        let fits: Bool
        if let field = control as? NSTextField, field.cell?.wraps == true {
            let needed = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: 10_000))
            fits = needed.height <= field.frame.height + 0.5
        } else {
            fits = control.intrinsicContentSize.width <= control.frame.width + 0.5 &&
                (control.intrinsicContentSize.height < 0 || control.intrinsicContentSize.height <= control.frame.height + 0.5)
        }
        return fits ? nil : "\(control.stringValue.isEmpty ? (control as? NSButton)?.title ?? "" : control.stringValue) " +
            "\(control.intrinsicContentSize) in \(control.frame.size)"
    }
}

let withArt = makeGame("game-art", art: ["PIC1.PNG", "ICON0.PNG"])
let iconOnly = makeGame("game-icon", art: ["ICON0.PNG"])
let noArt = makeGame("game-no-art", art: [])
var spoken: [String] = []
launcher.announce = { text, urgent in spoken.append((urgent ? "! " : "") + text) }
try! JSONSerialization.data(withJSONObject: ["source": "/Users/player/Downloads/PAIN BCES00548.zip",
    "disc": withArt.appendingPathComponent("disc").path, "prepared": withArt.appendingPathComponent("prepared").path])
    .write(to: state.appendingPathComponent("selection.json"))
launcher.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
let main = NSApp.windows.first { $0.title == "PAIN" }!
main.orderOut(nil)
let settingsButton = views(in: main.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Settings…" }
check("main window has an enabled Settings… button", settingsButton?.isEnabled == true)
check("Show FPS left the main window",
      !views(in: main.contentView!).contains { ($0 as? NSButton)?.title == "Show FPS" })

func waitFor(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}
let mainButton = { (title: String) in views(in: main.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }! }
let play = mainButton("Play")
let banner = views(in: main.contentView!).compactMap { $0 as? BannerView }.first!
let bar = views(in: main.contentView!).compactMap { $0 as? NSProgressIndicator }.first { !$0.isIndeterminate }!
let activity = views(in: main.contentView!).compactMap { $0 as? NSProgressIndicator }.first { $0.isIndeterminate }!
func shown(_ text: String) -> Bool {
    views(in: main.contentView!).contains { ($0 as? NSTextField)?.stringValue == text && !$0.isHiddenOrHasHiddenAncestor }
}
/// Renders the main window in both appearances and checks its text fits.
func renderMain(_ name: String) {
    // The bar animates to a new value.
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    main.contentView!.layoutSubtreeIfNeeded()
    for (appearanceName, appearance) in appearances {
        main.appearance = appearance
        main.contentView!.layoutSubtreeIfNeeded()
        check("no clipped text, \(name) \(appearanceName)", clipped(main.contentView!).isEmpty,
              clipped(main.contentView!).joined(separator: "; "))
        render(main.contentView!, appearance, "main-\(name)-\(appearanceName)")
    }
    main.appearance = nil
}

check("the banner is up when the window opens, before the art is decoded", !banner.isHidden && banner.frame.height == 240)
check("the art arrives off the main thread", waitFor { banner.art != nil })
check("PIC1 fills the banner", banner.art?.fills == true && banner.art?.image.width == 1280)
let dockIcon = state.appendingPathComponent("Dock Icon.png")
check("a Dock icon made from ICON0", FileManager.default.fileExists(atPath: dockIcon.path) &&
      NSApp.applicationIconImage?.size == NSSize(width: 512, height: 512))
try? FileManager.default.copyItem(at: dockIcon, to: out.appendingPathComponent("dock-icon.png"))
check("Play's bezel is the darkened accent", play.bezelColor === Launcher.defaultBezel && mainButton("Choose Game…").bezelColor == nil)
renderMain("idle")
let fullHeight = main.frame.height
print("main window: \(Int(main.frame.width)) x \(Int(fullHeight)) pt with the banner")
check("Play is the default button, large, and enabled", play.keyEquivalent == "\r" && play.controlSize == .large &&
      play.isEnabled && mainButton("Choose Game…").keyEquivalent.isEmpty)
check("Escape is on no button", !views(in: main.contentView!).contains { ($0 as? NSButton)?.keyEquivalent == "\u{1b}" })
check("idle: title and disc ID, nothing else", shown("PAIN") && shown("BCES00548") && launcher.status == .title)
check("the chosen file is on Choose Game…", mainButton("Choose Game…").toolTip == "/Users/player/Downloads/PAIN BCES00548.zip" &&
      mainButton("Choose Game…").accessibilityHelp() == "Current game: PAIN BCES00548.zip")
var keyLoop: [String] = []
var key: NSView? = main.initialFirstResponder
while let current = key as? NSButton, !keyLoop.contains(current.title) { keyLoop.append(current.title); key = current.nextKeyView }
check("Tab starts at Play and runs the row", keyLoop == ["Play", "Choose Game…", "Settings…", "Show Log"], keyLoop.joined(separator: ", "))
check("every main window control has an accessibility label", views(in: main.contentView!).compactMap { $0 as? NSButton }
      .allSatisfy { !($0.accessibilityLabel() ?? $0.title).isEmpty })

select(iconOnly)
check("ICON0 when there is no PIC1", waitFor { banner.art?.fills == false })
renderMain("idle-icon0")
check("ICON0 keeps the banner's height", main.frame.height == fullHeight)

select(noArt)
check("no art: no banner", banner.isHidden && banner.art == nil)
check("no art: no Dock icon left from the last disc", !FileManager.default.fileExists(atPath: dockIcon.path))
renderMain("idle-no-art")
let compactHeight = main.frame.height
print("main window without art: \(Int(compactHeight)) pt")
launcher.show(.problem("PAIN closed during launch or play (code 9). Open the log for details."))
check("no art: an error keeps the height", main.frame.height == compactHeight)
renderMain("error-no-art")

select(nil)
check("no game: Choose Game… takes Return and Play is off", mainButton("Choose Game…").keyEquivalent == "\r" &&
      play.keyEquivalent.isEmpty && !play.isEnabled && shown("No game chosen"))
renderMain("no-game")

// Play, with a stand-in game that writes what the real one writes, one step at a time.
select(withArt)
_ = waitFor { banner.art != nil }
let gameHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PAIN.app/Contents/MacOS/PainRecomp")
try! FileManager.default.createDirectory(at: gameHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
let steps = """
    #!/bin/sh
    step() { until [ -e "$PAIN_PREVIEW_DATA_DIR/step$1" ]; do sleep 0.05; done; }
    echo "icon=$PS3RECOMP_APP_ICON"
    step 1; echo "[shader-prep] Preparing shaders (80 of 163)" >&2; echo "[shader-prep] Preparing shaders (96 of 163)" >&2
    step 2; echo "[shader-prep] Prepared 163 of 163 Metal pipelines before Play (shipped 150 of 150, learned 13 of 13) in 20113 ms" >&2
    step 3; echo "[rsx] Metal backend init OK -- window open" >&2
    step 4; exit 9

    """
try! steps.write(to: gameHelper, atomically: true, encoding: .utf8)
chmod(gameHelper.path, 0o755)
func step(_ n: Int) { FileManager.default.createFile(atPath: state.appendingPathComponent("step\(n)").path, contents: Data()) }
spoken = []
play.performClick(nil)
check("Play: Starting…, indeterminate", launcher.status == .progress("Starting…") && bar.isHiddenOrHasHiddenAncestor &&
      activity.accessibilityLabel() == "Starting" && !activity.isHiddenOrHasHiddenAncestor)
check("loading: Play, Choose Game… and Settings… are off; Show Log is on", !play.isEnabled &&
      !mainButton("Choose Game…").isEnabled && !mainButton("Settings…").isEnabled && mainButton("Show Log").isEnabled)
check("loading: the title gives way to the progress", !shown("PAIN") && shown("Starting…"))
renderMain("starting")
check("starting keeps the window's height", main.frame.height == fullHeight)
step(1)
check("the count is read from the log", waitFor { launcher.status == .progress("Preparing shaders", done: 96, total: 163) })
check("a determinate bar with its count", !bar.isHiddenOrHasHiddenAncestor && activity.isHiddenOrHasHiddenAncestor &&
      bar.doubleValue == 96 && bar.maxValue == 163 &&
      shown("Preparing shaders") && shown("96 of 163"))
check("the bar's accessibility label and value", bar.accessibilityLabel() == "Preparing shaders" &&
      bar.accessibilityValueDescription() == "96 of 163", "\(bar.accessibilityLabel() ?? "nil") \(bar.accessibilityValueDescription() ?? "nil")")
renderMain("preparing")
check("preparing keeps the window's height", main.frame.height == fullHeight)
check("VoiceOver hears the start and the first count, not every count",
      spoken == ["Starting", "Preparing shaders, 80 of 163"], spoken.joined(separator: " | "))
step(2)
check("after the last count: Starting… again", waitFor { launcher.status == .progress("Starting…") } &&
      !activity.isHiddenOrHasHiddenAncestor && bar.isHiddenOrHasHiddenAncestor)
check("the game gets the Dock icon", (try? String(contentsOf: state.appendingPathComponent("logs/game.log"), encoding: .utf8))?
      .contains("icon=" + state.appendingPathComponent("Dock Icon.png").path) == true)
// As the app runs: a regular app with its window up.
NSApp.setActivationPolicy(.regular)
main.orderFront(nil)
step(3)
check("the window hides and leaves the Dock when the game's window opens",
      waitFor { !main.isVisible } && NSApp.activationPolicy() == .accessory)
check("the app stays while the game runs with no window",
      launcher.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)
step(4)
check("the window comes back, in the Dock, when the game ends", waitFor { play.isEnabled } && main.isVisible &&
      NSApp.activationPolicy() == .regular)
check("a failed run says so", launcher.status == .problem(
    "PAIN closed during launch or play (code 9). Open the log for details."))
check("errors are announced at once", spoken.last == "! PAIN closed during launch or play (code 9). Open the log for details.",
      spoken.joined(separator: " | "))
renderMain("error")
check("an error keeps the window's height", main.frame.height == fullHeight)
for n in 1...4 { try? FileManager.default.removeItem(at: state.appendingPathComponent("step\(n)")) }

// Import, with a stand-in importer that fails with a long message.
let python = Bundle.main.resourceURL!.appendingPathComponent("Python/bin/python3")
try! FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
try! """
    #!/bin/sh
    until [ -e "$PAIN_PREVIEW_DATA_DIR/import-done" ]; do sleep 0.05; done
    echo "Error: The selected ZIP holds BLES00123, not PAIN (BCES00548). Choose the PAIN disc ZIP or the folder extracted from it, with PS3_GAME and PS3_DISC.SFB at its top level, then try again."
    exit 1

    """.write(to: python, atomically: true, encoding: .utf8)
chmod(python.path, 0o755)
launcher.importGame(URL(fileURLWithPath: "/Users/player/Downloads/Some Other Game.zip"))
check("import: the same progress, indeterminate", launcher.status == .progress("Checking and preparing the selected files…") &&
      !activity.isHiddenOrHasHiddenAncestor && !play.isEnabled && !mainButton("Choose Game…").isEnabled)
renderMain("importing")
check("importing keeps the window's height", main.frame.height == fullHeight)
FileManager.default.createFile(atPath: state.appendingPathComponent("import-done").path, contents: Data())
check("a long import error is shown whole, without its Error: prefix",
      waitFor { if case .problem = launcher.status { return true }; return false } &&
      shown("The selected ZIP holds BLES00123, not PAIN (BCES00548). Choose the PAIN disc ZIP or the folder extracted " +
            "from it, with PS3_GAME and PS3_DISC.SFB at its top level, then try again."))
renderMain("error-long")
check("a long error keeps the window's height", main.frame.height == fullHeight)
launcher.refreshSelection()

// The sheet over a missing file: defaults, and Save writes nothing.
try? FileManager.default.removeItem(at: settings)
let sheet = SettingsSheet(url: settings)
let panel = sheet.panel
sheet.reload()
let fpsBefore = UserDefaults.standard.object(forKey: "showFPS")
button(panel, "Save").performClick(nil)
check("Save with no changes creates no file", contents() == nil)
check("Save with no changes leaves Show FPS alone", UserDefaults.standard.object(forKey: "showFPS") as? Bool == fpsBefore as? Bool)

let labels = ["Resolution:", "Frame rate:", "Picture shape:", "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:",
              "Vibration:", "Stick dead zone:", "Shake button:"]
check("every pop-up's accessible title is its visible label",
      labels.allSatisfy { label in views(in: panel.contentView!).contains {
          ($0 as? NSPopUpButton)?.accessibilityTitleUIElement() as? NSTextField != nil &&
          (($0 as! NSPopUpButton).accessibilityTitleUIElement() as! NSTextField).stringValue == label } } &&
      views(in: panel.contentView!).filter { $0 is NSPopUpButton }.count == labels.count)
check("defaults shown", popUp(panel, "Resolution:").titleOfSelectedItem == "1280 × 720" &&
      popUp(panel, "Frame rate:").titleOfSelectedItem == "30 FPS" && popUp(panel, "Language:").titleOfSelectedItem == "Automatic" &&
      button(panel, "V-Sync").state == .on && button(panel, "Even frame pacing").state == .on &&
      button(panel, "Sound").state == .on && button(panel, "Full screen").state == .off &&
      popUp(panel, "Vibration:").titleOfSelectedItem == "100%" && popUp(panel, "Stick dead zone:").titleOfSelectedItem == "10%" &&
      button(panel, "Hold PS or Start+Select to quit").state == .on && button(panel, "Motion").state == .on &&
      popUp(panel, "Shake button:").titleOfSelectedItem == "Off" &&
      popUp(panel, "Shake button:").itemTitles == ["Off", "L3", "R3", "Touchpad"])

// Tab order: the key view loop from the first control.
panel.recalculateKeyViewLoop()
var order: [String] = []
var view: NSView? = popUp(panel, "Resolution:")
// Labels and AppKit's own hosting views sit in the loop too; they never take focus.
for _ in 0..<200 {
    guard let current = view else { break }
    let name = (current as? NSPopUpButton).flatMap { ($0.accessibilityTitleUIElement() as? NSTextField)?.stringValue }
        ?? (current as? NSButton)?.title
    if let name {
        if order.first == name { break }
        order.append(name)
    }
    view = current.nextKeyView
}
print("tab order: " + order.joined(separator: " → "))
let tabOrder = ["Resolution:", "Frame rate:", "V-Sync", "Even frame pacing", "Full screen", "Picture shape:",
      "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:", "Sound", "Show FPS",
      "Vibration:", "Stick dead zone:", "Hold PS or Start+Select to quit", "Motion", "Shake button:",
      "Show Settings File", "Cancel", "Save"]
check("tab order runs top to bottom", order == tabOrder, order.joined(separator: ", "))
check("Return saves and Escape cancels", button(panel, "Save").keyEquivalent == "\r" && button(panel, "Cancel").keyEquivalent == "\u{1b}")

func truncated() -> [String] {
    views(in: panel.contentView!).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { view in
        guard let control = view as? NSControl, !(control is NSPopUpButton) else { return nil }
        let fits = control.intrinsicContentSize.width <= control.frame.width + 0.5 &&
            (control.intrinsicContentSize.height < 0 || control.intrinsicContentSize.height <= control.frame.height + 0.5)
        return fits ? nil : "\(control.stringValue.isEmpty ? (control as? NSButton)?.title ?? "" : control.stringValue) " +
            "\(control.intrinsicContentSize) in \(control.frame.size)"
    } + views(in: panel.contentView!).compactMap { $0 as? NSPopUpButton }.compactMap { control in
        control.itemArray.map { item -> CGFloat in
            let cell = control.cell!.copy() as! NSPopUpButtonCell
            cell.removeAllItems(); cell.addItem(withTitle: item.title)
            return cell.cellSize.width
        }.max()! <= control.frame.width + 0.5 ? nil : "pop-up \(control.titleOfSelectedItem ?? "") too narrow"
    }
}

for (name, appearance) in appearances {
    panel.appearance = appearance
    sheet.reload()
    panel.contentView!.layoutSubtreeIfNeeded()
    check("no truncated text, defaults \(name)", truncated().isEmpty, truncated().joined(separator: "; "))
    render(panel.contentView!, appearance, "settings-defaults-\(name)")
}

// 60 FPS shows the warning line; 30 hides it again.
let warning = views(in: panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("On a Mac") }!
sheet.reload()
check("warning hidden at 30 FPS", warning.isHiddenOrHasHiddenAncestor)
choose(popUp(panel, "Frame rate:"), "60 FPS")
check("warning shown at 60 FPS", !warning.isHiddenOrHasHiddenAncestor)
choose(popUp(panel, "Frame rate:"), "30 FPS")
check("warning hidden again at 30 FPS", warning.isHiddenOrHasHiddenAncestor)
for (name, appearance) in appearances {
    panel.appearance = appearance
    sheet.reload()
    choose(popUp(panel, "Frame rate:"), "60 FPS")
    panel.contentView!.layoutSubtreeIfNeeded()
    check("no truncated text, 60 FPS \(name)", truncated().isEmpty, truncated().joined(separator: "; "))
    render(panel.contentView!, appearance, "settings-60fps-\(name)")
}
panel.appearance = nil

// Save writes only what changed.
sheet.reload()
choose(popUp(panel, "Resolution:"), "1920 × 1080")
button(panel, "Save").performClick(nil)
check("Save writes only the changed key", contents() == "[settings]\nres_scale = 1.5\n", contents()?.debugDescription ?? "nil")

// An existing file: shown values, custom items, in-place edits, overrides.
let existing = "; mine\n[settings]\nres_scale = 1.25 ; custom\nvsync = no\nanisotropic = 6\nlanguage = 18\n" +
    "vblank_ms = 10\n; sim_steps = 1\n[other]\naa = smaa\n"
try! existing.write(to: settings, atomically: true, encoding: .utf8)
sheet.reload()
check("existing values shown", popUp(panel, "Resolution:").titleOfSelectedItem == "Custom (1.25×)" &&
      button(panel, "V-Sync").state == .off && popUp(panel, "Texture filtering:").titleOfSelectedItem == "6×" &&
      popUp(panel, "Texture filtering:").itemTitles == ["Off", "2×", "4×", "6×", "8×", "16×"] &&
      popUp(panel, "Language:").titleOfSelectedItem == "English (UK)" &&
      popUp(panel, "Anti-aliasing:").titleOfSelectedItem == "Off")
button(panel, "Save").performClick(nil)
check("Save with no changes leaves an existing file byte for byte", contents() == existing)
sheet.reload()
choose(popUp(panel, "Frame rate:"), "60 FPS")
button(panel, "Sound").performClick(nil)
button(panel, "Save").performClick(nil)
check("frame rate and sound saved; vblank_ms commented out; the rest untouched",
      contents() == "; mine\n[settings]\nres_scale = 1.25 ; custom\nvsync = no\nanisotropic = 6\nlanguage = 18\n" +
      "; vblank_ms = 10\n; sim_steps = 1\nframe_rate = 60\naudio = off\n[other]\naa = smaa\n", contents()?.debugDescription ?? "nil")

// A file the launcher can't read: the error is shown inline and Save is off.
try! FileManager.default.removeItem(at: settings)
try! FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
panel.appearance = appearances[0].1
sheet.reload()
let message = views(in: panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("PAIN couldn't") }
check("read error shown inline with Save disabled", message.map { !$0.isHiddenOrHasHiddenAncestor } == true &&
      !button(panel, "Save").isEnabled, message?.stringValue ?? "no message")
check("no truncated text, read error", truncated().isEmpty, truncated().joined(separator: "; "))
render(panel.contentView!, appearances[0].1, "settings-read-error-light")
try! FileManager.default.removeItem(at: settings)

// MARK: - Controller navigation, driven with synthetic input

/// A control's name as the checks use it: a pop-up's label, else its title.
func name(_ responder: NSResponder?) -> String {
    if let popUp = responder as? NSPopUpButton { return (popUp.accessibilityTitleUIElement() as? NSTextField)?.stringValue ?? "?" }
    return (responder as? NSButton)?.title ?? "none"
}

extension NSView {
    var lastBaselineAnchorY: CGFloat { convert(NSPoint(x: 0, y: isFlipped ? bounds.height - lastBaselineOffsetFromBottom : lastBaselineOffsetFromBottom), to: nil).y }
}

/// Contrast ratio of two colours as drawn in an appearance (WCAG 2 formula).
func contrast(_ a: NSColor, on b: NSColor, _ appearance: NSAppearance) -> Double {
    var ratio = 0.0
    appearance.performAsCurrentDrawingAppearance {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func channel(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
        }
        // A translucent colour is drawn over the background.
        let top = a.usingColorSpace(.sRGB)!, bottom = b.usingColorSpace(.sRGB)!
        let alpha = top.alphaComponent
        let blended = NSColor(srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
                              green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
                              blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha), alpha: 1)
        let (l1, l2) = (luminance(blended), luminance(bottom))
        ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
    return ratio
}

// The game is a stand-in that exits after a second.
let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PAIN.app/Contents/MacOS/PainRecomp")
try! FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
try! "#!/bin/sh\nexec sleep 1\n".write(to: helper, atomically: true, encoding: .utf8)
chmod(helper.path, 0o755)

let nav = launcher.navigator
var active = true
var pad = PadState()
var now: TimeInterval = 1000
nav.isActive = { active }
nav.readPad = { pad }
nav.clock = { now }
func running() -> Bool { !play.isEnabled && !mainButton("Settings…").isEnabled }
/// One pad reading at the next instant.
func send(_ state: PadState, after seconds: TimeInterval = 0.02) {
    now += seconds
    pad = state
    nav.update(state, at: now)
}

nav.refresh()
// The window opens with Play focused for Tab; the controller's first push shows where it is.
main.makeFirstResponder(nil)
check("controller armed once the pad is seen released", nav.armed)
check("first direction focuses Play on the main window", nav.perform(.down) && name(main.firstResponder) == "Play",
      name(main.firstResponder))
var mainOrder = [name(main.firstResponder)]
while nav.perform(.left) { mainOrder.append(name(main.firstResponder)) }
check("main window focus order visits every control once", Array(mainOrder.reversed()) == ["Choose Game…", "Settings…", "Show Log", "Play"],
      mainOrder.joined(separator: ", "))
var downOrder = [name(main.firstResponder)]
while nav.perform(.down) { downOrder.append(name(main.firstResponder)) }
check("Down walks the same order", downOrder == ["Choose Game…", "Settings…", "Show Log", "Play"], downOrder.joined(separator: ", "))
check("Circle does nothing on the main window", !nav.perform(.cancel))

// Stick threshold, hysteresis and repeat (synthetic clock).
send(PadState())
send(PadState(x: -0.45))
check("stick below the threshold does nothing", name(main.firstResponder) == "Play")
send(PadState(x: -0.6))
check("stick past the threshold moves once", name(main.firstResponder) == "Show Log", name(main.firstResponder))
send(PadState(x: -0.35), after: 0.1)
send(PadState(x: -0.55), after: 0.1)
check("wobbling above the release point is one push", name(main.firstResponder) == "Show Log", name(main.firstResponder))
nav.tick(at: now + 0.1)
check("no repeat before the delay", name(main.firstResponder) == "Show Log")
now += 0.25
nav.tick(at: now)
check("repeat after the delay", name(main.firstResponder) == "Settings…", name(main.firstResponder))
now += ControllerNavigator.repeatInterval
nav.tick(at: now)
check("repeat continues at the interval", name(main.firstResponder) == "Choose Game…", name(main.firstResponder))
send(PadState(x: -0.2))
send(PadState(y: -1))
send(PadState(y: -1), after: 0.1)
check("d-pad Down moves once per press", name(main.firstResponder) == "Settings…", name(main.firstResponder))
send(PadState())
send(PadState(x: 1)); send(PadState())
check("d-pad Right moves once", name(main.firstResponder) == "Show Log", name(main.firstResponder))

// Status line and focus ring on the main window.
main.contentView!.layoutSubtreeIfNeeded()
let layoutViews = views(in: main.contentView!).filter { $0 is NSButton || ($0 as? NSTextField)?.stringValue.isEmpty == false }
let framesBefore = layoutViews.map { $0.convert($0.bounds, to: nil) }
let status = ControllerInput.describe(name: "DualSense Wireless Controller", level: 0.8, state: .discharging)
launcher.showController(status)
main.contentView!.layoutSubtreeIfNeeded()
let statusLine = views(in: main.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == status.text }
check("status line shows name and battery", status.text == "DualSense Wireless Controller · 80% battery" &&
      statusLine.map { !$0.isHiddenOrHasHiddenAncestor } == true, status.text)
check("status line is an accessibility element with a label",
      statusLine?.isAccessibilityElement() == true &&
      statusLine?.accessibilityLabel() == "Controller connected: DualSense Wireless Controller, 80% battery",
      statusLine?.accessibilityLabel() ?? "nil")
check("status line moves nothing", layoutViews.map { $0.convert($0.bounds, to: nil) } == framesBefore)
check("the controller line keeps the window's height", main.frame.height == fullHeight)
check("the controller line sits on the disc ID's baseline, at the right",
      statusLine.map { abs($0.lastBaselineAnchorY - views(in: main.contentView!).compactMap { $0 as? NSTextField }
          .first { $0.stringValue == "BCES00548" }!.lastBaselineAnchorY) < 0.5 } == true)
check("battery wording", ControllerInput.describe(name: "Pad", level: 0.5, state: .charging).text == "Pad · 50% battery, charging" &&
      ControllerInput.describe(name: "Pad", level: 1, state: .full).text == "Pad · battery full" &&
      ControllerInput.describe(name: "Pad", level: 0, state: .unknown).text == "Pad" &&
      ControllerInput.describe(name: nil, level: nil, state: .unknown).text == "Controller")
check("focus ring view takes no clicks or accessibility focus",
      views(in: main.contentView!).compactMap { $0 as? FocusRingView }.first.map {
          $0.hitTest(NSPoint(x: 100, y: 50)) == nil && !$0.isAccessibilityElement() && !$0.acceptsFirstResponder } == true)
renderMain("controller")
for (appearanceName, appearance) in appearances {
    let background = NSColor.windowBackgroundColor
    let text = contrast(statusLine!.textColor!, on: background, appearance)
    let title = contrast(.labelColor, on: background, appearance)
    let ring = contrast(.controlAccentColor, on: background, appearance)
    let warning = contrast(.systemRed, on: background, appearance)
    let playText = contrast(.white, on: Launcher.defaultBezel, appearance)
    var accentFraction = 0
    appearance.performAsCurrentDrawingAppearance {
        accentFraction = Int((Launcher.darkened(NSColor.controlAccentColor.usingColorSpace(.sRGB)!).fraction * 100).rounded())
    }
    print(String(format: "contrast \(appearanceName): title and messages %.2f:1, secondary text (disc ID, count, controller) %.2f:1, " +
                 "focus ring %.2f:1, error sign %.2f:1; secondaryLabelColor would be %.2f:1; Play's title on its bezel %.2f:1 " +
                 "(on the plain accent %.2f:1, darkened %d%%)", title, text, ring, warning, contrast(.secondaryLabelColor, on: background, appearance),
                 playText, contrast(.white, on: .controlAccentColor, appearance), accentFraction))
    check("text at least 4.5:1, focus ring and error sign at least 3:1, \(appearanceName)",
          text >= 4.5 && title >= 4.5 && ring >= 3 && warning >= 3 && playText >= 4.5)
}
// The other accent colours (the system colours they follow), and Increase Contrast.
for (appearanceName, appearance) in appearances + [
    ("light, increased contrast", NSAppearance(named: .accessibilityHighContrastAqua)!),
    ("dark, increased contrast", NSAppearance(named: .accessibilityHighContrastDarkAqua)!)] {
    var row: [String] = []
    for (accentName, accent) in [("blue", NSColor.systemBlue), ("purple", .systemPurple), ("pink", .systemPink), ("red", .systemRed),
                                 ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen),
                                 ("graphite", .systemGray)] {
        var resolved = accent
        appearance.performAsCurrentDrawingAppearance { resolved = accent.usingColorSpace(.sRGB)! }
        let (bezel, fraction) = Launcher.darkened(resolved)
        let before = contrast(.white, on: resolved, appearance), after = contrast(.white, on: bezel, appearance)
        row.append(String(format: "%@ %.2f→%.2f (%d%% darker)", accentName, before, after, Int((fraction * 100).rounded())))
        check("white on the \(accentName) default button at least 4.5:1, \(appearanceName)", after >= 4.5)
    }
    print("Play bezel \(appearanceName): " + row.joined(separator: ", "))
}
launcher.showController(nil)
check("no controller: no status line", statusLine?.isHiddenOrHasHiddenAncestor == true)

// Options plays; input is ignored while the game runs; a held Cross after the game does nothing until released.
send(PadState())
send(PadState(options: true))
check("Options starts the game from the main window", running())
send(PadState())
check("disarmed while the game runs", !nav.armed)
let focusWhileRunning = main.firstResponder
check("actions ignored while the game runs", !nav.perform(.left) && !nav.perform(.play) && !nav.perform(.activate) &&
      main.firstResponder === focusWhileRunning)
send(PadState(x: -1))
check("pad ignored while the game runs", main.firstResponder === focusWhileRunning)
pad = PadState(cross: true)
check("the stand-in game exits", waitFor { !running() })
check("Cross held through the game's exit does not arm", !nav.armed)
send(PadState(cross: true), after: 0.1)
check("held Cross does not restart the game", !running())
send(PadState())
check("released: armed", nav.armed)
check("Play focused for the next check", name(main.firstResponder) == "Play" || (nav.perform(.right) && name(main.firstResponder) == "Play"))
send(PadState(cross: true))
check("a fresh Cross press after the release activates Play", running())
pad = PadState()
check("the stand-in game exits again", waitFor { !running() })
check("armed after the game when nothing is held", nav.armed)

// Not the active app: nothing counts, and coming back needs a release.
active = false
check("actions ignored while inactive", !nav.perform(.left) && !nav.perform(.play))
send(PadState(cross: true))
check("pad ignored while inactive", !running() && !nav.armed)
active = true
nav.refresh()
check("active again with Cross held: not armed", !nav.armed)
send(PadState())
check("active again after a release: armed", nav.armed)

// The Settings sheet, through its own navigator over the same controls.
let sheetNav = ControllerNavigator()
sheetNav.isActive = { true }
sheetNav.screen = { sheet.controllerScreen }
try? FileManager.default.removeItem(at: settings)
panel.appearance = nil
sheet.reload()
panel.makeFirstResponder(popUp(panel, "Resolution:"))
var sheetOrder = [name(panel.firstResponder)]
while sheetNav.perform(.down) { sheetOrder.append(name(panel.firstResponder)) }
check("sheet focus order visits every control once, as Tab does", sheetOrder == tabOrder && Set(sheetOrder).count == tabOrder.count,
      sheetOrder.joined(separator: ", "))
var upOrder = [name(panel.firstResponder)]
while sheetNav.perform(.up) { upOrder.append(name(panel.firstResponder)) }
check("Up walks back to the top", upOrder == tabOrder.reversed(), upOrder.joined(separator: ", "))
func focus(_ label: String) {
    while name(panel.firstResponder) != label && sheetNav.perform(.down) {}
    while name(panel.firstResponder) != label && sheetNav.perform(.up) {}
}
focus("Frame rate:")
check("Right changes the pop-up in place and shows the 60 FPS warning",
      sheetNav.perform(.right) && popUp(panel, "Frame rate:").titleOfSelectedItem == "60 FPS" && !warning.isHiddenOrHasHiddenAncestor)
check("Right at the last item does nothing", !sheetNav.perform(.right))
check("Left changes it back and hides the warning",
      sheetNav.perform(.left) && popUp(panel, "Frame rate:").titleOfSelectedItem == "30 FPS" && warning.isHiddenOrHasHiddenAncestor)
check("Cross on a pop-up does not open its menu", !sheetNav.perform(.activate) && name(panel.firstResponder) == "Frame rate:")
focus("Sound")
check("Cross toggles a checkbox", sheetNav.perform(.activate) && button(panel, "Sound").state == .off)
focus("Vibration:")
check("Vibration Left", sheetNav.perform(.left) && popUp(panel, "Vibration:").titleOfSelectedItem == "75%")
focus("Stick dead zone:")
check("Stick dead zone Right", sheetNav.perform(.right) && popUp(panel, "Stick dead zone:").titleOfSelectedItem == "15%")
focus("Hold PS or Start+Select to quit")
check("quit checkbox toggles", sheetNav.perform(.activate) && button(panel, "Hold PS or Start+Select to quit").state == .off)
check("Down from the quit checkbox reaches Motion", sheetNav.perform(.down) && name(panel.firstResponder) == "Motion")
check("Motion toggles", sheetNav.perform(.activate) && button(panel, "Motion").state == .off)
check("Down from Motion reaches Shake button", sheetNav.perform(.down) && name(panel.firstResponder) == "Shake button:")
check("Shake button Right, Right", sheetNav.perform(.right) && sheetNav.perform(.right) &&
      popUp(panel, "Shake button:").titleOfSelectedItem == "R3")
check("Shake button Right to Touchpad, then the end", sheetNav.perform(.right) &&
      popUp(panel, "Shake button:").titleOfSelectedItem == "Touchpad" && !sheetNav.perform(.right))
check("Shake button Left", sheetNav.perform(.left) && popUp(panel, "Shake button:").titleOfSelectedItem == "R3")
check("Down from Shake button reaches Show Settings File", sheetNav.perform(.down) &&
      name(panel.firstResponder) == "Show Settings File")
focus("Save")
check("Cross on Save", sheetNav.perform(.activate))
let saved = "[settings]\nvibration = 75\nstick_deadzone = 15\nshake_button = r3\naudio = off\ncontroller_quit = off\nmotion = off\n"
check("Save by controller writes exactly the changed keys", contents() == saved, contents()?.debugDescription ?? "nil")
sheet.reload()
focus("Vibration:")
sheetNav.perform(.left)
check("Circle cancels", sheetNav.perform(.cancel))
check("Cancel by controller writes nothing", contents() == saved, contents()?.debugDescription ?? "nil")

// Custom values keep their own items and are not rewritten.
try! "[settings]\nvibration = 40\nstick_deadzone = 7\n".write(to: settings, atomically: true, encoding: .utf8)
sheet.reload()
check("custom controller values shown as their own items",
      popUp(panel, "Vibration:").itemTitles == ["Off", "25%", "40%", "50%", "75%", "100%"] &&
      popUp(panel, "Vibration:").titleOfSelectedItem == "40%" &&
      popUp(panel, "Stick dead zone:").itemTitles == ["Off", "5%", "7%", "10%", "15%", "20%", "30%"] &&
      popUp(panel, "Stick dead zone:").titleOfSelectedItem == "7%",
      "\(popUp(panel, "Vibration:").itemTitles) \(popUp(panel, "Stick dead zone:").itemTitles)")
button(panel, "Hold PS or Start+Select to quit").performClick(nil)
button(panel, "Save").performClick(nil)
check("custom values kept when another key changes",
      contents() == "[settings]\nvibration = 40\nstick_deadzone = 7\ncontroller_quit = off\n", contents()?.debugDescription ?? "nil")

// Keyboard behaviour after the focus ring was added.
check("the focus ring view is in the sheet", views(in: panel.contentView!).contains { $0 is FocusRingView })
panel.recalculateKeyViewLoop()
var loop: [String] = []
var next: NSView? = popUp(panel, "Resolution:")
for _ in 0..<200 {
    guard let current = next else { break }
    if current is NSPopUpButton || current is NSButton {
        if loop.first == name(current) { break }
        loop.append(name(current))
    }
    next = current.nextKeyView
}
check("tab order unchanged with the focus ring", loop == tabOrder, loop.joined(separator: ", "))
check("Return still saves and Escape still cancels", button(panel, "Save").keyEquivalent == "\r" &&
      button(panel, "Cancel").keyEquivalent == "\u{1b}" && play.keyEquivalent == "\r")

// The sheet with focus on Vibration, and its height against a 13-inch display.
try? FileManager.default.removeItem(at: settings)
for (appearanceName, appearance) in appearances {
    panel.appearance = appearance
    sheet.reload()
    panel.makeFirstResponder(popUp(panel, "Resolution:"))
    focus("Vibration:")
    sheetNav.perform(.left)
    sheetNav.perform(.right)
    panel.contentView!.layoutSubtreeIfNeeded()
    check("no truncated text, controller section \(appearanceName)", truncated().isEmpty, truncated().joined(separator: "; "))
    render(panel.contentView!, appearance, "settings-controller-\(appearanceName)")
}
choose(popUp(panel, "Frame rate:"), "60 FPS")
panel.contentView!.layoutSubtreeIfNeeded()
let tallest = panel.contentView!.fittingSize.height
print("sheet height with the 60 FPS warning: \(Int(tallest)) pt")
// A 13-inch MacBook Air at its default scale is 900 pt (older) or 956 pt tall; leave room for the menu bar and title bar.
check("sheet fits a 13-inch display at default scale", tallest <= 900 - 40 - 28 - 40)
panel.appearance = nil

// With no game running the launcher quits at once (with one, it waits for the game: checked on a Mac with the real game).
check("quit with no game running is immediate", launcher.applicationShouldTerminate(NSApp) == .terminateNow)

print("\(failures) render harness checks failed")
exit(failures == 0 ? 0 : 1)
