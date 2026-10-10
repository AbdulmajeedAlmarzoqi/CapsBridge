import Foundation
import Testing
@testable import CapsBridgeKit

@Suite struct NVDAConfigTests {
    private let modern = """
    schemaVersion = 24
    [general]
    \tlanguage = Windows
    [keyboard]
    \tkeyboardLayout = laptop
    \tNVDAModifierKeys = 6
    \tspeakTypedWords = 1
    [speech]
    \tsynth = oneCore
    \t[[oneCore]]
    \t\tvoice = David

    """

    @Test func readsTheModifierMask() {
        #expect(NVDAConfig(text: modern).schemaVersion == 24)
        #expect(!NVDAConfig(text: modern).capsLockIsNVDAKey)
        #expect(NVDAConfig(text: modern.replacingOccurrences(of: "= 6", with: "= 7")).capsLockIsNVDAKey)
    }

    @Test func turnsOnOnlyTheCapsLockBit() throws {
        var config = NVDAConfig(text: modern)
        let made = config.enableCapsLock()
        let change = try #require(made)
        #expect(change == NVDAConfig.Change(kind: .maskChanged, previousValue: "6"))
        #expect(config.text == modern.replacingOccurrences(of: "NVDAModifierKeys = 6", with: "NVDAModifierKeys = 7"))
        #expect(config.capsLockIsNVDAKey)
    }

    @Test func leavesAConfigurationThatAlreadyHasIt() {
        let text = modern.replacingOccurrences(of: "= 6", with: "= 5")
        var config = NVDAConfig(text: text)
        #expect(config.enableCapsLock() == nil)
        #expect(config.text == text)
    }

    @Test func undoingRestoresTheFile() throws {
        var config = NVDAConfig(text: modern)
        let made = config.enableCapsLock()
        let change = try #require(made)
        config.undo(change)
        #expect(config.text == modern)
    }

    @Test func undoingKeepsWhatTheUserChangedSince() throws {
        var config = NVDAConfig(text: modern.replacingOccurrences(of: "= 6", with: "= 4"))
        let made = config.enableCapsLock()
        let change = try #require(made)
        #expect(config.text.contains("NVDAModifierKeys = 5"))

        // The user turns numpad Insert back on in NVDA's settings.
        var later = NVDAConfig(text: config.text.replacingOccurrences(of: "= 5", with: "= 7"))
        later.undo(change)
        #expect(later.text.contains("NVDAModifierKeys = 6"))
    }

    @Test func addsTheLineWhenNVDAUsesItsDefault() throws {
        let text = modern.replacingOccurrences(of: "\tNVDAModifierKeys = 6\n", with: "")
        var config = NVDAConfig(text: text)
        #expect(!config.capsLockIsNVDAKey)

        let made = config.enableCapsLock()

        let change = try #require(made)
        #expect(change.kind == .maskAdded)
        #expect(config.text.contains("\tspeakTypedWords = 1\n\tNVDAModifierKeys = 7\n[speech]"))

        config.undo(change)
        #expect(config.text == text)
    }

    @Test func addsTheSectionWhenItIsMissing() throws {
        let text = "schemaVersion = 24\n[general]\n\tlanguage = Windows\n"
        var config = NVDAConfig(text: text)
        let made = config.enableCapsLock()
        let change = try #require(made)
        #expect(change == NVDAConfig.Change(kind: .maskAdded, addedSection: true))
        #expect(config.text == text + "[keyboard]\n\tNVDAModifierKeys = 7\n")

        config.undo(change)
        #expect(config.text == text)
    }

    @Test func usesTheOlderSettingInOlderFiles() throws {
        let text = "schemaVersion = 9\n[keyboard]\n\tuseCapsLockAsNVDAModifierKey = False\n\tkeyboardLayout = laptop\n"
        var config = NVDAConfig(text: text)
        #expect(!config.capsLockIsNVDAKey)

        let made = config.enableCapsLock()

        let change = try #require(made)
        #expect(change == NVDAConfig.Change(kind: .legacyChanged, previousValue: "False"))
        #expect(config.text.contains("\tuseCapsLockAsNVDAModifierKey = True\n"))

        config.undo(change)
        #expect(config.text == text)
    }

    @Test func writesTheOlderSettingIntoAFileNVDAHasNotWrittenYet() throws {
        // NVDA upgrades a file without a schema version, and turns this setting into the mask itself.
        var config = NVDAConfig(text: "")
        let made = config.enableCapsLock()
        let change = try #require(made)
        #expect(change == NVDAConfig.Change(kind: .legacyAdded, addedSection: true))
        #expect(config.text == "[keyboard]\n\tuseCapsLockAsNVDAModifierKey = True\n")
    }

    @Test func undoesInAFileNVDAUpgradedSince() throws {
        var config = NVDAConfig(text: "")
        let made = config.enableCapsLock()
        let change = try #require(made)

        var upgraded = NVDAConfig(text: "schemaVersion = 24\n[keyboard]\n\tNVDAModifierKeys = 7\n")
        upgraded.undo(change)
        #expect(!upgraded.capsLockIsNVDAKey)
        #expect(!upgraded.text.contains("NVDAModifierKeys"))
    }

    @Test func keepsWindowsLineEndingsAndTheByteOrderMark() throws {
        let text = modern.replacingOccurrences(of: "\n", with: "\r\n")
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        var config = try NVDAConfig(data: data)
        config.enableCapsLock()

        let expected = text.replacingOccurrences(of: "NVDAModifierKeys = 6", with: "NVDAModifierKeys = 7")
        #expect(config.data == Data([0xEF, 0xBB, 0xBF]) + Data(expected.utf8))
    }

    @Test func leavesEverythingElseByteForByte() throws {
        let text = "schemaVersion = 24\n# a comment\n[keyboard]\n    NVDAModifierKeys = 2   \n[speech]\n\tsymbolDictionaries = cldr,\n\tname = \"quoted # value\"\n"
        var config = NVDAConfig(text: text)
        config.enableCapsLock()
        #expect(config.text == text.replacingOccurrences(of: "    NVDAModifierKeys = 2   ", with: "    NVDAModifierKeys = 3"))
    }

    @Test func refusesAFileThatIsNotText() {
        #expect(throws: NVDAConfig.ReadError.notUTF8) {
            try NVDAConfig(data: Data([0xFF, 0xFE, 0x00, 0xD8]))
        }
    }
}
