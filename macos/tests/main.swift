// Checks the launcher's settings.ini model (macos/SettingsFile.swift) against
// the rules of load() and save() in settings/settings.cpp.
// Build and run: macos/tests/run.sh
// With --crosscheck DIR EXAMPLE_INI it also writes INI files and the values this model
// reads from them, for crosscheck.cpp to compare with the game's own load().
import Foundation

var failures = 0
var cases = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    if ok { print("ok   \(name)") } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

func shown(_ text: String) -> String { text.debugDescription }

/// The file after the changes must be exactly `output`.
func writes(_ name: String, _ input: String, _ changes: [(Setting, String)], _ output: String) {
    let result = SettingsFile(input).applying(changes)
    check(name, result.bytes == Array(output.utf8), "got \(shown(result.text)), expected \(shown(output))")
}

/// Each setting in `values` reads as the given value; the rest are defaults.
func reads(_ name: String, _ input: String, _ values: [Setting: String]) {
    let file = SettingsFile(input)
    let wrong = Setting.allCases.filter { file.value($0) != (values[$0] ?? $0.fallback) }
    check(name, wrong.isEmpty, wrong.map { "\($0.key)=\(file.value($0)) expected \(values[$0] ?? $0.fallback)" }
        .joined(separator: ", "))
}

// MARK: - Reading

reads("empty file reads defaults", "", [:])
reads("key before any section", "aa = smaa\n[video]\nvsync = off\n", [.aa: "smaa"])
reads("key in [settings]", "[settings]\nvsync = off\nframe_rate = 60\n", [.vsync: "off", .frameRate: "60"])
reads("key in another section is ignored", "[settings]\n[video]\naa = smaa\n[Settings]\nupscale = metalfx\n",
      [.upscale: "metalfx"])
reads("section names are trimmed and case-insensitive", "[other]\naa = fxaa\n[  SETTINGS ]\naspect = Stretch\n",
      [.aspect: "stretch"])
reads("keys are case-insensitive", "VSync = Off\n  Res_Scale\t= 2 \n", [.vsync: "off", .resScale: "2"])
reads("duplicated key: last wins", "[settings]\naa = fxaa\naa = smaa\n", [.aa: "smaa"])
reads("duplicated key: a later invalid value keeps the earlier valid one", "aa = fxaa\naa = bogus\n", [.aa: "fxaa"])
reads("commented sample lines are inactive", "[settings]\n; res_scale = 2\n# vsync = off\n", [:])
reads("trailing comments end the value", "aa = smaa ; my choice\nupscale = metalfx#x\n", [.aa: "smaa", .upscale: "metalfx"])
reads("a comment character anywhere starts the comment", "vsync ; = off\nfull#screen = on\n", [:])
reads("CRLF file", "[settings]\r\nvsync = off\r\naa = fxaa\r\n", [.vsync: "off", .aa: "fxaa"])
reads("no trailing newline", "[settings]\nfullscreen = on", [.fullscreen: "on"])
reads("invalid values read as defaults",
      "res_scale = 4\nframe_rate = 45\naa = msaa\nanisotropic = 3x\nlanguage = xx\nvsync = maybe\naudio =\n", [:])
reads("toggle synonyms on", "vsync = yes\nfullscreen = TRUE\naudio = 1\n", [.fullscreen: "on"])
reads("toggle synonyms off", "vsync = No\nfullscreen = false\naudio = 0\n", [.vsync: "off", .audio: "off"])
reads("aa and upscale accept 0 as off", "aa = 0\nupscale = 0\n", [:])
reads("custom res_scale", "res_scale = 1.25\n", [.resScale: "1.25"])
reads("res_scale bounds", "res_scale = 0.5\n", [.resScale: "0.5"])
reads("custom anisotropic", "anisotropic = 6\n", [.anisotropic: "6"])
reads("numeric language", "language = 18\n", [.language: "18"])
reads("language code is lower-cased", "language = EN-GB\n", [.language: "en-gb"])
check("frame pacing defaults to on, as the game has it", Setting.framePacing.fallback == "on")
reads("frame_pacing off", "[settings]\nframe_pacing = off\n", [.framePacing: "off"])
reads("frame_pacing synonyms", "frame_pacing = No\n", [.framePacing: "off"])
reads("frame_pacing invalid reads as default", "frame_pacing = 33\n", [:])
check("controller defaults are the game's", Setting.stickDeadzone.fallback == "10" &&
      Setting.vibration.fallback == "100" && Setting.controllerQuit.fallback == "on")
