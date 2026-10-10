import Foundation

/// What Windows in a VM looks like at one moment, as the probe script reports it.
public struct GuestSnapshot: Decodable, Equatable, Sendable {
    public var build: String?
    /// The `Scancode Map` registry value in hexadecimal, when there is one.
    public var scancodeMap: String?
    /// Whether CapsBridge's notes are in the registry.
    public var marked: Bool
    /// Whether Windows has yet to restart since CapsBridge wrote the map.
    public var awaitingRestart: Bool
    /// The mapping F18 had before CapsBridge took it, as stored in the map.
    public var replacedMapping: String?
    /// A map CapsBridge couldn't read and replaced, kept whole.
    public var originalScancodeMap: String?
    /// The change CapsBridge made to NVDA's configuration, as JSON.
    public var nvdaChange: String?
    public var nvdaPath: String?
    public var nvdaVersion: String?
    public var nvdaRunning: Bool
    public var nvdaConfigPath: String
    /// The whole of `nvda.ini` in Base64, when the file exists.
    public var nvdaConfig: String?

    /// The probe prints its JSON in Base64, so no code page stands between Windows and the Mac.
    public init(probeOutput: String) throws {
        let line = probeOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let json = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)),
              let snapshot = try? JSONDecoder().decode(GuestSnapshot.self, from: json) else {
            throw GuestError.unreadableProbe
        }
        self = snapshot
    }

    public enum KeyMappingState: Equatable, Sendable {
        /// Windows doesn't turn F18 into Caps Lock.
        case missing
        /// The map is written, and Windows reads it at its next start.
        case awaitingRestart
        case active
    }

    public enum NVDAState: Equatable, Sendable {
        case notInstalled
        case capsLockOn
        case capsLockOff
        /// `nvda.ini` isn't text CapsBridge can read, so it's left alone.
        case unreadable
    }

    public var keyMapping: KeyMappingState {
        guard let scancodeMap, let map = ScancodeMap(hex: scancodeMap), map.containsBridge else { return .missing }
        return awaitingRestart ? .awaitingRestart : .active
    }

    public var nvda: NVDAState {
        guard nvdaPath != nil else { return .notInstalled }
        guard let config = try? nvdaConfiguration() else { return .unreadable }
        return config.capsLockIsNVDAKey ? .capsLockOn : .capsLockOff
    }

    /// NVDA's configuration, or an empty one when NVDA hasn't written its file yet.
    public func nvdaConfiguration() throws -> NVDAConfig {
        guard let nvdaConfig else { return NVDAConfig(text: "") }
        guard let data = Data(base64Encoded: nvdaConfig) else { throw NVDAConfig.ReadError.notUTF8 }
        return try NVDAConfig(data: data)
    }

    public var recordedNVDAChange: NVDAConfig.Change? {
        nvdaChange.flatMap { try? JSONDecoder().decode(NVDAConfig.Change.self, from: Data($0.utf8)) }
    }

    /// Whether Windows still holds anything CapsBridge put there.
    public var hasCapsBridgeTraces: Bool {
        keyMapping != .missing || marked || nvdaChange != nil
    }
}

public enum GuestError: Error, Equatable, Sendable {
    /// A script failed in Windows, with what it printed.
    case scriptFailed(String)
    case unreadableProbe
    case nvdaStillRunning
    case nvdaConfigUnreadable
}

enum GuestScripts {
    /// Reads everything CapsBridge needs to know in one go, and changes nothing.
    static let probe = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    $layout = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
    $map = (Get-ItemProperty -Path $layout -Name 'Scancode Map').'Scancode Map'
    $marker = Get-ItemProperty -Path 'HKLM:\SOFTWARE\CapsBridge'
    $userMarker = Get-ItemProperty -Path 'HKCU:\Software\CapsBridge'
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $nvda = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\nvda.exe').'(default)'
    if (-not $nvda -or -not (Test-Path -LiteralPath $nvda)) {
        $nvda = $null
        foreach ($candidate in @("$env:ProgramFiles\NVDA\nvda.exe", "${env:ProgramFiles(x86)}\NVDA\nvda.exe")) {
            if (Test-Path -LiteralPath $candidate) { $nvda = $candidate; break }
        }
    }
    $configPath = Join-Path $env:APPDATA 'nvda\nvda.ini'
    $config = $null
    if (Test-Path -LiteralPath $configPath) {
        $config = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
    }

    $answer = [ordered]@{
        build = "$($version.CurrentBuild).$($version.UBR)"
        scancodeMap = if ($map) { ($map | ForEach-Object { $_.ToString('X2') }) -join '' } else { $null }
        marked = Test-Path 'HKLM:\SOFTWARE\CapsBridge'
        awaitingRestart = Test-Path 'HKLM:\SOFTWARE\CapsBridge\AwaitingRestart'
        replacedMapping = $marker.ReplacedMapping
        originalScancodeMap = $marker.OriginalScancodeMap
        nvdaChange = $userMarker.NVDAChange
        nvdaPath = $nvda
        nvdaVersion = if ($nvda) { (Get-Item -LiteralPath $nvda).VersionInfo.ProductVersion } else { $null }
        nvdaRunning = [bool](Get-Process -Name nvda)
        nvdaConfigPath = $configPath
        nvdaConfig = $config
    }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($answer | ConvertTo-Json -Compress)))
    """#

    /// Wraps a script that changes something: any error stops it and goes to standard error as plain text.
    static func failing(_ body: String) -> String {
        """
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        try {
        \(body)
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            exit 1
        }
        """
    }

    /// A PowerShell single-quoted literal.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
