import Foundation

/// Windows' `Scancode Map`: the registry value under
/// `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout` that remaps keys for the whole
/// system. Windows reads it when it starts, so a change takes effect after a restart.
public struct ScancodeMap: Equatable, Sendable {
    public struct Entry: Hashable, Sendable {
        /// The key pressed.
        public var source: UInt16
        /// The key Windows sees instead.
        public var target: UInt16

        public init(source: UInt16, target: UInt16) {
            self.source = source
            self.target = target
        }

        /// The entry as it's stored: target then source, each little-endian.
        public var hex: String {
            String(format: "%02X%02X%02X%02X", target & 0xFF, target >> 8, source & 0xFF, source >> 8)
        }

        public init?(hex: String) {
            guard let bytes = Data(hex: hex), bytes.count == 4 else { return nil }
            self.init(source: UInt16(bytes[2]) | UInt16(bytes[3]) << 8, target: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        }
    }

    public enum Scancode {
        public static let capsLock: UInt16 = 0x003A
        public static let f18: UInt16 = 0x0069
    }

    /// F18, which the Mac sends in Caps Lock's place, becomes Caps Lock again.
    public static let bridge = Entry(source: Scancode.f18, target: Scancode.capsLock)

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Reads the registry value. `nil` when it isn't a well-formed map.
    public init?(registryData data: Data) {
        // 8 bytes of version and flags, a count that includes the terminator, then 4 bytes an entry.
        guard data.count >= 16 else { return nil }
        let bytes = [UInt8](data)
        let count = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        guard count >= 1, bytes.count >= 12 + count * 4 else { return nil }
        var entries: [Entry] = []
        for index in 0..<(count - 1) {
            let offset = 12 + index * 4
            let target = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            let source = UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8
            if target == 0 && source == 0 { break }
            entries.append(Entry(source: source, target: target))
        }
        self.entries = entries
    }

    public init?(hex: String) {
        guard let data = Data(hex: hex) else { return nil }
        self.init(registryData: data)
    }

    public var registryData: Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        let count = UInt32(entries.count + 1)
        bytes += [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]
        for entry in entries {
            bytes += [UInt8(entry.target & 0xFF), UInt8(entry.target >> 8), UInt8(entry.source & 0xFF), UInt8(entry.source >> 8)]
        }
        bytes += [0, 0, 0, 0]
        return Data(bytes)
    }

    public var hex: String { registryData.map { String(format: "%02X", $0) }.joined() }

    public var isEmpty: Bool { entries.isEmpty }

    public var containsBridge: Bool { entries.contains(Self.bridge) }

    /// Adds the bridge and returns the mapping F18 had before, if it had another.
    @discardableResult
    public mutating func insertBridge() -> Entry? {
        let replaced = entries.first { $0.source == Scancode.f18 && $0 != Self.bridge }
        entries.removeAll { $0.source == Scancode.f18 }
        entries.append(Self.bridge)
        return replaced
    }

    /// Removes the bridge and puts back the mapping it replaced.
    public mutating func removeBridge(restoring replaced: Entry? = nil) {
        entries.removeAll { $0 == Self.bridge }
        if let replaced, !entries.contains(where: { $0.source == replaced.source }) {
            entries.append(replaced)
        }
    }
}

extension Data {
    /// Bytes from hexadecimal text, ignoring spaces. `nil` for anything else.
    init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
