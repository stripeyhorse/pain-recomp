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

let labels = ["Resolution:", "Frame rate:", "Picture shape:", "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:",
              "Vibration:", "Stick dead zone:"]
check("every pop-up's accessible title is its visible label",
      labels.allSatisfy { label in views(in: panel.contentView!).contains {
          ($0 as? NSPopUpButton)?.accessibilityTitleUIElement() as? NSTextField != nil &&
          (($0 as! NSPopUpButton).accessibilityTitleUIElement() as! NSTextField).stringValue == label } } &&
      views(in: panel.contentView!).filter { $0 is NSPopUpButton }.count == labels.count)
check("defaults shown", popUp(panel, "Resolution:").titleOfSelectedItem == "1280 × 720" &&
      popUp(panel, "Frame rate:").titleOfSelectedItem == "30 FPS" && popUp(panel, "Language:").titleOfSelectedItem == "Automatic" &&
      button(panel, "V-Sync").state == .on && button(panel, "Sound").state == .on && button(panel, "Full screen").state == .off &&
      popUp(panel, "Vibration:").titleOfSelectedItem == "100%" && popUp(panel, "Stick dead zone:").titleOfSelectedItem == "10%" &&
      button(panel, "Hold PS or Start+Select to quit").state == .on)

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
let tabOrder = ["Resolution:", "Frame rate:", "V-Sync", "Full screen", "Picture shape:",
      "Anti-aliasing:", "Upscaling:", "Texture filtering:", "Language:", "Sound", "Show FPS",
      "Vibration:", "Stick dead zone:", "Hold PS or Start+Select to quit",
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

func waitFor(_ seconds: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
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
let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PainRecomp")
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
let mainButton = { (title: String) in views(in: main.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }! }
let play = mainButton("Play")
func running() -> Bool { !play.isEnabled && !mainButton("Settings…").isEnabled }
/// One pad reading at the next instant.
func send(_ state: PadState, after seconds: TimeInterval = 0.02) {
    now += seconds
    pad = state
    nav.update(state, at: now)
}

nav.refresh()
check("controller armed once the pad is seen released", nav.armed)
check("first direction focuses Play on the main window", nav.perform(.down) && name(main.firstResponder) == "Play",
      name(main.firstResponder))
var mainOrder = [name(main.firstResponder)]
while nav.perform(.left) { mainOrder.append(name(main.firstResponder)) }
check("main window focus order visits every control once", Array(mainOrder.reversed()) == ["Choose Game…", "Show Log", "Settings…", "Play"],
      mainOrder.joined(separator: ", "))
var downOrder = [name(main.firstResponder)]
while nav.perform(.down) { downOrder.append(name(main.firstResponder)) }
check("Down walks the same order", downOrder == ["Choose Game…", "Show Log", "Settings…", "Play"], downOrder.joined(separator: ", "))
check("Circle does nothing on the main window", !nav.perform(.cancel))

// Stick threshold, hysteresis and repeat (synthetic clock).
send(PadState())
send(PadState(x: -0.45))
check("stick below the threshold does nothing", name(main.firstResponder) == "Play")
send(PadState(x: -0.6))
check("stick past the threshold moves once", name(main.firstResponder) == "Settings…", name(main.firstResponder))
send(PadState(x: -0.35), after: 0.1)
send(PadState(x: -0.55), after: 0.1)
check("wobbling above the release point is one push", name(main.firstResponder) == "Settings…", name(main.firstResponder))
nav.tick(at: now + 0.1)
check("no repeat before the delay", name(main.firstResponder) == "Settings…")
now += 0.25
nav.tick(at: now)
check("repeat after the delay", name(main.firstResponder) == "Show Log", name(main.firstResponder))
now += ControllerNavigator.repeatInterval
nav.tick(at: now)
check("repeat continues at the interval", name(main.firstResponder) == "Choose Game…", name(main.firstResponder))
send(PadState(x: -0.2))
send(PadState(y: -1))
send(PadState(y: -1), after: 0.1)
check("d-pad Down moves once per press", name(main.firstResponder) == "Show Log", name(main.firstResponder))
send(PadState())
send(PadState(x: 1)); send(PadState())
check("d-pad Right moves once", name(main.firstResponder) == "Settings…", name(main.firstResponder))

// Status line and focus ring on the main window.
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
let statusText = views(in: main.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("PAIN · BCES") }!
let ready = statusText.stringValue
statusText.stringValue = "PAIN closed during launch or play (code 1). Open the log for details. " +
    "PAIN closed during launch or play (code 1). Open the log for details. PAIN closed during launch."
main.contentView!.layoutSubtreeIfNeeded()
check("status line stays inside the window under a three-line message",
      statusLine.map { $0.convert($0.bounds, to: nil).minY >= 8 } == true,
      statusLine.map { "\($0.convert($0.bounds, to: nil))" } ?? "")
statusText.stringValue = ready
check("battery wording", ControllerInput.describe(name: "Pad", level: 0.5, state: .charging).text == "Pad · 50% battery, charging" &&
      ControllerInput.describe(name: "Pad", level: 1, state: .full).text == "Pad · battery full" &&
      ControllerInput.describe(name: "Pad", level: 0, state: .unknown).text == "Pad" &&
      ControllerInput.describe(name: nil, level: nil, state: .unknown).text == "Controller")
check("focus ring view takes no clicks or accessibility focus",
      views(in: main.contentView!).compactMap { $0 as? FocusRingView }.first.map {
          $0.hitTest(NSPoint(x: 100, y: 50)) == nil && !$0.isAccessibilityElement() && !$0.acceptsFirstResponder } == true)
for (appearanceName, appearance) in appearances {
    render(main.contentView!, appearance, "main-window-controller-\(appearanceName)")
    let background = NSColor.windowBackgroundColor
    let text = contrast(.labelColor, on: background, appearance), ring = contrast(.controlAccentColor, on: background, appearance)
    print(String(format: "contrast \(appearanceName): status line %.2f:1, focus ring %.2f:1, existing grey status text %.2f:1",
                 text, ring, contrast(.secondaryLabelColor, on: background, appearance)))
    check("status line text at least 4.5:1 and focus ring at least 3:1, \(appearanceName)", text >= 4.5 && ring >= 3)
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
focus("Save")
check("Cross on Save", sheetNav.perform(.activate))
let saved = "[settings]\nvibration = 75\nstick_deadzone = 15\naudio = off\ncontroller_quit = off\n"
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

print("\(failures) render harness checks failed")
exit(failures == 0 ? 0 : 1)