reads("controller keys", "[settings]\nstick_deadzone = 0\nvibration = 55\ncontroller_quit = off\n",
      [.stickDeadzone: "0", .vibration: "55", .controllerQuit: "off"])
reads("controller number bounds", "stick_deadzone = 50\nvibration = 0\n", [.stickDeadzone: "50", .vibration: "0"])
reads("controller numbers out of range read as defaults", "stick_deadzone = 51\nvibration = 101\n", [:])
reads("controller numbers are integers only",
      "stick_deadzone = 10.0\nstick_deadzone = +5\nvibration = 1e2\nvibration = 50%\nvibration = -1\nstick_deadzone =\n", [:])
reads("controller numbers keep their text", "stick_deadzone = 08\nvibration = 040\n", [.stickDeadzone: "08", .vibration: "040"])
reads("controller_quit synonyms", "controller_quit = No\n", [.controllerQuit: "off"])
reads("controller_quit invalid reads as default", "controller_quit = off\ncontroller_quit = maybe\n", [.controllerQuit: "off"])
reads("controller keys in another section are ignored", "[pad]\nvibration = 0\ncontroller_quit = off\n", [:])
check("motion defaults are the game's", Setting.motion.fallback == "on" && Setting.shakeButton.fallback == "off")
reads("motion keys", "[settings]\nmotion = off\nshake_button = r3\n", [.motion: "off", .shakeButton: "r3"])
reads("shake_button values are lower-cased", "shake_button = TouchPad\n", [.shakeButton: "touchpad"])
reads("shake_button l3 with a comment", "shake_button = l3 ; left stick\n", [.shakeButton: "l3"])
reads("motion synonyms", "motion = No\n", [.motion: "off"])
reads("motion and shake_button invalid read as defaults",
      "motion = maybe\nshake_button = r2\nshake_button = 0\nshake_button = l 3\nshake_button =\n", [:])
reads("shake_button: a later invalid value keeps the earlier valid one", "shake_button = r3\nshake_button = x\n",
      [.shakeButton: "r3"])
check("numeric language maps to its language", languageID("18") == languageID("en-gb") && languageID("0") == 0)
check("language ids follow cellSysutil", languageID("en") == 1 && languageID("en-us") == 1 &&
      languageID("pt") == 7 && languageID("pt-br") == 17 && languageID("tr") == 19 && languageID("auto") == nil)
check("res_scale presets compare by number", SettingsFile.real("1.0") == SettingsFile.real("1"))
check("integers follow from_chars", SettingsFile.integer("+4") == nil && SettingsFile.integer("08") == 8 &&
      SettingsFile.integer(" 4") == nil && SettingsFile.integer("4.0") == nil)

// MARK: - Writing

writes("empty file gains [settings]", "", [(.aa, "fxaa")], "[settings]\naa = fxaa\n")
writes("no changes leave the bytes alone", "junk\r\n[x]\n\u{1}", [], "junk\r\n[x]\n\u{1}")
writes("key before any section replaced in place", "aa = smaa\n[video]\nx = 1\n", [(.aa, "fxaa")],
       "aa = fxaa\n[video]\nx = 1\n")
writes("key in [settings] replaced in place", "[settings]\nvsync = off\n", [(.vsync, "on")], "[settings]\nvsync = on\n")
writes("key in another section is left; new line after the settings content",
       "[settings]\nvsync = off\n\n[video]\naa = smaa\n", [(.aa, "fxaa")],
       "[settings]\nvsync = off\n\naa = fxaa\n[video]\naa = smaa\n")
writes("file with only another section gets [settings] at the start", "[video]\naa = smaa\n", [(.aa, "off")],
       "[settings]\naa = off\n[video]\naa = smaa\n")
writes("duplicated key: last is replaced", "[settings]\naa = fxaa\naa = smaa\n", [(.aa, "off")],
       "[settings]\naa = fxaa\naa = off\n")
writes("commented sample untouched", "[settings]\n; res_scale = 1\n; Comment\n", [(.resScale, "2")],
       "[settings]\n; res_scale = 1\n; Comment\nres_scale = 2\n")
writes("trailing comment on the edited line preserved", "  aa\t=  fxaa   ; my choice\nx=1 # keep\n", [(.aa, "smaa")],
       "  aa\t=  smaa   ; my choice\nx=1 # keep\n")
writes("CRLF file stays CRLF", "[settings]\r\nvsync = off\r\n", [(.vsync, "on"), (.aa, "fxaa")],
       "[settings]\r\nvsync = on\r\naa = fxaa\r\n")
