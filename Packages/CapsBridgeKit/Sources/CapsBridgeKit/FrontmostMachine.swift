import Foundation

/// Works out which configured VM, if any, the frontmost app is showing.
public enum FrontmostMachine {
    /// - Parameters:
    ///   - bundleIdentifier: The frontmost app's bundle identifier.
    ///   - arguments: The frontmost process's arguments. VMPal starts a VM's process with `--machine <folder>`.
    ///   - readMachineID: Reads a VM's ID from its folder, for a VM that was renamed or moved since it was set up.
    public static func machine(
        bundleIdentifier: String?,
        arguments: @autoclosure () -> [String],
        configuration: BridgeConfiguration,
        readMachineID: (_ folder: String) -> String? = machineID(inFolder:)
    ) -> BridgeMachine? {
        guard let bundleIdentifier, !configuration.machines.isEmpty else { return nil }

        if bundleIdentifier.hasPrefix(CapsBridgeIdentifiers.vmpalMachineStubPrefix) {
            let id = String(bundleIdentifier.dropFirst(CapsBridgeIdentifiers.vmpalMachineStubPrefix.count))
            return configuration.machines.first { $0.hasID(id) }
        }

        guard bundleIdentifier == CapsBridgeIdentifiers.vmpalMachine else { return nil }
        let arguments = arguments()
        guard let flag = arguments.firstIndex(of: "--machine"), flag + 1 < arguments.count else { return nil }
        let folder = URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL.path
        if let known = configuration.machines.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == folder }) {
            return known
        }
        guard let id = readMachineID(folder) else { return nil }
        return configuration.machines.first { $0.hasID(id) }
    }

    /// The `id` in a `.vmpal` folder's `config.json`.
    public static func machineID(inFolder folder: String) -> String? {
        let config = URL(fileURLWithPath: folder).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["id"] as? String
    }
}

public enum ProcessArguments {
    /// The arguments a running process was started with, its own name first.
    public static func of(processID: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // The executable's path comes first, padded with NULs, then the arguments.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
