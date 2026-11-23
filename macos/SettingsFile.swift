import Foundation

// The settings.ini keys the launcher's Settings sheet edits. Reading and
// writing follow load(), normalize() and save() in settings/settings.cpp,
// byte for byte: a line is split at '\n', a comment starts at the first ';'
// or '#', keys count in [settings] or before any section, and the last valid
// value wins. Environment variables are not consulted.
enum Setting: String, CaseIterable {
    case resScale = "res_scale", frameRate = "frame_rate", vsync, fullscreen, aspect, aa, upscale
    case anisotropic, language, audio

    var key: String { rawValue }

    var fallback: String {
        switch self {
        case .resScale: return "1"
        case .frameRate: return "30"
        case .vsync, .audio: return "on"
        case .fullscreen, .aa, .upscale: return "off"
        case .aspect: return "fit"
        case .anisotropic: return "0"
        case .language: return "auto"
        }
    }

    /// The value as normalize() leaves it, or nil when the game rejects it.
    func normalize(_ text: String) -> String? {
        var value = SettingsFile.lower(SettingsFile.trim(text))
        switch self {
        case .vsync, .fullscreen, .audio:
            if value == "yes" || value == "true" || value == "1" { value = "on" }
            if value == "no" || value == "false" || value == "0" { value = "off" }
            return value == "on" || value == "off" ? value : nil
        case .resScale:
            guard let real = SettingsFile.real(value), real >= 0.5, real <= 3 else { return nil }
            return value
        case .frameRate:
            return value == "30" || value == "60" ? value : nil
        case .anisotropic:
            guard let integer = SettingsFile.integer(value), integer == 0 || (2...16).contains(integer) else {
                return nil
            }
            return value
        case .language:
            if value == "auto" { return value }
            if let integer = SettingsFile.integer(value) { return (0...19).contains(integer) ? value : nil }
            let codes = " ja en en-us fr es de it nl pt pt-pt ru ko zh-t zh-s fi sv da no pl pt-br en-gb tr "
            return codes.contains(" " + value + " ") ? value : nil
        case .aa:
            if value == "0" { value = "off" }
            return ["off", "fxaa", "smaa"].contains(value) ? value : nil
        case .aspect:
            return value == "fit" || value == "stretch" ? value : nil
        case .upscale:
            if value == "0" { value = "off" }
            return value == "off" || value == "metalfx" ? value : nil
        }
    }
}

struct SettingsFileError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct SettingsFile {
    var bytes: [UInt8]

    init(bytes: [UInt8] = []) { self.bytes = bytes }
    init(_ text: String) { bytes = Array(text.utf8) }

