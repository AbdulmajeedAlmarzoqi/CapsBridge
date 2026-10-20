import Foundation
import Testing
@testable import CapsBridgeKit

@Suite struct KeyMappingTableTests {
    private let capsLockAsEscape = KeyMapping(source: HIDKey.capsLock, destination: 0x7_0000_0029)
    private let unrelated = KeyMapping(source: 0x7_0000_0064, destination: 0x7_0000_0035)

    @Test func addsAndRemovesTheBridge() {
        var table = KeyMappingTable(mappings: [unrelated])
        let displaced = table.insertBridge()
        #expect(displaced.isEmpty)
        #expect(table.mappings == [unrelated, KeyMappingTable.bridge])

        table.removeBridge()
        #expect(table.mappings == [unrelated])
    }

    @Test func putsBackTheCapsLockMappingItDisplaced() {
        var table = KeyMappingTable(mappings: [capsLockAsEscape, unrelated])
        let displaced = table.insertBridge()
        #expect(displaced == [capsLockAsEscape])
        #expect(table.mappings == [unrelated, KeyMappingTable.bridge])

        table.removeBridge(restoring: displaced)
        #expect(table.mappings == [unrelated, capsLockAsEscape])
    }

    @Test func respectsACapsLockMappingMadeMeanwhile() {
        var table = KeyMappingTable(mappings: [capsLockAsEscape])
        let displaced = table.insertBridge()

        let capsLockAsControl = KeyMapping(source: HIDKey.capsLock, destination: 0x7_0000_00E0)
        table.mappings = [capsLockAsControl]
        table.removeBridge(restoring: displaced)
        #expect(table.mappings == [capsLockAsControl])
    }
}

@Suite struct FrontmostMachineTests {
    private let windows = BridgeMachine(
        id: "68EC9C63-9660-4265-ACFF-3FE50D96C41A",
        path: "/Users/someone/Library/Application Support/VMPal/Virtual Machines/Windows 11.vmpal",
        name: "Windows 11")

    private var configuration: BridgeConfiguration { BridgeConfiguration(machines: [windows]) }

    @Test func findsTheMachineByItsFolder() {
        let found = FrontmostMachine.machine(
            bundleIdentifier: CapsBridgeIdentifiers.vmpalMachine,
            arguments: ["VMPalMachine", "--machine", windows.path, "--base", "/somewhere"],
            configuration: configuration,
            readMachineID: { _ in nil })
        #expect(found == windows)
    }

    @Test func findsARenamedMachineByItsID() {
        let found = FrontmostMachine.machine(
            bundleIdentifier: CapsBridgeIdentifiers.vmpalMachine,
            arguments: ["VMPalMachine", "--machine", "/Volumes/Disk/Work PC.vmpal"],
            configuration: configuration,
            readMachineID: { folder in folder == "/Volumes/Disk/Work PC.vmpal" ? "68ec9c63-9660-4265-acff-3fe50d96c41a" : nil })
        #expect(found == windows)
    }

    @Test func findsTheMachineBehindItsDockApp() {
        let found = FrontmostMachine.machine(
            bundleIdentifier: "com.tableplus.VMPal.vm.68ec9c6396604265acff3fe50d96c41a",
            arguments: [],
            configuration: configuration)
        #expect(found == windows)
    }

    @Test func ignoresMachinesThatWereNotSetUp() {
        let found = FrontmostMachine.machine(
            bundleIdentifier: CapsBridgeIdentifiers.vmpalMachine,
            arguments: ["VMPalMachine", "--machine", "/Volumes/Disk/Ubuntu.vmpal"],
            configuration: configuration,
            readMachineID: { _ in "11111111-2222-3333-4444-555555555555" })
        #expect(found == nil)
    }

    @Test(arguments: ["com.apple.Safari", "com.tableplus.VMPal", nil] as [String?])
    func ignoresOtherApps(bundleIdentifier: String?) {
        let found = FrontmostMachine.machine(
            bundleIdentifier: bundleIdentifier,
            arguments: ["App", "--machine", windows.path],
            configuration: configuration)
        #expect(found == nil)
    }

    @Test func doesNotReadArgumentsWithNothingConfigured() {
        var asked = false
        func arguments() -> [String] {
            asked = true
            return []
        }
        _ = FrontmostMachine.machine(
            bundleIdentifier: CapsBridgeIdentifiers.vmpalMachine,
            arguments: arguments(),
            configuration: BridgeConfiguration())
        #expect(!asked)
    }
}

@Suite struct BridgeConfigurationTests {
    private let machine = BridgeMachine(id: "AAAA1111-0000-0000-0000-000000000000", path: "/a.vmpal", name: "A")

    @Test func aMachineIsInOneListAtATime() {
        var configuration = BridgeConfiguration()
        configuration.markAwaitingRestart(machine)
        #expect(configuration.isAwaitingRestart(machineID: machine.id))
        #expect(!configuration.isEnabled(machineID: machine.id))

        configuration.enable(machine)
        #expect(configuration.isEnabled(machineID: "aaaa1111000000000000000000000000"))
        #expect(configuration.awaitingRestart.isEmpty)

        configuration.forget(machineID: machine.id)
        #expect(configuration == BridgeConfiguration())
    }

    @Test func survivesTheDisk() throws {
        let store = SharedStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.removeAll() }
        #expect(store.loadConfiguration() == BridgeConfiguration())

        let configuration = BridgeConfiguration(machines: [machine])
        try store.save(configuration)
        #expect(store.loadConfiguration() == configuration)

        try store.removeAll()
        #expect(store.loadConfiguration() == BridgeConfiguration())
    }

    @Test func keepsDisplacedKeyMappingsUntilTheyAreBack() throws {
        let store = SharedStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? store.removeAll() }
        let capsLockAsEscape = KeyMapping(source: HIDKey.capsLock, destination: 0x7_0000_0029)

        store.saveDisplacedMappings([capsLockAsEscape])
        #expect(store.loadDisplacedMappings() == [capsLockAsEscape])

        store.saveDisplacedMappings([])
        #expect(store.loadDisplacedMappings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.displacedMappingsURL.path))
    }

    @Test func readsAFileWrittenWithFewerFields() throws {
        let configuration = try JSONDecoder().decode(BridgeConfiguration.self, from: Data(#"{"machines":[]}"#.utf8))
        #expect(configuration == BridgeConfiguration())
    }
}
