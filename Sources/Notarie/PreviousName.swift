//
// Moving in from an earlier name of the app. When the app is renamed its
// bundle id changes, and with it everything macOS files under that id: the
// settings (UserDefaults domain), the Keychain service, the Application
// Support folder (recordings, transcripts awaiting delivery, the .env). On
// the first launch under the new name this moves them over once:
//
//   - the Application Support folder is renamed, when the new one does not
//     exist yet (so nothing is ever merged or overwritten);
//   - every stored setting the new domain doesn't have is copied;
//   - every secret is copied from the old Keychain service, if the new one
//     has none (macOS may ask once to let the new app read the old item).
//
// Privacy grants (microphone, system audio, calendars) can't be moved: macOS
// ties them to the bundle id, so they are asked for again.
//
// BuildFlavor.previousName says which name came before; nil means nothing
// to move in from. Runs before the single-instance lock, since the lock
// file lives in the folder this moves.
//

import AppKit
import Foundation
import os

private let moveLog = Logger(subsystem: "com.jwiderberg.notarie", category: "PreviousName")

struct PreviousAppName: Sendable {
    /// The earlier CFBundleIdentifier, also its Keychain service.
    let bundleID: String
    /// Shown in the alert when the old app is still running.
    let displayName: String
    /// Its folder under ~/Library/Application Support.
    let supportFolder: String
}

enum PreviousName {
    /// Set once the move has been done (or found nothing to do).
    static let doneKey = "settings.movedFromPreviousName"

    enum Outcome: Equatable {
        case nothingToDo
        case oldAppRunning
        case moved(folder: Bool, settings: Int, secrets: Int)
    }

    /// The folder step on its own: rename old → new only when the old one
    /// exists and the new one doesn't.
    enum FolderAction: Equatable { case rename, keep }
    static func folderAction(oldExists: Bool, newExists: Bool) -> FolderAction {
        oldExists && !newExists ? .rename : .keep
    }

    /// Which of the old domain's entries to copy: stored settings
    /// (`settings.*` and the setting keys outside that namespace) the new
    /// domain doesn't already have. Window frames and system keys stay, and
    /// so does "setup done": the privacy grants have to be given again, and
    /// setup is where that happens.
    static func settingsToCopy(old: [String: Any], new: [String: Any], settingKeys: Set<String>) -> [String: Any] {
        let skip: Set<String> = [doneKey, SettingKey.onboardingCompleted.storageKey]
        return old.filter { key, _ in
            (key.hasPrefix("settings.") || settingKeys.contains(key))
                && !skip.contains(key) && new[key] == nil
        }
    }

    /// Runs the move if this build has a previous name and it hasn't run
    /// yet. Call first thing at launch, inside the bundle only.
    @MainActor
    static func moveInIfNeeded() -> Outcome {
        guard let previous = BuildFlavor.previousName, AppInfo.isRunningInBundle else { return .nothingToDo }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return .nothingToDo }

        // The old app writing into its folder while it is renamed would
        // split a live recording across two folders.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: previous.bundleID).isEmpty {
            moveLog.notice("\(previous.displayName, privacy: .public) is running; not moving its data yet")
            return .oldAppRunning
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldFolder = support.appendingPathComponent(previous.supportFolder, isDirectory: true)
        let newFolder = Outbox.rootURL.deletingLastPathComponent()
        var movedFolder = false
        switch folderAction(oldExists: fm.fileExists(atPath: oldFolder.path),
                            newExists: fm.fileExists(atPath: newFolder.path)) {
        case .rename:
            do {
                try fm.moveItem(at: oldFolder, to: newFolder)
                movedFolder = true
                moveLog.notice("moved \(oldFolder.path, privacy: .public) to \(newFolder.path, privacy: .public)")
            } catch {
                moveLog.error("could not move \(oldFolder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .keep:
            break
        }

        let oldDomain = defaults.persistentDomain(forName: previous.bundleID) ?? [:]
        let newDomain = defaults.persistentDomain(forName: AppInfo.bundleID) ?? [:]
        let nonSecretKeys = Set(SettingKey.allCases.filter { !$0.isSecret }.map(\.storageKey))
        let copied = settingsToCopy(old: oldDomain, new: newDomain, settingKeys: nonSecretKeys)
        for (key, value) in copied { defaults.set(value, forKey: key) }

        var secrets = 0
        for key in SettingKey.allCases where key.isSecret {
            let account = key.storageKey
            do {
                guard try KeychainStore.get(account) == nil,
                      try KeychainStore.exists(account, service: previous.bundleID),
                      let value = try KeychainStore.get(account, service: previous.bundleID)
                else { continue }
                try KeychainStore.set(account, value)
                secrets += 1
            } catch {
                moveLog.error("could not copy the \(account, privacy: .public) secret: \(String(describing: error), privacy: .public)")
            }
        }

        defaults.set(true, forKey: doneKey)
        moveLog.notice("moved in from \(previous.displayName, privacy: .public): folder=\(movedFolder, privacy: .public) settings=\(copied.count, privacy: .public) secrets=\(secrets, privacy: .public)")
        return .moved(folder: movedFolder, settings: copied.count, secrets: secrets)
    }
}
