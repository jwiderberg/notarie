import Foundation
import Testing
@testable import Notarie

/// Moving in from an earlier name: which settings are copied and when the
/// folder is renamed. The launch-time run itself needs the bundle.
@Suite struct PreviousNameTests {
    @Test func folderIsRenamedOnlyIntoNothing() {
        #expect(PreviousName.folderAction(oldExists: true, newExists: false) == .rename)
        #expect(PreviousName.folderAction(oldExists: true, newExists: true) == .keep)
        #expect(PreviousName.folderAction(oldExists: false, newExists: false) == .keep)
        #expect(PreviousName.folderAction(oldExists: false, newExists: true) == .keep)
    }

    @Test func copiesStoredSettingsTheNewDomainLacks() {
        let old: [String: Any] = [
            "settings.recordingsKeepDays": 90,
            "settings.transcriptsFolderPath": "/Users/x/Documents/Old Transcripts",
            "sttLanguage": "sv",
            "settings.systemAudioEngine": "sck",
            "NSWindow Frame Settings": "0 0 100 100",
            "AppleLanguages": ["en"],
        ]
        let new: [String: Any] = ["settings.systemAudioEngine": "taps"]
        let copied = PreviousName.settingsToCopy(old: old, new: new, settingKeys: ["sttLanguage"])
        #expect(Set(copied.keys) == ["settings.recordingsKeepDays", "settings.transcriptsFolderPath", "sttLanguage"])
        #expect(copied["settings.recordingsKeepDays"] as? Int == 90)
    }

    @Test func setupRunsAgainAndTheMoveIsNotCopied() {
        let old: [String: Any] = [
            SettingKey.onboardingCompleted.storageKey: true,
            PreviousName.doneKey: true,
            "settings.recordingsKeepDays": 7,
        ]
        let copied = PreviousName.settingsToCopy(old: old, new: [:], settingKeys: [])
        #expect(Set(copied.keys) == ["settings.recordingsKeepDays"])
    }

    @Test func movesInFromMinnas() {
        #expect(BuildFlavor.previousName?.bundleID == "com.jwiderberg.minnas")
        #expect(BuildFlavor.previousName?.supportFolder == "minnas")
    }
}
