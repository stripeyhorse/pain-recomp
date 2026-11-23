// Test-only harness, not shipped: renders the launcher window and the
// Settings sheet to PNG in light and dark appearance, and drives the sheet's
// controls to check what Save writes and how the controls are labelled.
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

// The launcher window, ready to play: a stand-in prepared game.
let game = state.appendingPathComponent("fake-game", isDirectory: true)
for file in ["disc/PARAM.SFO", "disc/USRDIR/CacheData.pak", "prepared/EBOOT.elf",
             "prepared/hdd0/game/BCES00548/USRDIR/CacheFlags/CacheDone.flg"] {
    let url = game.appendingPathComponent(file)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}
let selection = ["source": "/Users/player/Downloads/PAIN BCES00548.zip",
                 "disc": game.appendingPathComponent("disc").path, "prepared": game.appendingPathComponent("prepared").path]
try! JSONSerialization.data(withJSONObject: selection).write(to: state.appendingPathComponent("selection.json"))
let launcher = Launcher()
launcher.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
let main = NSApp.windows.first { $0.title == "PAIN" }!
main.orderOut(nil)
let settingsButton = views(in: main.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Settings…" }
check("main window has an enabled Settings… button", settingsButton?.isEnabled == true)
check("Show FPS left the main window",
      !views(in: main.contentView!).contains { ($0 as? NSButton)?.title == "Show FPS" })
for (name, appearance) in appearances {
    render(main.contentView!, appearance, "main-window-\(name)")
}

// The sheet over a missing file: defaults, and Save writes nothing.
try? FileManager.default.removeItem(at: settings)
let sheet = SettingsSheet(url: settings)
let panel = sheet.panel
sheet.reload()
let fpsBefore = UserDefaults.standard.object(forKey: "showFPS")
button(panel, "Save").performClick(nil)
check("Save with no changes creates no file", contents() == nil)
check("Save with no changes leaves Show FPS alone", UserDefaults.standard.object(forKey: "showFPS") as? Bool == fpsBefore as? Bool)

let labels = ["Resolution:", "Frame rate:", "Picture shape:", "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:"]
check("every pop-up's accessible title is its visible label",
      labels.allSatisfy { label in views(in: panel.contentView!).contains {
          ($0 as? NSPopUpButton)?.accessibilityTitleUIElement() as? NSTextField != nil &&
          (($0 as! NSPopUpButton).accessibilityTitleUIElement() as! NSTextField).stringValue == label } } &&
      views(in: panel.contentView!).filter { $0 is NSPopUpButton }.count == labels.count)
check("defaults shown", popUp(panel, "Resolution:").titleOfSelectedItem == "1280 × 720" &&
      popUp(panel, "Frame rate:").titleOfSelectedItem == "30 FPS" && popUp(panel, "Language:").titleOfSelectedItem == "Automatic" &&
      button(panel, "V-Sync").state == .on && button(panel, "Sound").state == .on && button(panel, "Full screen").state == .off)

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
check("tab order runs top to bottom", order == ["Resolution:", "Frame rate:", "V-Sync", "Full screen", "Picture shape:",
      "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:", "Sound", "Show FPS",
      "Show Settings File", "Cancel", "Save"], order.joined(separator: ", "))
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

print("\(failures) render harness checks failed")
exit(failures == 0 ? 0 : 1)
