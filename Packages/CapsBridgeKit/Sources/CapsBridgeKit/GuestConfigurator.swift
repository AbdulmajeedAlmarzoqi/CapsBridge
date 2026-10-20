import CryptoKit
import Foundation

/// Runs things inside one VM's Windows.
public protocol GuestShell: Sendable {
    /// Runs a PowerShell script and returns what it printed. Throws `GuestError.scriptFailed` when it fails.
    func runPowerShell(_ script: String, asAdministrator: Bool) async throws -> String
    func copyIntoGuest(_ localFile: URL, to guestPath: String) async throws
    /// Opens a file as double-clicking it would, so what it starts outlives the command that started it.
    func open(_ guestPath: String) async throws
}

/// A VM's Windows, reached through VMPal's command line and the VMPal Tools inside the VM.
public struct VMPalGuestShell: GuestShell {
    public var controller: any VMPalControlling
    public var machineID: String

    public init(controller: any VMPalControlling, machineID: String) {
        self.controller = controller
        self.machineID = machineID
    }

    public func runPowerShell(_ script: String, asAdministrator: Bool) async throws -> String {
        // -EncodedCommand takes UTF-16 in Base64, which no quoting rule on the way can spoil.
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        let result = try await controller.execute(
            in: machineID,
            program: "powershell.exe",
            arguments: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            asAdministrator: asAdministrator,
            timeout: 120)
        guard result.succeeded else {
            let printed = [result.stderr, result.stdout].compactMap { $0 }.first { !$0.isEmpty }
            let message = printed ?? (result.timedOut == true ? "PowerShell timed out." : "PowerShell exited with code \(result.exitCode ?? -1).")
            throw GuestError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout ?? ""
    }

    public func copyIntoGuest(_ localFile: URL, to guestPath: String) async throws {
        try await controller.copy(localFile: localFile, to: guestPath, in: machineID)
    }

    public func open(_ guestPath: String) async throws {
        // Explorer hands the file to the shell that's already running and exits with 1, which means nothing here.
        _ = try await controller.execute(in: machineID, program: "explorer.exe", arguments: [guestPath], asAdministrator: false, timeout: 30)
    }
}

/// Reads and changes what CapsBridge needs in a VM's Windows: the `Scancode Map`, NVDA's setting,
/// and the notes that let it undo both.
public struct GuestConfigurator: Sendable {
    public var shell: any GuestShell

    public init(shell: any GuestShell) {
        self.shell = shell
    }

    public func inspect() async throws -> GuestSnapshot {
        try GuestSnapshot(probeOutput: await shell.runPowerShell(GuestScripts.probe, asAdministrator: false))
    }

    // MARK: - The key mapping

    /// Makes Windows turn F18 into Caps Lock from its next start on.
    public func applyKeyMapping(to snapshot: GuestSnapshot) async throws {
        var map = ScancodeMap()
        var unreadableOriginal: String?
        if let existing = snapshot.scancodeMap, !existing.isEmpty {
            if let parsed = ScancodeMap(hex: existing) {
                map = parsed
            } else {
                unreadableOriginal = existing
            }
        }
        let replaced = map.insertBridge()

        var lines = [
            "$layout = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Keyboard Layout'",
            "$marker = 'HKLM:\\SOFTWARE\\CapsBridge'",
            "if (-not (Test-Path $marker)) { New-Item -Path $marker | Out-Null }",
            "Set-ItemProperty -Path $layout -Name 'Scancode Map' -Type Binary -Value ([byte[]]@(\(Self.byteList(map.registryData))))",
            // A volatile key lives in memory only, so it's gone once Windows has restarted, and tells
            // "written since the last start" without trusting the VM's clock.
            "$machine = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)",
            "$machine.CreateSubKey('SOFTWARE\\CapsBridge\\AwaitingRestart', [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [Microsoft.Win32.RegistryOptions]::Volatile).Close()",
        ]
        // The notes describe this setup only: what an earlier one replaced may have been removed since.
        if let replaced {
            lines.append("Set-ItemProperty -Path $marker -Name 'ReplacedMapping' -Value \(GuestScripts.quoted(replaced.hex))")
        } else {
            lines.append("Remove-ItemProperty -Path $marker -Name 'ReplacedMapping' -ErrorAction SilentlyContinue")
        }
        if let unreadableOriginal {
            lines.append("Set-ItemProperty -Path $marker -Name 'OriginalScancodeMap' -Value \(GuestScripts.quoted(unreadableOriginal))")
        } else {
            lines.append("Remove-ItemProperty -Path $marker -Name 'OriginalScancodeMap' -ErrorAction SilentlyContinue")
        }
        _ = try await shell.runPowerShell(GuestScripts.failing(lines.joined(separator: "\n")), asAdministrator: true)
    }