    /// Reads the file; a missing file is an empty one.
    init(contentsOf url: URL) throws {
        var status = stat()
        if stat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw SettingsFileError(String(cString: strerror(errno))) }
            bytes = []
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw SettingsFileError("It isn't a regular file.") }
        bytes = Array(try Data(contentsOf: url))
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// The value the game resolves from this file, or the game's default.
    func value(_ setting: Setting) -> String {
        iniValue(setting) ?? setting.fallback
    }

    /// The last valid value in the file, as load() keeps it.
    func iniValue(_ setting: Setting) -> String? {
        scan().assignments.reversed().lazy
            .filter { $0.key == setting.key }
            .compactMap { setting.normalize(String(decoding: self.bytes[$0.tail], as: UTF8.self)) }
            .first
    }

    /// The file with each change applied as save() applies it, in order. A
    /// frame_rate change also comments out active vblank_ms and sim_steps
    /// lines, which would otherwise override it.
    func applying(_ changes: [(Setting, String)]) -> SettingsFile {
        var file = self
        if changes.contains(where: { $0.0 == .frameRate }) {
            for line in file.scan().assignments.reversed() where line.key == "vblank_ms" || line.key == "sim_steps" {
                file.bytes.insert(contentsOf: Array("; ".utf8), at: line.lineStart)
            }
        }
        for (setting, value) in changes { file.save(setting.key, value) }
        return file
    }

    /// Writes through a temporary file in the same directory and a rename.
    func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SettingsFileError(error.localizedDescription)
        }
        var status = stat()
        var mode: mode_t = 0o644
        if stat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else { throw SettingsFileError("It isn't a regular file.") }
            mode = status.st_mode & 0o777
        }
        let temporary = url.path + ".tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw SettingsFileError(String(cString: strerror(errno))) }
        var failure: Int32 = 0
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temporary, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw SettingsFileError(String(cString: strerror(failure)))
        }
    }

    // MARK: - save() and load()

    private struct Assignment {
        let key: String
        let lineStart: Int
        let tail: Range<Int>  // after '=', up to the comment, trimmed
    }

    /// Every active key line in the settings section, and where save()
    /// inserts a missing key: after the last line of settings content.
    private func scan() -> (assignments: [Assignment], insertOffset: Int) {
        var assignments: [Assignment] = []
        var insertOffset = 0
        var settingsSection = true
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.count
            let comment = bytes[start..<end].firstIndex(where: { $0 == 59 || $0 == 35 }) ?? end
            let text = Self.trim(bytes, start..<comment)
            if text.count >= 2, bytes[text.lowerBound] == 91, bytes[text.upperBound - 1] == 93 {
                let name = Self.trim(bytes, text.lowerBound + 1..<text.upperBound - 1)
                settingsSection = Self.lower(String(decoding: bytes[name], as: UTF8.self)) == "settings"
            } else if settingsSection, let equals = bytes[text].firstIndex(of: 61) {
                let key = Self.lower(String(decoding: bytes[Self.trim(bytes, text.lowerBound..<equals)], as: UTF8.self))
                let value = Self.trim(bytes, equals + 1..<text.upperBound)
                assignments.append(Assignment(key: key, lineStart: start,
                                              tail: value.isEmpty ? equals + 1..<equals + 1 : value))
            }
            start = end == bytes.count ? end : end + 1
            if settingsSection { insertOffset = start }
        }
        return (assignments, insertOffset)
    }

    private mutating func save(_ key: String, _ value: String) {
        let (assignments, insertOffset) = scan()
        if let line = assignments.last(where: { $0.key == key }) {
            bytes.replaceSubrange(line.tail, with: Array(value.utf8))
            return
        }
        // save() always inserts '\n'; this keeps a CRLF file CRLF.
        let crlf = bytes.firstIndex(of: 10).map { $0 > 0 && bytes[$0 - 1] == 13 } ?? false
        let newline = crlf ? "\r\n" : "\n"
        var line = ""
        if insertOffset > 0 && bytes[insertOffset - 1] != 10 { line += newline }
        if insertOffset == 0 { line += "[settings]" + newline }
        line += "\(key) = \(value)" + newline
        bytes.insert(contentsOf: Array(line.utf8), at: insertOffset)
    }

    // MARK: - The C++ helpers

    static func trim(_ bytes: [UInt8], _ range: Range<Int>) -> Range<Int> {
        let blank: (UInt8) -> Bool = { $0 == 32 || $0 == 9 || $0 == 13 }
        guard let first = bytes[range].firstIndex(where: { !blank($0) }) else { return range.lowerBound..<range.lowerBound }
        let last = bytes[range].lastIndex(where: { !blank($0) })!
        return first..<last + 1
    }

    static func trim(_ text: String) -> String {
        let bytes = Array(text.utf8)
        return String(decoding: bytes[trim(bytes, 0..<bytes.count)], as: UTF8.self)
    }

    /// ASCII only, like lower() in settings.cpp.
    static func lower(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    /// strtod() that must consume the whole text, as normalize() requires.
    static func real(_ text: String) -> Double? {
        text.withCString { start in
            var end: UnsafeMutablePointer<CChar>?
            let value = strtod(start, &end)
            guard let end, end != UnsafeMutablePointer(mutating: start), end.pointee == 0 else { return nil }
            return value
        }
    }

    /// std::from_chars into an int: an optional '-', then digits only.
    static func integer(_ text: String) -> Int32? {
        text.first == "+" ? nil : Int32(text)
    }
}

/// The PS3 language a value selects, by CELL_SYSUTIL_LANG_* id, as
/// sysutil_language() in the toolkit's cellSysutil.c reads PS3_LANG: a number,
/// else a code, else English (US). nil is "auto" (the Mac's own language).
func languageID(_ value: String) -> Int? {
    if value == "auto" { return nil }
    if let number = SettingsFile.integer(value), (0...19).contains(number) { return Int(number) }
    let codes = ["ja": 0, "en": 1, "en-us": 1, "fr": 2, "es": 3, "de": 4, "it": 5, "nl": 6, "pt": 7,
                 "pt-pt": 7, "ru": 8, "ko": 9, "zh-t": 10, "zh-s": 11, "fi": 12, "sv": 13, "da": 14,
                 "no": 15, "pl": 16, "pt-br": 17, "en-gb": 18, "tr": 19]
    return codes[value] ?? 1
}
