import Foundation

/// NVDA's `nvda.ini`, edited one line at a time so everything else in it stays byte for byte.
///
/// NVDA keeps which keys act as the NVDA key in its `[keyboard]` section. Since configuration
/// schema 10 that is `NVDAModifierKeys`, a bit mask (Caps Lock 1, numpad Insert 2, Insert 4,
/// 6 by default). Before, it was `useCapsLockAsNVDAModifierKey`, off by default, which NVDA
/// converts by itself when it upgrades an older file.
public struct NVDAConfig: Equatable, Sendable {
    /// What `enableCapsLock()` changed, kept so it can be undone later.
    public struct Change: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// `NVDAModifierKeys` was there without the Caps Lock bit.
            case maskChanged
            /// `NVDAModifierKeys` wasn't there: NVDA used its default.
            case maskAdded
            /// `useCapsLockAsNVDAModifierKey` was there and off.
            case legacyChanged
            /// `useCapsLockAsNVDAModifierKey` wasn't there.
            case legacyAdded
        }

        public var kind: Kind
        /// The value the line had, for the kinds that changed one.
        public var previousValue: String?
        /// Whether the `[keyboard]` section had to be added too.
        public var addedSection: Bool

        public init(kind: Kind, previousValue: String? = nil, addedSection: Bool = false) {
            self.kind = kind
            self.previousValue = previousValue
            self.addedSection = addedSection
        }
    }

    public enum ReadError: Error, Equatable, Sendable {
        case notUTF8
    }

    private static let capsLockBit = 1
    private static let defaultMask = 6
    private static let maskKey = "NVDAModifierKeys"
    private static let legacyKey = "useCapsLockAsNVDAModifierKey"
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    private var lines: [String]
    private var newline: String
    private var endsWithNewline: Bool
    private var hasByteOrderMark: Bool

    public init(text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        endsWithNewline = text.hasSuffix("\n")
        hasByteOrderMark = false
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if endsWithNewline || text.isEmpty { lines.removeLast() }
        self.lines = lines
    }

    public init(data: Data) throws {
        let hasMark = data.starts(with: Self.byteOrderMark)
        guard let text = String(data: hasMark ? data.dropFirst(3) : data, encoding: .utf8) else {
            throw ReadError.notUTF8
        }
        self.init(text: text)
        hasByteOrderMark = hasMark
    }

    public var text: String {
        lines.joined(separator: newline) + (endsWithNewline && !lines.isEmpty ? newline : "")
    }

    public var data: Data {
        (hasByteOrderMark ? Self.byteOrderMark : Data()) + Data(text.utf8)
    }

    /// The file's `schemaVersion`. A file without one is as old as they come.
    public var schemaVersion: Int? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if let value = Self.value(of: "schemaVersion", in: line) { return Int(value) }
        }
        return nil
    }

    /// Whether Caps Lock is an NVDA key with this configuration.
    public var capsLockIsNVDAKey: Bool {
        if usesMask {
            let mask = keyboardValue(of: Self.maskKey).flatMap { Int($0) } ?? Self.defaultMask
            return mask & Self.capsLockBit != 0
        }
        return keyboardValue(of: Self.legacyKey).map(Self.isTrue) ?? false
    }

    /// Makes Caps Lock an NVDA key. Returns what it changed, or `nil` when it already was one.
    @discardableResult
    public mutating func enableCapsLock() -> Change? {
        guard !capsLockIsNVDAKey else { return nil }
        if usesMask {
            if let previous = keyboardValue(of: Self.maskKey) {
                let mask = Int(previous) ?? Self.defaultMask
                setKeyboardValue("\(mask | Self.capsLockBit)", for: Self.maskKey)
                return Change(kind: .maskChanged, previousValue: previous)
            }
            let addedSection = setKeyboardValue("\(Self.defaultMask | Self.capsLockBit)", for: Self.maskKey)
            return Change(kind: .maskAdded, addedSection: addedSection)
        }
        if let previous = keyboardValue(of: Self.legacyKey) {
            setKeyboardValue("True", for: Self.legacyKey)
            return Change(kind: .legacyChanged, previousValue: previous)
        }
        let addedSection = setKeyboardValue("True", for: Self.legacyKey)
        return Change(kind: .legacyAdded, addedSection: addedSection)
    }

    /// Takes Caps Lock back out, leaving whatever else changed in the file since.
    public mutating func undo(_ change: Change) {
        // NVDA may have rewritten the file in its newer form since the change was made.
        if usesMask {
            guard let current = keyboardValue(of: Self.maskKey).flatMap({ Int($0) }) else { return }
            let withoutCapsLock = current & ~Self.capsLockBit
            // NVDA needs one key at least: with Caps Lock the only one, the default comes back.
            let restored = withoutCapsLock == 0 ? Self.defaultMask : withoutCapsLock
            if change.kind == .maskAdded || change.kind == .legacyAdded, restored == Self.defaultMask {
                removeKeyboardValue(for: Self.maskKey, andSection: change.addedSection)
            } else {
                setKeyboardValue("\(restored)", for: Self.maskKey)
            }
            return
        }
        guard keyboardValue(of: Self.legacyKey) != nil else { return }
        switch change.kind {
        case .legacyAdded, .maskAdded:
            removeKeyboardValue(for: Self.legacyKey, andSection: change.addedSection)
        case .legacyChanged, .maskChanged:
            setKeyboardValue(change.kind == .legacyChanged ? (change.previousValue ?? "False") : "False", for: Self.legacyKey)
        }
    }

    // MARK: - The [keyboard] section

    private var usesMask: Bool {
        if keyboardValue(of: Self.maskKey) != nil { return true }
        if keyboardValue(of: Self.legacyKey) != nil { return false }
        return (schemaVersion ?? 0) >= 10
    }

    /// The lines of `[keyboard]`'s own keys, without its header: up to the next section of any depth,
    /// since a section's keys come before its subsections.
    private var keyboardSection: Range<Int>? {
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[keyboard]" }) else {
            return nil
        }
        var end = header + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end += 1
        }
        return (header + 1)..<end
    }

    private func keyboardLine(of key: String) -> Int? {
        keyboardSection?.first { Self.value(of: key, in: lines[$0]) != nil }
    }

    private func keyboardValue(of key: String) -> String? {
        keyboardLine(of: key).flatMap { Self.value(of: key, in: lines[$0]) }
    }

    /// Sets a key in `[keyboard]`, adding the line or the section when missing. Returns whether it added the section.
    @discardableResult
    private mutating func setKeyboardValue(_ value: String, for key: String) -> Bool {
        if let index = keyboardLine(of: key) {
            let indentation = lines[index].prefix { $0 == " " || $0 == "\t" }
            lines[index] = "\(indentation)\(key) = \(value)"
            return false
        }
        if let section = keyboardSection {
            // Indented as the section's other keys are, and after the last of them.
            let keyLines = section.filter { lines[$0].contains("=") && !lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            let indentation = keyLines.first.map { String(lines[$0].prefix { $0 == " " || $0 == "\t" }) } ?? "\t"
            let position = (keyLines.last ?? section.lowerBound - 1) + 1
            lines.insert("\(indentation)\(key) = \(value)", at: position)
            return false
        }
        lines.append("[keyboard]")
        lines.append("\t\(key) = \(value)")
        endsWithNewline = true
        return true
    }

    private mutating func removeKeyboardValue(for key: String, andSection removeSection: Bool) {
        guard let index = keyboardLine(of: key) else { return }
        lines.remove(at: index)
        guard removeSection, let section = keyboardSection else { return }
        let isEmpty = section.allSatisfy { lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        if isEmpty {
            lines.removeSubrange((section.lowerBound - 1)..<section.upperBound)
        }
    }

    // MARK: - Lines

    /// The value of `key = value` on a line, without quotes. `nil` when the line sets another key.
    private static func value(of key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return nil }
        let rest = trimmed.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard rest.first == "=" else { return nil }
        var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = String(value.dropFirst().dropLast())
        } else if let comment = value.firstIndex(of: "#") {
            value = value[..<comment].trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func isTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(value.lowercased())
    }
}
