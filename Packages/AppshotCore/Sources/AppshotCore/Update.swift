import CryptoKit
import Foundation

public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts `0.3.2` or a tag like `v0.3.2`; a `-beta` or `+build` suffix is ignored.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<suffix]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        guard !values.isEmpty else { return nil }
        components = values
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The fields of `GET /repos/floweredao/appshot/releases/latest` that the updater reads.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var browserDownloadURL: URL
        public var size: Int
        public var digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var htmlURL: URL
    public var body: String?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public var version: AppVersion
    public var downloadURL: URL
    public var size: Int
    /// Lowercase hex SHA-256 of the zip, published by GitHub as the asset digest.
    public var sha256: String
    public var releaseURL: URL
    public var notes: String
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latest: AppVersion)
    case available(AvailableUpdate)
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case badCurrentVersion(String)
    case badReleaseTag(String)
    case notPublished
    case missingAsset(String)
    case missingDigest
    case untrustedURL(String)
}

public enum UpdateCheck {
    public static let assetName = "Appshot.zip"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/floweredao/appshot/releases/latest")!
    private static let downloadPathPrefix = "/floweredao/appshot/releases/download/"
    private static let releasePagePathPrefix = "/floweredao/appshot/releases/"

    public static func evaluate(_ release: GitHubRelease, currentVersion: String) throws -> UpdateCheckResult {
        guard let current = AppVersion(currentVersion) else { throw UpdateCheckError.badCurrentVersion(currentVersion) }
        guard let latest = AppVersion(release.tagName) else { throw UpdateCheckError.badReleaseTag(release.tagName) }
        guard !release.draft, !release.prerelease else { throw UpdateCheckError.notPublished }
        guard current < latest else { return .upToDate(latest: latest) }
        guard let asset = release.assets.first(where: { $0.name == assetName }) else { throw UpdateCheckError.missingAsset(assetName) }
        guard isTrustedDownload(asset.browserDownloadURL) else { throw UpdateCheckError.untrustedURL(asset.browserDownloadURL.absoluteString) }
        guard isGitHubPage(release.htmlURL, pathPrefix: releasePagePathPrefix) else { throw UpdateCheckError.untrustedURL(release.htmlURL.absoluteString) }
        guard let sha256 = sha256Hex(fromDigest: asset.digest) else { throw UpdateCheckError.missingDigest }
        return .available(AvailableUpdate(
            version: latest,
            downloadURL: asset.browserDownloadURL,
            size: asset.size,
            sha256: sha256,
            releaseURL: release.htmlURL,
            notes: release.body ?? ""
        ))
    }

    /// Downloads come only over HTTPS from this repository's release assets on github.com.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        isGitHubPage(url, pathPrefix: downloadPathPrefix)
    }

    private static func isGitHubPage(_ url: URL, pathPrefix: String) -> Bool {
        guard url.scheme == "https", url.host() == "github.com", url.port == nil, url.user() == nil else { return false }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix(pathPrefix) && !path.contains("/../") && !path.contains("/./")
    }

    /// Parses a GitHub asset digest of the form `sha256:<64 hex digits>`.
    public static func sha256Hex(fromDigest digest: String?) -> String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(hex)
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = 24 * 60 * 60) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}
