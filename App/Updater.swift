import AppKit
import AppshotCore
import Foundation

enum UpdaterError: Error {
    case http(Int)
    case insecureResponse
    case unzipFailed
    case cannotReplace(String)
}

@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: Updater.lastCheckKey) as? Date
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @ObservationIgnored private var timer: Timer?

    private static let automaticKey = "updateAutomaticChecks"
    private static let lastCheckKey = "updateLastCheck"
    private static let notifiedKey = "updateNotifiedVersion"

    var automaticChecks: Bool {
        get {
            access(keyPath: \.automaticChecks)
            return UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.automaticChecks) { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
            if newValue { checkAutomaticallyIfDue() }
        }
    }

    var isBusy: Bool { phase == .checking || phase == .installing }

    func startAutomaticChecks() {
        checkAutomaticallyIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomaticallyIfDue() }
        }
    }

    private func checkAutomaticallyIfDue() {
        guard automaticChecks, !isBusy, UpdateCheck.isDue(lastCheck: lastCheck, now: .now) else { return }
        Task {
            guard case .available(let update)? = await check(), UserDefaults.standard.string(forKey: Self.notifiedKey) != update.version.description else { return }
            UserDefaults.standard.set(update.version.description, forKey: Self.notifiedKey)
            presentAvailable(update)
        }
    }

    @discardableResult
    func check() async -> UpdateCheckResult? {
        phase = .checking
        do {
            let result = try await Self.fetch(currentVersion: currentVersion)
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            switch result {
            case .upToDate: phase = .upToDate
            case .available(let update): phase = .available(update)
            }
            return result
        } catch {
            phase = .failed(Self.describe(error))
            return nil
        }
    }

    func checkFromMenu() {
        Task {
            switch await check() {
            case .available(let update)?:
                presentAvailable(update)
            case .upToDate?:
                presentAlert(
                    title: String(localized: "Appshot is up to date"),
                    detail: String(localized: "Version \(currentVersion) is the latest version.")
                )
            case nil:
                if case .failed(let reason) = phase {
                    presentAlert(title: String(localized: "Could not check for updates"), detail: reason)
                }
            }
        }
    }

    func install(_ update: AvailableUpdate) {
        Task {
            do {
                phase = .installing
                try await Self.installAndRelaunch(update, currentVersion: currentVersion)
                NSApp.terminate(nil)
            } catch {
                let reason = Self.describe(error)
                phase = .failed(reason)
                presentAlert(title: String(localized: "Appshot was not updated"), detail: reason)
            }
        }
    }

    private func presentAvailable(_ update: AvailableUpdate) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Appshot \(update.version.description) is available")
        alert.informativeText = String(localized: "You have version \(currentVersion). Appshot checks the download and restarts after the update.")
        alert.addButton(withTitle: String(localized: "Install and Restart"))
        alert.addButton(withTitle: String(localized: "Release Notes"))
        alert.addButton(withTitle: String(localized: "Later"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(update)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(update.releaseURL)
        default: break
        }
    }

    private func presentAlert(title: String, detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: - Work off the main actor

    nonisolated static func fetch(currentVersion: String) async throws -> UpdateCheckResult {
        var request = URLRequest(url: UpdateCheck.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Appshot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSecure(response)
        return try UpdateCheck.evaluate(GitHubRelease.decode(data), currentVersion: currentVersion)
    }

    /// Downloads the release zip and runs every check; returns the verified app inside a private work folder.
    nonisolated static func prepare(_ update: AvailableUpdate, currentVersion: String, replacing current: URL) async throws -> URL {
        guard UpdateCheck.isTrustedDownload(update.downloadURL) else { throw UpdateCheckError.untrustedURL(update.downloadURL.absoluteString) }
        let work = FileManager.default.temporaryDirectory.appending(path: "Appshot-Update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            var request = URLRequest(url: update.downloadURL)
            request.setValue("Appshot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            try requireSecure(response)
            let zip = work.appending(path: UpdateCheck.assetName)
            try FileManager.default.moveItem(at: downloaded, to: zip)
            return try verifyArchive(zip, sha256: update.sha256, currentVersion: currentVersion, replacing: current, work: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Checksum, unpack, bundle ID, team, designated requirement, and version, in that order.
    nonisolated static func verifyArchive(_ zip: URL, sha256: String, currentVersion: String, replacing current: URL, work: URL) throws -> URL {
        try UpdateVerifier.verifyArchive(zip, expectedSHA256: sha256)
        let unpacked = work.appending(path: "unpacked")
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdaterError.unzipFailed }
        let candidate = unpacked.appending(path: "Appshot.app")
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else { throw UpdateVerificationError.appNotFound }
        try UpdateVerifier.verifyApp(candidate, replacing: current)
        try UpdateVerifier.verifyNewer(candidate, than: currentVersion)
        return candidate
    }

    nonisolated static func installAndRelaunch(_ update: AvailableUpdate, currentVersion: String, relaunch: Bool = true) async throws {
        let destination = Bundle.main.bundleURL
        try requireReplaceable(destination)
        let candidate = try await prepare(update, currentVersion: currentVersion, replacing: destination)
        try scheduleReplacement(of: destination, with: candidate, relaunch: relaunch)
    }

    nonisolated private static func requireSecure(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw UpdaterError.insecureResponse }
        guard http.statusCode == 200 else { throw UpdaterError.http(http.statusCode) }
    }

    nonisolated private static func requireReplaceable(_ destination: URL) throws {
        let path = destination.path(percentEncoded: false)
        let parent = destination.deletingLastPathComponent().path(percentEncoded: false)
        guard !path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent),
              FileManager.default.isWritableFile(atPath: path) else {
            throw UpdaterError.cannotReplace(path)
        }
    }

    /// Swaps the bundle after this process exits, restoring the old copy if the move fails, then reopens Appshot.
    nonisolated private static func scheduleReplacement(of destination: URL, with candidate: URL, relaunch: Bool) throws {
        let script = """
        set -u
        pid="$1"; src="${2%/}"; dest="${3%/}"; relaunch="$4"; work="${5%/}"
        mkdir -p "$HOME/Library/Logs/Appshot"; exec >>"$HOME/Library/Logs/Appshot/update.log" 2>&1
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        staging="$dest.update-$$"; backup="$dest.previous-$$"
        if /usr/bin/ditto "$src" "$staging" && mv "$dest" "$backup"; then
          if mv "$staging" "$dest"; then rm -rf "$backup"; echo "$(date) updated $dest"; else mv "$backup" "$dest"; echo "$(date) swap failed; kept $dest"; fi
        else
          echo "$(date) could not stage the update; kept $dest"
        fi
        rm -rf "$staging" "$work"
        if [ "$relaunch" = 1 ]; then /usr/bin/open "$dest"; fi
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", script, "appshot-update",
            String(ProcessInfo.processInfo.processIdentifier),
            candidate.path(percentEncoded: false),
            destination.path(percentEncoded: false),
            relaunch ? "1" : "0",
            candidate.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case UpdateVerificationError.hashMismatch:
            return String(localized: "The download does not match the checksum published with the release, so it was not installed.")
        case UpdateVerificationError.bundleIDMismatch(_, let actual):
            return String(localized: "The download contains a different app (\(actual)), so it was not installed.")
        case UpdateVerificationError.teamMismatch:
            return String(localized: "The downloaded app is signed by a different developer team, so it was not installed.")
        case UpdateVerificationError.requirementNotSatisfied, UpdateVerificationError.invalidSignature, UpdateVerificationError.unreadableSignature:
            return String(localized: "The downloaded app's code signature does not match this copy of Appshot, so it was not installed.")
        case UpdateVerificationError.notNewer(_, let downloaded):
            return String(localized: "The downloaded app (\(downloaded)) is not newer than this version, so it was not installed.")
        case UpdateVerificationError.appNotFound:
            return String(localized: "The download does not contain Appshot.app, so it was not installed.")
        case UpdateCheckError.untrustedURL:
            return String(localized: "The release points outside github.com/floweredao/appshot, so it was not installed.")
        case UpdateCheckError.missingDigest:
            return String(localized: "The release has no published checksum, so it cannot be verified.")
        case UpdateCheckError.missingAsset:
            return String(localized: "The latest release has no Appshot.zip.")
        case UpdateCheckError.notPublished, UpdateCheckError.badReleaseTag, UpdateCheckError.badCurrentVersion, is DecodingError:
            return String(localized: "The latest release on GitHub could not be read.")
        case UpdaterError.http(let status):
            return String(localized: "GitHub answered with HTTP \(status).")
        case UpdaterError.insecureResponse:
            return String(localized: "The update server did not answer over HTTPS.")
        case UpdaterError.unzipFailed:
            return String(localized: "The download could not be unpacked, so it was not installed.")
        case UpdaterError.cannotReplace(let path):
            return String(localized: "Appshot cannot replace itself at \(path). Move Appshot to the Applications folder and try again.")
        default:
            return error.localizedDescription
        }
    }
}
