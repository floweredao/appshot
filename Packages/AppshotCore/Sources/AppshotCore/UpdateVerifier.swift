import Foundation
import Security

public enum UpdateVerificationError: Error, Equatable, Sendable {
    case hashMismatch(expected: String, actual: String)
    case appNotFound
    case unreadableSignature(String)
    case invalidSignature(String)
    case bundleIDMismatch(expected: String, actual: String)
    case teamMismatch(expected: String, actual: String)
    case requirementNotSatisfied
    case notNewer(installed: String, downloaded: String)
}

/// Gates an update before it replaces the running app: the zip must match the published SHA-256,
/// and the unpacked app must carry the same bundle ID, team, and signing certificate as the current app.
public enum UpdateVerifier {
    public static func verifyArchive(_ zip: URL, expectedSHA256: String) throws {
        let actual = try UpdateCheck.sha256Hex(ofFile: zip)
        guard actual == expectedSHA256.lowercased() else {
            throw UpdateVerificationError.hashMismatch(expected: expectedSHA256.lowercased(), actual: actual)
        }
    }

    public static func verifyApp(_ candidate: URL, replacing current: URL) throws {
        let currentCode = try staticCode(current)
        let candidateCode = try staticCode(candidate)

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let validity = SecStaticCodeCheckValidityWithErrors(candidateCode, flags, nil, nil)
        guard validity == errSecSuccess else { throw UpdateVerificationError.invalidSignature(message(validity)) }

        let currentInfo = try signingInfo(currentCode)
        let candidateInfo = try signingInfo(candidateCode)
        let currentID = currentInfo[kSecCodeInfoIdentifier as String] as? String ?? ""
        let candidateID = candidateInfo[kSecCodeInfoIdentifier as String] as? String ?? ""
        guard !currentID.isEmpty, currentID == candidateID else {
            throw UpdateVerificationError.bundleIDMismatch(expected: currentID, actual: candidateID)
        }
        let currentTeam = currentInfo[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        let candidateTeam = candidateInfo[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        guard currentTeam == candidateTeam else {
            throw UpdateVerificationError.teamMismatch(expected: currentTeam, actual: candidateTeam)
        }

        var requirement: SecRequirement?
        let copied = SecCodeCopyDesignatedRequirement(currentCode, [], &requirement)
        guard copied == errSecSuccess, let requirement else { throw UpdateVerificationError.unreadableSignature(message(copied)) }
        guard SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw UpdateVerificationError.requirementNotSatisfied
        }
    }

    public static func bundleVersion(_ app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static func verifyNewer(_ candidate: URL, than installedVersion: String) throws {
        let downloaded = bundleVersion(candidate) ?? ""
        guard let new = AppVersion(downloaded), let old = AppVersion(installedVersion), old < new else {
            throw UpdateVerificationError.notNewer(installed: installedVersion, downloaded: downloaded)
        }
    }

    private static func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateVerificationError.unreadableSignature(message(status)) }
        return code
    }

    private static func signingInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let info = info as? [String: Any] else {
            throw UpdateVerificationError.unreadableSignature(message(status))
        }
        return info
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
