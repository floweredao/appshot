import Foundation
import Testing
@testable import AppshotCore

@Suite struct UpdateTests {
    private let digest = "sha256:18a13284b4ecc21a6d3407addc68a03f7567c7eda8d3a90b67cf623e55fe1726"

    private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false, asset: String = "Appshot.zip", digest: String? = nil) -> Data {
        let digestField = "\"digest\": \"\(digest ?? self.digest)\","
        return Data("""
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/floweredao/appshot/releases/tag/\(tag)",
          "body": "- Notes",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "assets": [{
            "name": "\(asset)",
            \(digestField)
            "size": 2310933,
            "browser_download_url": "https://github.com/floweredao/appshot/releases/download/\(tag)/\(asset)"
          }]
        }
        """.utf8)
    }

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("0.3.10")! > AppVersion("0.3.9")!)
        #expect(AppVersion("v0.4")! > AppVersion("0.3.2")!)
        #expect(AppVersion("0.3")! == AppVersion("v0.3.0")!)
        #expect(AppVersion("1.0.0-beta")!.description == "1.0.0")
        #expect(AppVersion("") == nil)
        #expect(AppVersion("0.x") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func newerReleaseIsAvailableWithItsDigest() throws {
        let release = try GitHubRelease.decode(releaseJSON(tag: "v0.3.3"))
        let result = try UpdateCheck.evaluate(release, currentVersion: "0.3.2")
        guard case .available(let update) = result else { Issue.record("expected an update, got \(result)"); return }
        #expect(update.version.description == "0.3.3")
        #expect(update.sha256 == "18a13284b4ecc21a6d3407addc68a03f7567c7eda8d3a90b67cf623e55fe1726")
        #expect(update.downloadURL.lastPathComponent == "Appshot.zip")
        #expect(update.size == 2310933)
    }

    @Test func sameOrOlderReleaseIsUpToDate() throws {
        let same = try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "v0.3.2")), currentVersion: "0.3.2")
        #expect(same == .upToDate(latest: AppVersion("0.3.2")!))
        let older = try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "v0.3.1")), currentVersion: "0.3.2")
        #expect(older == .upToDate(latest: AppVersion("0.3.1")!))
    }

    @Test func refusesReleasesItCannotVerifyOrInstall() throws {
        #expect(throws: UpdateCheckError.missingDigest) {
            try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "v0.4.0", digest: "sha256:abc")), currentVersion: "0.3.2")
        }
        let noDigest = Data(String(decoding: releaseJSON(tag: "v0.4.0"), as: UTF8.self)
            .replacingOccurrences(of: "\"digest\": \"\(digest)\",", with: "").utf8)
        #expect(throws: UpdateCheckError.missingDigest) {
            try UpdateCheck.evaluate(GitHubRelease.decode(noDigest), currentVersion: "0.3.2")
        }
        #expect(throws: UpdateCheckError.missingAsset("Appshot.zip")) {
            try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "v0.4.0", asset: "Other.zip")), currentVersion: "0.3.2")
        }
        #expect(throws: UpdateCheckError.notPublished) {
            try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "v0.4.0", prerelease: true)), currentVersion: "0.3.2")
        }
        #expect(throws: UpdateCheckError.badReleaseTag("nightly")) {
            try UpdateCheck.evaluate(GitHubRelease.decode(releaseJSON(tag: "nightly")), currentVersion: "0.3.2")
        }
    }

    @Test func onlyHTTPSReleaseAssetsOfThisRepositoryAreTrusted() throws {
        #expect(UpdateCheck.isTrustedDownload(URL(string: "https://github.com/floweredao/appshot/releases/download/v0.3.3/Appshot.zip")!))
        for bad in [
            "http://github.com/floweredao/appshot/releases/download/v0.3.3/Appshot.zip",
            "https://github.com.evil.example/floweredao/appshot/releases/download/v0.3.3/Appshot.zip",
            "https://github.com/someone/appshot/releases/download/v0.3.3/Appshot.zip",
            "https://github.com/floweredao/appshot/releases/download/../../../x/Appshot.zip",
            "https://github.com:8443/floweredao/appshot/releases/download/v0.3.3/Appshot.zip",
            "file:///tmp/Appshot.zip",
        ] {
            #expect(!UpdateCheck.isTrustedDownload(URL(string: bad)!), "\(bad)")
        }
        let foreign = Data(String(decoding: releaseJSON(tag: "v0.4.0"), as: UTF8.self)
            .replacingOccurrences(of: "https://github.com/floweredao/appshot/releases/download", with: "https://example.com/floweredao/appshot/releases/download").utf8)
        #expect(throws: UpdateCheckError.untrustedURL("https://example.com/floweredao/appshot/releases/download/v0.4.0/Appshot.zip")) {
            try UpdateCheck.evaluate(GitHubRelease.decode(foreign), currentVersion: "0.3.2")
        }
        #expect(UpdateCheck.latestReleaseURL.absoluteString == "https://api.github.com/repos/floweredao/appshot/releases/latest")
    }

    @Test func archiveMustMatchThePublishedHash() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "appshot-update-\(UUID().uuidString).zip")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try UpdateCheck.sha256Hex(ofFile: file) == abc)
        try UpdateVerifier.verifyArchive(file, expectedSHA256: abc.uppercased())
        #expect(throws: UpdateVerificationError.hashMismatch(expected: String(repeating: "0", count: 64), actual: abc)) {
            try UpdateVerifier.verifyArchive(file, expectedSHA256: String(repeating: "0", count: 64))
        }
    }

    @Test func appMustCarryTheSameBundleIDAndSignature() throws {
        let calculator = URL(filePath: "/System/Applications/Calculator.app")
        let textEdit = URL(filePath: "/System/Applications/TextEdit.app")
        try UpdateVerifier.verifyApp(calculator, replacing: calculator)
        #expect(throws: UpdateVerificationError.bundleIDMismatch(expected: "com.apple.calculator", actual: "com.apple.TextEdit")) {
            try UpdateVerifier.verifyApp(textEdit, replacing: calculator)
        }
        let unsigned = FileManager.default.temporaryDirectory.appending(path: "appshot-unsigned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsigned) }
        #expect(throws: UpdateVerificationError.self) { try UpdateVerifier.verifyApp(unsigned, replacing: calculator) }
    }

    @Test func downloadedAppMustBeNewer() throws {
        let calculator = URL(filePath: "/System/Applications/Calculator.app")
        let version = try #require(UpdateVerifier.bundleVersion(calculator))
        try UpdateVerifier.verifyNewer(calculator, than: "0.0.1")
        #expect(throws: UpdateVerificationError.notNewer(installed: version, downloaded: version)) {
            try UpdateVerifier.verifyNewer(calculator, than: version)
        }
    }

    @Test func automaticCheckRunsOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    @Test func digestMustBeASCIIHex() {
        let hex = String(repeating: "a", count: 64)
        #expect(UpdateCheck.sha256Hex(fromDigest: "sha256:" + hex) == hex)
        // FULLWIDTH LATIN SMALL LETTER A counts as a hex digit for Character.isHexDigit.
        #expect(UpdateCheck.sha256Hex(fromDigest: "sha256:" + String(repeating: "\u{FF41}", count: 64)) == nil)
    }
}