writes("no trailing newline: replace", "[settings]\nvsync = off", [(.vsync, "on")], "[settings]\nvsync = on")
writes("no trailing newline: insert", "[settings]\nvsync = off", [(.aa, "fxaa")], "[settings]\nvsync = off\naa = fxaa\n")
writes("invalid existing value replaced", "res_scale = 9 ; too big\n", [(.resScale, "2")], "res_scale = 2 ; too big\n")
writes("empty existing value replaced as save() does", "aa =\n", [(.aa, "fxaa")], "aa =fxaa\n")
writes("upper-case key replaced", "VSYNC = Off\n", [(.vsync, "on")], "VSYNC = on\n")
writes("unchanged keys not written", "; mine\n[settings]\nvsync = yes\naa = 0\n[other]\nk = v\n", [(.fullscreen, "on")],
       "; mine\n[settings]\nvsync = yes\naa = 0\nfullscreen = on\n[other]\nk = v\n")
writes("several inserts keep their order", "[settings]\n", [(.resScale, "1.5"), (.frameRate, "60"), (.language, "fr")],
       "[settings]\nres_scale = 1.5\nframe_rate = 60\nlanguage = fr\n")
writes("frame_rate change comments out active vblank_ms and sim_steps",
       "[settings]\nframe_rate = 30\nvblank_ms = 10\n  sim_steps=1 ; measured\n; vblank_ms = 16.667\n[other]\nsim_steps = 2\n",
       [(.frameRate, "60")],
       "[settings]\nframe_rate = 60\n; vblank_ms = 10\n;   sim_steps=1 ; measured\n; vblank_ms = 16.667\n[other]\nsim_steps = 2\n")
writes("frame_rate change comments out every active override line", "vblank_ms = 8\nvblank_ms = 12\n", [(.frameRate, "60")],
       "; vblank_ms = 8\n; vblank_ms = 12\nframe_rate = 60\n")
writes("overrides untouched when frame_rate is unchanged", "[settings]\nvblank_ms = 10\nsim_steps = 1\n", [(.aa, "smaa")],
       "[settings]\nvblank_ms = 10\nsim_steps = 1\naa = smaa\n")
writes("controller keys inserted in order", "[settings]\n",
       [(.vibration, "50"), (.stickDeadzone, "15"), (.controllerQuit, "off")],
       "[settings]\nvibration = 50\nstick_deadzone = 15\ncontroller_quit = off\n")
writes("controller key replaced in place", "[settings]\nvibration = 40 ; mine\nCONTROLLER_QUIT = yes\n",
       [(.vibration, "0"), (.controllerQuit, "off")], "[settings]\nvibration = 0 ; mine\nCONTROLLER_QUIT = off\n")
writes("motion keys inserted in order", "[settings]\nvibration = 50\n", [(.motion, "off"), (.shakeButton, "touchpad")],
       "[settings]\nvibration = 50\nmotion = off\nshake_button = touchpad\n")
writes("shake_button replaced in place", "[settings]\nSHAKE_BUTTON = R3 ; mine\nmotion = 0\n",
       [(.shakeButton, "off"), (.motion, "on")], "[settings]\nSHAKE_BUTTON = off ; mine\nmotion = on\n")
writes("custom vibration kept when another key changes", "vibration = 40\n", [(.stickDeadzone, "5")],
       "vibration = 40\nstick_deadzone = 5\n")
writes("custom res_scale kept when another key changes", "res_scale = 1.25\n", [(.aa, "fxaa")],
       "res_scale = 1.25\naa = fxaa\n")

// MARK: - The file on disk

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-file-test-\(getpid())")
try? FileManager.default.removeItem(at: directory)
let url = directory.appendingPathComponent("state/settings.ini")
do {
    let missing = try SettingsFile(contentsOf: url)
    check("missing file reads empty", missing.bytes.isEmpty)
    try missing.applying([(.vsync, "off")]).write(to: url)
    check("write creates the directory and file", try String(contentsOf: url, encoding: .utf8) == "[settings]\nvsync = off\n")
    chmod(url.path, 0o640)
    try SettingsFile(contentsOf: url).applying([(.vsync, "on")]).write(to: url)
    var status = stat()
    stat(url.path, &status)
    check("rewrite keeps the file mode", status.st_mode & 0o777 == 0o640, String(status.st_mode & 0o777, radix: 8))
    let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    check("no temporary file left behind", left == ["settings.ini"], "\(left)")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.ini"), withIntermediateDirectories: true)
    let folder = directory.appendingPathComponent("folder.ini")
    check("a directory is not read", (try? SettingsFile(contentsOf: folder)) == nil)
    check("a directory is not replaced", (try? SettingsFile().write(to: folder)) == nil)
    chmod(url.deletingLastPathComponent().path, 0o500)
    let refused = (try? SettingsFile("vsync = off\n").write(to: url)) == nil
    chmod(url.deletingLastPathComponent().path, 0o700)
    check("an unwritable directory reports an error", refused)
    check("the failed write left the file alone", try String(contentsOf: url, encoding: .utf8) == "[settings]\nvsync = on\n")
} catch {
    check("file on disk", false, "\(error)")
}
try? FileManager.default.removeItem(at: directory)

