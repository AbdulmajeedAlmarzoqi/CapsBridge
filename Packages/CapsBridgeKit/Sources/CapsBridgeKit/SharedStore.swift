import Foundation

/// A VM whose Windows has been set up to turn F18 back into Caps Lock.
public struct BridgeMachine: Codable, Hashable, Sendable {
    /// The VM's ID, as VMPal gives it.
    public var id: String
    /// Its `.vmpal` folder, which VMPal's machine process is started with.
    public var path: String
    public var name: String

    public init(id: String, path: String, name: String) {
        self.id = id
        self.path = path
        self.name = name
    }

    /// IDs compare without case or dashes: VMPal writes them both ways.
    public static func normalizedID(_ id: String) -> String {
        id.lowercased().filter { $0.isHexDigit }
    }

    public func hasID(_ other: String) -> Bool {
        Self.normalizedID(id) == Self.normalizedID(other)
    }
}

/// What the app decides and the helper acts on.
public struct BridgeConfiguration: Codable, Equatable, Sendable {
    /// VMs the helper forwards Caps Lock to while their window is in front.
    public var machines: [BridgeMachine]
    /// VMs set up but still waiting for Windows to restart. Forwarding to them starts after that:
    /// until Windows restarts, F18 means nothing to it and Caps Lock would do nothing at all.
    public var awaitingRestart: [BridgeMachine]

    public init(machines: [BridgeMachine] = [], awaitingRestart: [BridgeMachine] = []) {
        self.machines = machines
        self.awaitingRestart = awaitingRestart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machines = try container.decodeIfPresent([BridgeMachine].self, forKey: .machines) ?? []
        awaitingRestart = try container.decodeIfPresent([BridgeMachine].self, forKey: .awaitingRestart) ?? []
    }

    public func isEnabled(machineID: String) -> Bool {
        machines.contains { $0.hasID(machineID) }
    }

    public func isAwaitingRestart(machineID: String) -> Bool {
        awaitingRestart.contains { $0.hasID(machineID) }
    }

    public mutating func enable(_ machine: BridgeMachine) {
        forget(machineID: machine.id)
        machines.append(machine)
    }

    public mutating func markAwaitingRestart(_ machine: BridgeMachine) {
        forget(machineID: machine.id)
        awaitingRestart.append(machine)
    }

    public mutating func forget(machineID: String) {
        machines.removeAll { $0.hasID(machineID) }
        awaitingRestart.removeAll { $0.hasID(machineID) }
    }
}

/// What the helper reports about itself, for the app's checks.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var processID: Int32
    public var version: String
    public var executablePath: String
    public var startedAt: Date
    /// Whether Caps Lock is mapped to F18 right now.
    public var bridgeActive: Bool
    public var activeMachineID: String?

    public init(processID: Int32, version: String, executablePath: String, startedAt: Date, bridgeActive: Bool, activeMachineID: String?) {
        self.processID = processID
        self.version = version
        self.executablePath = executablePath
        self.startedAt = startedAt
        self.bridgeActive = bridgeActive
        self.activeMachineID = activeMachineID
    }

    /// Whether the process that wrote this still runs.
    public var isAlive: Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}

/// The folder the app and the helper share: `~/Library/Application Support/CapsBridge`.
public struct SharedStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static let standard = SharedStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("CapsBridge", isDirectory: true))

    public var configurationURL: URL { directory.appendingPathComponent("configuration.json") }
    public var helperStatusURL: URL { directory.appendingPathComponent("helper-status.json") }
    public var displacedMappingsURL: URL { directory.appendingPathComponent("displaced-key-mappings.json") }
    public var updateCheckURL: URL { directory.appendingPathComponent("update-check.json") }

    public func loadUpdateCheckState() -> UpdateCheckState {
        load(UpdateCheckState.self, from: updateCheckURL) ?? UpdateCheckState()
    }

    public func save(_ state: UpdateCheckState) {
        try? write(state, to: updateCheckURL)
    }

    public func loadConfiguration() -> BridgeConfiguration {
        load(BridgeConfiguration.self, from: configurationURL) ?? BridgeConfiguration()
    }

    public func save(_ configuration: BridgeConfiguration) throws {
        try write(configuration, to: configurationURL)
    }

    public func loadHelperStatus() -> HelperStatus? {
        load(HelperStatus.self, from: helperStatusURL)
    }

    public func save(_ status: HelperStatus) throws {
        try write(status, to: helperStatusURL)
    }

    public func loadDisplacedMappings() -> [KeyMapping] {
        load([KeyMapping].self, from: displacedMappingsURL) ?? []
    }

    public func saveDisplacedMappings(_ mappings: [KeyMapping]) {
        if mappings.isEmpty {
            try? FileManager.default.removeItem(at: displacedMappingsURL)
        } else {
            try? write(mappings, to: displacedMappingsURL)
        }
    }

    public func configurationModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configurationURL.path))?[.modificationDate] as? Date
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
