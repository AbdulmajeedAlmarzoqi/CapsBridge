import AppKit
import Foundation

/// Where VMPal is on this Mac.
public struct VMPalInstallation: Equatable, Sendable {
    public var appURL: URL
    public var version: String
    /// VMPal's command line lives in its machine helper, started with `--cli`.
    public var commandLineURL: URL

    public static func find() -> VMPalInstallation? {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: CapsBridgeIdentifiers.vmpal),
            URL(fileURLWithPath: "/Applications/VMPal.app"),
        ]
        for appURL in candidates.compactMap({ $0 }) {
            let tool = appURL.appendingPathComponent("Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine")
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { continue }
            let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return VMPalInstallation(appURL: appURL, version: version ?? "", commandLineURL: tool)
        }
        return nil
    }
}

/// A VM as `vmpal list --json` describes it.
public struct VirtualMachine: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var guest: String
    public var state: String
    public var path: String
    public var system: String?
    public var installed: Bool?
    /// VMPal's "Allow agent control of this VM", which commands inside the VM need.
    public var agentControl: Bool?

    public var isWindows: Bool { guest == "windows" }
    public var isRunning: Bool { state == "running" }
    public var allowsControl: Bool { agentControl ?? true }

    public var bridgeMachine: BridgeMachine { BridgeMachine(id: id, path: path, name: name) }
}

/// `vmpal status <VM> --json`: whether a running VM can run commands now.
public struct MachineStatus: Decodable, Sendable {
    public struct Machine: Decodable, Sendable {
        public struct Tools: Decodable, Sendable {
            public var connected: Bool?
            public var version: String?
        }

        public var tools: Tools?
        public var systemBuild: String?
    }

    public var state: String?
    public var executionAvailable: Bool?
    public var adminExecutionAvailable: Bool?
    public var vm: Machine?

    public var canRunCommands: Bool { executionAvailable ?? false }
    public var canRunAdministratorCommands: Bool { adminExecutionAvailable ?? false }
}

/// `vmpal exec --json`: a command's result.
public struct ExecResult: Decodable, Sendable {
    public var exitCode: Int?
    public var stdout: String?
    public var stderr: String?
    public var timedOut: Bool?
    public var state: String?

    public var succeeded: Bool { exitCode == 0 && timedOut != true }
}

public enum VMPalError: Error, Equatable, Sendable {
    /// vmpal said no: its exit status and what it printed on standard error.
    case commandFailed(command: String, status: Int32, message: String)
    case unreadableAnswer(command: String)
}

/// The parts of VMPal's command line CapsBridge uses.
public protocol VMPalControlling: Sendable {
    func machines() async throws -> [VirtualMachine]
    func status(of machineID: String) async throws -> MachineStatus
    func execute(in machineID: String, program: String, arguments: [String], asAdministrator: Bool, timeout: Int) async throws -> ExecResult
    func copy(localFile: URL, to guestPath: String, in machineID: String) async throws
    func start(_ machineID: String) async throws
    func restart(_ machineID: String) async throws
    func setControlAllowed(_ allowed: Bool, for machineID: String) async throws
}

public struct VMPalCommandLine: VMPalControlling {
    public var installation: VMPalInstallation

    public init(installation: VMPalInstallation) {
        self.installation = installation
    }

    public func machines() async throws -> [VirtualMachine] {
        struct Answer: Decodable { var vms: [VirtualMachine] }
        return try await decode(Answer.self, from: ["list", "--json"]).vms
    }

    public func status(of machineID: String) async throws -> MachineStatus {
        try await decode(MachineStatus.self, from: ["status", machineID, "--json"])
    }

    public func execute(in machineID: String, program: String, arguments: [String], asAdministrator: Bool, timeout: Int) async throws -> ExecResult {
        var command = ["exec", machineID, "--json", "--timeout", "\(timeout)s"]
        if asAdministrator { command.append("--admin") }
        command += ["--", program] + arguments
        // vmpal exits with the command's own status, so a failing command still answers in JSON.
        let output = try await run(command)
        if let result = try? JSONDecoder().decode(ExecResult.self, from: output.standardOutput),
           result.exitCode != nil || result.state != nil {
            return result
        }
        throw VMPalError.commandFailed(command: "exec", status: output.status, message: Self.message(from: output))
    }

    public func copy(localFile: URL, to guestPath: String, in machineID: String) async throws {
        try await runChecked(["cp", localFile.path, "\(machineID):\(guestPath)"])
    }

    public func start(_ machineID: String) async throws {
        try await runChecked(["start", machineID, "--wait", "--timeout", "15m", "--json"])
    }

    public func restart(_ machineID: String) async throws {
        try await runChecked(["restart", machineID, "--wait", "--timeout", "30m", "--json"])
    }

    public func setControlAllowed(_ allowed: Bool, for machineID: String) async throws {
        try await runChecked(["set", machineID, "--agent-control", allowed ? "on" : "off", "--json"])
    }

    private func run(_ command: [String]) async throws -> ProcessOutput {
        try await ProcessRunner.run(installation.commandLineURL, arguments: ["--cli"] + command)
    }

    @discardableResult
    private func runChecked(_ command: [String]) async throws -> ProcessOutput {
        let output = try await run(command)
        guard output.status == 0 else {
            throw VMPalError.commandFailed(command: command[0], status: output.status, message: Self.message(from: output))
        }
        return output
    }

    private func decode<Answer: Decodable>(_ type: Answer.Type, from command: [String]) async throws -> Answer {
        let output = try await runChecked(command)
        guard let answer = try? JSONDecoder().decode(type, from: output.standardOutput) else {
            throw VMPalError.unreadableAnswer(command: command[0])
        }
        return answer
    }

    private static func message(from output: ProcessOutput) -> String {
        let text = output.errorText.isEmpty ? output.outputText : output.errorText
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
