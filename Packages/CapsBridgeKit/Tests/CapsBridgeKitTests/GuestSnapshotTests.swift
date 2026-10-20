import Foundation
import Testing
@testable import CapsBridgeKit

@Suite struct GuestSnapshotTests {
    private func snapshot(map: String?, awaitingRestart: Bool = false, nvdaPath: String? = "C:\\Program Files\\NVDA\\nvda.exe", config: String? = nil, configExists: Bool? = nil) throws -> GuestSnapshot {
        var fields: [String: Any] = [
            "marked": awaitingRestart, "awaitingRestart": awaitingRestart, "nvdaRunning": true,
            "nvdaConfigPath": "C:\\Users\\me\\AppData\\Roaming\\nvda\\nvda.ini",
        ]
        fields["scancodeMap"] = map
        fields["nvdaPath"] = nvdaPath
        fields["nvdaConfig"] = config.map { Data($0.utf8).base64EncodedString() }
        fields["nvdaConfigExists"] = configExists ?? (config != nil)
        let json = try JSONSerialization.data(withJSONObject: fields)
        return try GuestSnapshot(probeOutput: json.base64EncodedString() + "\r\n")
    }

    private let bridgeOnly = "0000000000000000020000003A00690000000000"

    @Test func aMapWrittenSinceTheLastStartWaitsForARestart() throws {
        #expect(try snapshot(map: nil).keyMapping == .missing)
        #expect(try snapshot(map: bridgeOnly, awaitingRestart: true).keyMapping == .awaitingRestart)
        #expect(try snapshot(map: bridgeOnly).keyMapping == .active)
        #expect(try snapshot(map: "0000000000000000020000001D003A0000000000").keyMapping == .missing)
    }

    @Test func knowsWhatItLeftInWindows() throws {
        #expect(try !snapshot(map: nil).hasCapsBridgeTraces)
        #expect(try snapshot(map: bridgeOnly).hasCapsBridgeTraces)
        #expect(try snapshot(map: nil, awaitingRestart: true).hasCapsBridgeTraces)
    }

    @Test func readsNVDAsSetting() throws {
        #expect(try snapshot(map: nil, nvdaPath: nil).nvda == .notInstalled)
        #expect(try snapshot(map: nil, config: nil).nvda == .capsLockOff)
        #expect(try snapshot(map: nil, config: "schemaVersion = 24\n[keyboard]\n\tNVDAModifierKeys = 7\n").nvda == .capsLockOn)
        #expect(try snapshot(map: nil, config: "schemaVersion = 24\n").nvda == .capsLockOff)
    }

    @Test func neverTakesAFileItCouldNotReadForAMissingOne() throws {
        // Writing a fresh configuration over it would lose everything the user set in NVDA.
        let unread = try snapshot(map: nil, config: nil, configExists: true)
        #expect(unread.nvda == .unreadable)
        #expect(throws: NVDAConfig.ReadError.notReadable) { try unread.nvdaConfiguration() }

        let missing = try snapshot(map: nil, config: nil, configExists: false)
        #expect(missing.nvda == .capsLockOff)
        #expect(try missing.nvdaConfiguration().text == "")
    }

    @Test func rejectsAnAnswerThatIsNotTheProbes() {
        #expect(throws: GuestError.unreadableProbe) {
            try GuestSnapshot(probeOutput: "The term 'powershell' is not recognized")
        }
    }
}