// MARK: - Files for the cross-check with settings.cpp

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--crosscheck" {
    let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    // name, starting file, changes the sheet would make, extra keys the game must resolve
    let files: [(String, String, [(Setting, String)], [String: String])] = [
        ("written-empty", "", [(.resScale, "2"), (.vsync, "off"), (.language, "en-gb"), (.anisotropic, "16")], [:]),
        ("written-sample", try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8),
         [(.resScale, "1.5"), (.aa, "smaa"), (.audio, "off"), (.upscale, "metalfx")], [:]),
        ("written-60-overrides", "[settings]\nvblank_ms = 10\nsim_steps = 2\n", [(.frameRate, "60")],
         ["vblank_ms": "8.333", "sim_steps": "1"]),
        ("written-unchanged-overrides", "[settings]\nvblank_ms = 10\nsim_steps = 1\n", [(.fullscreen, "on")],
         ["vblank_ms": "10", "sim_steps": "1"]),
        ("written-crlf-no-newline", "[settings]\r\nvsync = off\r\naspect = fit", [(.aspect, "stretch"), (.aa, "fxaa")], [:]),
        ("written-other-section", "[video]\naa = smaa\n", [(.aa, "fxaa"), (.language, "ja")], [:]),
        ("written-duplicate-invalid", "aa = fxaa\naa = bogus\nres_scale = 9\n", [(.aa, "smaa"), (.resScale, "3")], [:]),
        ("read-synonyms", "vsync = No\nfullscreen = TRUE\naudio = 0\naa = 0\nupscale = 0\n", [], [:]),
        ("read-sections", "aa = smaa\n[video]\nvsync = off\n[ Settings ]\nVSync = 0 ; x\n#aspect = stretch\n", [], [:]),
        ("read-invalid", "res_scale = 4\nframe_rate = 45\nanisotropic = 1\nlanguage = xx\naspect=\n", [], [:]),
        ("read-numbers", "res_scale = 0x2\nanisotropic = 08\nlanguage = 18\nframe_rate = 60\n", [], [:]),
        ("read-odd-language", "language = en en-us\nres_scale = 1.25e0\n", [], [:]),
        ("written-controller", "[settings]\nvibration = 40 ; mine\n",
         [(.vibration, "75"), (.stickDeadzone, "30"), (.controllerQuit, "off")], [:]),
        ("read-controller", "stick_deadzone = 08\nvibration = 0\ncontroller_quit = No\n", [], [:]),
        ("read-controller-invalid", "stick_deadzone = 51\nvibration = 101\ncontroller_quit = maybe\n", [], [:]),
        ("written-motion", "[settings]\nshake_button = l3\n", [(.shakeButton, "r3"), (.motion, "off")], [:]),
        ("read-motion", "motion = No\nshake_button = TOUCHPAD\n", [], [:]),
        ("read-motion-invalid", "motion = maybe\nshake_button = r2\nshake_button = 0\nshake_button = l 3\n", [], [:]),
        ("read-controller-odd", "stick_deadzone = 10.0\nvibration = +5\nstick_deadzone = -0\nvibration = 1e2\n", [], [:]),
        ("read-last-valid", "language = fr\nlanguage = zz\nanisotropic = 4\nanisotropic = 6\n", [], [:]),
    ]
    for (name, input, changes, extra) in files {
        let file = SettingsFile(input).applying(changes)
        try! Data(file.bytes).write(to: out.appendingPathComponent(name + ".ini"))
        var expect = Setting.allCases.map { "\($0.key)=\(file.value($0))" }
        expect += extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try! (expect.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent(name + ".expect"),
                                                            atomically: true, encoding: .utf8)
    }
    print("wrote \(files.count) cross-check files to \(out.path)")
}

print("\(failures) of \(cases) settings file cases failed")
exit(failures == 0 ? 0 : 1)
