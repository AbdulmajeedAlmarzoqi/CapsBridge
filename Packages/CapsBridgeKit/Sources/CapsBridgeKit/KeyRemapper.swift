import Foundation
import IOKit.hidsystem

/// One entry of macOS's `UserKeyMapping`: the key pressed and the key the system reports instead.
public struct KeyMapping: Codable, Hashable, Sendable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

/// HID usages: the keyboard usage page (7) in the high word, the key in the low word.
public enum HIDKey {
    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D
}

/// The system's key mappings, and the bookkeeping to add and remove CapsBridge's own without
/// disturbing the user's.
public struct KeyMappingTable: Equatable, Sendable {
    /// macOS tells apps that Caps Lock changed state, never that it went down and came up. F18 is an
    /// ordinary key no Mac keyboard has, so it reaches a VM as a real press and release.
    public static let bridge = KeyMapping(source: HIDKey.capsLock, destination: HIDKey.f18)

    public var mappings: [KeyMapping]

    public init(mappings: [KeyMapping] = []) {
        self.mappings = mappings
    }

    public var containsBridge: Bool { mappings.contains(Self.bridge) }

    /// Maps Caps Lock to F18 and returns the Caps Lock mappings it took the place of.
    @discardableResult
    public mutating func insertBridge() -> [KeyMapping] {
        let displaced = mappings.filter { $0.source == HIDKey.capsLock && $0 != Self.bridge }
        mappings.removeAll { $0.source == HIDKey.capsLock }
        mappings.append(Self.bridge)
        return displaced
    }

    /// Removes the bridge and puts back the mappings it displaced, unless Caps Lock was mapped anew meanwhile.
    public mutating func removeBridge(restoring displaced: [KeyMapping] = []) {
        mappings.removeAll { $0 == Self.bridge }
        if !mappings.contains(where: { $0.source == HIDKey.capsLock }) {
            mappings.append(contentsOf: displaced)
        }
    }
}

/// Reads and writes `UserKeyMapping` on the HID event system, as `hidutil property --set` does.
/// It applies to every keyboard, needs no special permission, and lasts until logout.
public final class KeyRemapper {
    private static let property = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let store: SharedStore?
    /// The user's own Caps Lock mappings the bridge took the place of. Kept on disk too, so a helper
    /// that was restarted, or the app removing everything, can still put them back.
    private var displaced: [KeyMapping] {
        didSet { store?.saveDisplacedMappings(displaced) }
    }

    public init(store: SharedStore? = nil) {
        self.store = store
        displaced = store?.loadDisplacedMappings() ?? []
    }

    public func currentTable() -> KeyMappingTable {
        let raw = IOHIDEventSystemClientCopyProperty(client, Self.property as CFString) as? [[String: NSNumber]] ?? []
        let mappings = raw.compactMap { entry -> KeyMapping? in
            guard let source = entry[Self.sourceKey], let destination = entry[Self.destinationKey] else { return nil }
            return KeyMapping(source: source.uint64Value, destination: destination.uint64Value)
        }
        return KeyMappingTable(mappings: mappings)
    }

    @discardableResult
    public func apply(_ table: KeyMappingTable) -> Bool {
        let raw = table.mappings.map {
            [Self.sourceKey: NSNumber(value: $0.source), Self.destinationKey: NSNumber(value: $0.destination)]
        }
        return IOHIDEventSystemClientSetProperty(client, Self.property as CFString, raw as CFArray)
    }

    public var isBridgeActive: Bool { currentTable().containsBridge }

    /// Whether this process may change the mappings: writes the current table back unchanged.
    public func canRemap() -> Bool { apply(currentTable()) }

    @discardableResult
    public func activateBridge() -> Bool {
        var table = currentTable()
        if table.containsBridge { return true }
        displaced = table.insertBridge()
        return apply(table)
    }

    @discardableResult
    public func deactivateBridge() -> Bool {
        var table = currentTable()
        guard table.containsBridge else { return true }
        table.removeBridge(restoring: displaced)
        displaced = []
        return apply(table)
    }
}