    /// Takes CapsBridge's entry out of the map, leaving the user's own entries, and removes its notes.
    public func removeKeyMapping(from snapshot: GuestSnapshot) async throws {
        var lines = [
            "$layout = 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Keyboard Layout'",
            "$marker = 'HKLM:\\SOFTWARE\\CapsBridge'",
        ]
        if let existing = snapshot.scancodeMap, var map = ScancodeMap(hex: existing), map.containsBridge {
            map.removeBridge(restoring: snapshot.replacedMapping.flatMap(ScancodeMap.Entry.init(hex:)))
            let restored = map.isEmpty ? snapshot.originalScancodeMap.flatMap { Data(hex: $0) } : map.registryData
            if let restored, !restored.isEmpty {
                lines.append("Set-ItemProperty -Path $layout -Name 'Scancode Map' -Type Binary -Value ([byte[]]@(\(Self.byteList(restored))))")
            } else {
                lines.append("Remove-ItemProperty -Path $layout -Name 'Scancode Map'")
            }
        }
        lines.append("if (Test-Path $marker) { Remove-Item -Path $marker -Recurse -Force }")
        _ = try await shell.runPowerShell(GuestScripts.failing(lines.joined(separator: "\n")), asAdministrator: true)
    }

    // MARK: - NVDA

    /// Makes Caps Lock an NVDA key in NVDA's own configuration. Returns whether anything had to change.
    ///
    /// NVDA writes its configuration when it quits, so it is quit first and the file is read again
    /// after. NVDA is running again afterwards if it was before, whatever happens in between.
    @discardableResult
    public func enableNVDACapsLock() async throws -> Bool {
        let before = try await inspect()
        guard before.nvdaPath != nil, before.nvda == .capsLockOff else { return false }
        try await whileNVDAIsQuit(seenIn: before) { snapshot in
            var config = try nvdaConfiguration(in: snapshot)
            guard let change = config.enableCapsLock() else { return }
            // A change recorded earlier stays the one to undo: it holds what the user had first.
            try await write(config, over: snapshot, recording: snapshot.recordedNVDAChange ?? change)
        }
        return true
    }

    /// Undoes `enableNVDACapsLock`, when CapsBridge was what turned Caps Lock on. Returns whether it changed anything.
    @discardableResult
    public func restoreNVDASetting() async throws -> Bool {
        let before = try await inspect()
        guard let change = before.recordedNVDAChange else { return false }
        guard before.nvdaPath != nil else {
            try await removeUserNotes()
            return false
        }
        try await whileNVDAIsQuit(seenIn: before) { snapshot in
            var config = try nvdaConfiguration(in: snapshot)
            config.undo(change)
            try await write(config, over: snapshot, recording: nil)
        }
        return true
    }

    private func nvdaConfiguration(in snapshot: GuestSnapshot) throws -> NVDAConfig {
        do {
            return try snapshot.nvdaConfiguration()
        } catch {
            throw GuestError.nvdaConfigUnreadable
        }
    }

    /// Quits NVDA when it runs, does the work on Windows as it is once NVDA has written its
    /// configuration, and starts NVDA again, also when the work failed.
    private func whileNVDAIsQuit(seenIn before: GuestSnapshot, _ work: (GuestSnapshot) async throws -> Void) async throws {
        guard before.nvdaRunning, let path = before.nvdaPath else {
            try await work(before)
            return
        }
        do {
            try await quitNVDA(at: path)
            try await work(try await inspect())
        } catch {
            try? await startNVDA(at: path)
            throw error
        }
        try await startNVDA(at: path)
    }

