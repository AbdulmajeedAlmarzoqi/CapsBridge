import Carbon.HIToolbox
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
    /// The key left of 1 on ANSI keyboards, and the one next to the left Shift on Apple's ISO keyboards.
    public static let graveAccent: UInt64 = 0x7_0000_0035
    /// The key next to the left Shift on ISO keyboards, and the one left of 1 (§) on Apple's.
    public static let nonUSBackslash: UInt64 = 0x7_0000_0064
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

    /// On an ISO keyboard, the § key left of 1 and the key next to the left Shift reach a VM swapped:
    /// in Windows, § types a backslash and the other key types what § should, such as ذ in Arabic.
    /// Swapping them back puts each where Windows expects it.
    public static let isoKeySwap = [
        KeyMapping(source: HIDKey.graveAccent, destination: HIDKey.nonUSBackslash),
        KeyMapping(source: HIDKey.nonUSBackslash, destination: HIDKey.graveAccent),
    ]

    public var containsBridge: Bool { mappings.contains(Self.bridge) }

    /// The table for ISO keyboards: this one with the two keys swapped, unless the user mapped either.
    public func swappingISOKeys() -> KeyMappingTable {
        let keys = [HIDKey.graveAccent, HIDKey.nonUSBackslash]
        guard !mappings.contains(where: { keys.contains($0.source) }) else { return self }
        return KeyMappingTable(mappings: mappings + Self.isoKeySwap)
    }

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
/// It applies to every keyboard, needs no special permission, and lasts until logout. Setting it
/// replaces each keyboard's own mapping too, so ISO keyboards get theirs after it.
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
        IOHIDEventSystemClientSetProperty(client, Self.property as CFString, Self.raw(table))
    }

    private static func raw(_ table: KeyMappingTable) -> CFArray {
        table.mappings.map {
            [sourceKey: NSNumber(value: $0.source), destinationKey: NSNumber(value: $0.destination)]
        } as CFArray
    }

    public var isBridgeActive: Bool { currentTable().containsBridge }

    /// Whether this process may change the mappings: writes the current table back unchanged.
    public func canRemap() -> Bool { apply(currentTable()) }

    /// Maps Caps Lock to F18 on every keyboard, and swaps § and the key next to the left Shift on
    /// ISO ones. Again when it's active already, for a keyboard connected meanwhile.
    @discardableResult
    public func activateBridge() -> Bool {
        var table = currentTable()
        if !table.containsBridge {
            displaced = table.insertBridge()
            guard apply(table) else { return false }
        }
        let isoTable = table.swappingISOKeys()
        if isoTable != table {
            for keyboard in isoKeyboards() {
                IOHIDServiceClientSetProperty(keyboard, Self.property as CFString, Self.raw(isoTable))
            }
        }
        return true
    }

    /// The connected keyboards with the ISO layout.
    private func isoKeyboards() -> [IOHIDServiceClient] {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        // The type the user chose in Keyboard Setup Assistant, for keyboards that don't say.
        let chosenTypes = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.keyboardtype.plist")?["keyboardtype"] as? [String: Int] ?? [:]
        return services.filter { service in
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 else { return false }
            func number(_ key: String) -> Int? { (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue }
            let ids = [number("ProductID"), number("VendorID"), number("CountryCode") ?? 0].compactMap { $0 }
            let chosenType = ids.count == 3 ? chosenTypes[ids.map(String.init).joined(separator: "-")] : nil
            return KeyboardLayout.isISO(standardType: Self.standardType(of: service), keyboardType: chosenType)
        }
    }

    /// The layout macOS gives a keyboard, which is on the driver or the device in the I/O Registry.
    private static func standardType(of service: IOHIDServiceClient) -> Int? {
        guard let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return (IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "StandardType" as CFString, kCFAllocatorDefault, options) as? NSNumber)?.intValue
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

public enum KeyboardLayout {
    /// `StandardType` is 0 for ANSI, 1 for ISO and 2 for JIS. Keyboards without one have the type
    /// the user chose for them, if any; an unknown keyboard is taken to be ANSI and left as it is.
    public static func isISO(standardType: Int?, keyboardType: Int?) -> Bool {
        if let standardType { return standardType == 1 }
        if let keyboardType, let code = Int16(exactly: keyboardType) {
            return KBGetLayoutType(code) == PhysicalKeyboardLayoutType(kKeyboardISO)
        }
        return false
    }
}
