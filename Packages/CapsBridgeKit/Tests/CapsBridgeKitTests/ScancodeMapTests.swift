import Foundation
import Testing
@testable import CapsBridgeKit

@Suite struct ScancodeMapTests {
    private let bridgeOnly = "0000000000000000020000003A00690000000000"

    @Test func writesTheBridgeAsWindowsExpectsIt() {
        var map = ScancodeMap()
        let replaced = map.insertBridge()
        #expect(replaced == nil)
        #expect(map.hex == bridgeOnly)
    }

    @Test func readsBackWhatItWrites() throws {
        let map = try #require(ScancodeMap(hex: bridgeOnly))
        #expect(map.entries == [ScancodeMap.bridge])
        #expect(map.containsBridge)
    }

    @Test func keepsTheUsersOwnEntries() throws {
        // Caps Lock as Left Control, the way SharpKeys writes it.
        var map = try #require(ScancodeMap(hex: "0000000000000000020000001D003A0000000000"))
        let capsLockAsControl = ScancodeMap.Entry(source: 0x003A, target: 0x001D)
        #expect(map.entries == [capsLockAsControl])

        map.insertBridge()
        #expect(map.entries == [capsLockAsControl, ScancodeMap.bridge])

        map.removeBridge()
        #expect(map.entries == [capsLockAsControl])
    }

    @Test func replacesAndRestoresAnotherF18Mapping() throws {
        let f18AsEscape = ScancodeMap.Entry(source: 0x0069, target: 0x0001)
        var map = ScancodeMap(entries: [f18AsEscape])

        let replaced = map.insertBridge()
        #expect(replaced == f18AsEscape)
        #expect(map.entries == [ScancodeMap.bridge])

        let stored = try #require(replaced?.hex)
        map.removeBridge(restoring: ScancodeMap.Entry(hex: stored))
        #expect(map.entries == [f18AsEscape])
    }

    @Test func insertingTwiceChangesNothing() {
        var map = ScancodeMap()
        map.insertBridge()
        let replaced = map.insertBridge()
        #expect(replaced == nil)
        #expect(map.entries == [ScancodeMap.bridge])
    }

    @Test func readsExtendedKeys() throws {
        // Right Alt (E0 38) as Right Control (E0 1D).
        let map = try #require(ScancodeMap(hex: "0000000000000000020000001DE038E000000000"))
        #expect(map.entries == [ScancodeMap.Entry(source: 0xE038, target: 0xE01D)])
        #expect(map.hex == "0000000000000000020000001DE038E000000000")
    }

    @Test(arguments: ["", "00", "000000000000000002000000", "0000000000000000050000003A006900", "zz"])
    func rejectsMalformedMaps(hex: String) {
        #expect(ScancodeMap(hex: hex) == nil)
    }

    @Test func anEmptiedMapHasNoEntries() {
        var map = ScancodeMap()
        map.insertBridge()
        map.removeBridge()
        #expect(map.isEmpty)
    }
}