    private func quitNVDA(at path: String) async throws {
        let answer = try await shell.runPowerShell(GuestScripts.failing("""
        Start-Process -FilePath \(GuestScripts.quoted(path)) -ArgumentList '-q' -Wait
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Process -Name nvda -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
            Start-Sleep -Milliseconds 250
        }
        if (Get-Process -Name nvda -ErrorAction SilentlyContinue) { 'running' } else { 'quit' }
        """), asAdministrator: false)
        guard answer.contains("quit") else { throw GuestError.nvdaStillRunning }
    }

    /// Starts NVDA unless it runs already, and waits until it does.
    private func startNVDA(at path: String) async throws {
        // An NVDA that was slow to quit may still be on its way out.
        let check = """
        $deadline = (Get-Date).AddSeconds(%d)
        while (-not (Get-Process -Name nvda -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
            Start-Sleep -Milliseconds 300
        }
        if (Get-Process -Name nvda -ErrorAction SilentlyContinue) { 'running' } else { 'stopped' }
        """
        if try await shell.runPowerShell(String(format: check, 2), asAdministrator: false).contains("running") { return }
        try await shell.open(path)
        if try await shell.runPowerShell(String(format: check, 20), asAdministrator: false).contains("running") { return }
        throw GuestError.nvdaNotRestarted
    }

    /// Replaces `nvda.ini` with one system call, and only when it's still what was read: the new file is
    /// copied beside it and checked first.
    private func write(_ config: NVDAConfig, over snapshot: GuestSnapshot, recording change: NVDAConfig.Change?) async throws {
        let guestPath = snapshot.nvdaConfigPath
        let data = config.data
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("capsbridge-\(UUID().uuidString).ini")
        try data.write(to: local, options: .atomic)
        defer { try? FileManager.default.removeItem(at: local) }

        let staged = guestPath + ".capsbridge-new"
        _ = try await shell.runPowerShell(GuestScripts.failing("""
        $folder = Split-Path -Parent \(GuestScripts.quoted(guestPath))
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        if (Test-Path -LiteralPath \(GuestScripts.quoted(staged))) { Remove-Item -LiteralPath \(GuestScripts.quoted(staged)) -Force }
        """), asAdministrator: false)
        try await shell.copyIntoGuest(local, to: staged)

        let original = snapshot.nvdaConfigData.map(Self.digest) ?? ""
        var lines = [
            "$staged = \(GuestScripts.quoted(staged))",
            "$target = \(GuestScripts.quoted(guestPath))",
            "if ((Get-FileHash -Algorithm SHA256 -LiteralPath $staged).Hash -ne '\(Self.digest(data))') {",
            "    Remove-Item -LiteralPath $staged -Force",
            "    throw 'The copied configuration does not match.'",
            "}",
            "$current = if (Test-Path -LiteralPath $target) { (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash } else { '' }",
            "if ($current -ne '\(original)') {",
            "    Remove-Item -LiteralPath $staged -Force",
            "    throw '\(GuestScripts.changedMarker)'",
            "}",
            "if ($current) { [IO.File]::Replace($staged, $target, [NullString]::Value) } else { Move-Item -LiteralPath $staged -Destination $target }",
        ]
        lines += Self.userNotes(recording: change)
        do {
            _ = try await shell.runPowerShell(GuestScripts.failing(lines.joined(separator: "\n")), asAdministrator: false)
        } catch GuestError.scriptFailed(let message) where message.contains(GuestScripts.changedMarker) {
            throw GuestError.nvdaConfigChanged
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private func removeUserNotes() async throws {
        _ = try await shell.runPowerShell(
            GuestScripts.failing(Self.userNotes(recording: nil).joined(separator: "\n")), asAdministrator: false)
    }

    private static func userNotes(recording change: NVDAConfig.Change?) -> [String] {
        let key = "'HKCU:\\Software\\CapsBridge'"
        guard let change, let json = try? JSONEncoder().encode(change) else {
            return ["if (Test-Path \(key)) { Remove-Item -Path \(key) -Recurse -Force }"]
        }
        return [
            "if (-not (Test-Path \(key))) { New-Item -Path \(key) | Out-Null }",
            "Set-ItemProperty -Path \(key) -Name 'NVDAChange' -Value \(GuestScripts.quoted(String(decoding: json, as: UTF8.self)))",
        ]
    }

    private static func byteList(_ data: Data) -> String {
        data.map { String($0) }.joined(separator: ",")
    }
}
