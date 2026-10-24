import Foundation
import Testing
@testable import AppshotCore

private func makeConfig(_ root: URL) -> AppshotConfig {
    AppshotConfig(
        stateDir: root.appending(path: "state").path,
        inboxDir: root.appending(path: "inbox/appshot").path,
        channels: [
            ChannelOption(key: "general", label: "#general", id: "100"),
            ChannelOption(key: "coding", label: "#coding", id: "200"),
            ChannelOption(key: "dm", label: "DM", id: "300"),
        ],
        fallbackChannel: "general"
    )
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "appshot-malformed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url.appending(path: "state"), withIntermediateDirectories: true)
    return url
}

private func inboxLine(_ id: String, _ channel: String, _ text: String) -> String {
    #"{"id":"\#(id)","channel":"\#(channel)","kind":"NEW","text":"\#(text)"}"#
}

@Suite struct MalformedStateFileTests {
    @Test func handledIDsWithInvalidUTF8StillNameTheLastID() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        try [inboxLine("1", "200", "a"), inboxLine("2", "300", "b"), inboxLine("3", "100", "c")]
            .joined(separator: "\n").write(to: config.ownerInboxURL, atomically: true, encoding: .utf8)
        // "1", a stray 0xFF byte, then "2".
        try Data([0x31, 0xFF, 0x0A, 0x32, 0x0A]).write(to: config.handledIdsURL)

        let resolved = ChannelResolver(config: config).resolve()
        #expect(resolved == ResolvedChannel(id: "300", label: "DM", source: .lastHandled, lastMessage: "b"))
    }

    @Test func inboxEntryCutInsideACharacterStillCounts() throws {
        let root = try tempRoot()
        let config = makeConfig(root)
        var data = Data((inboxLine("1", "200", "a") + "\n").utf8)
        // The text ends in the first two bytes of a three-byte character.
        data.append(Data(#"{"id":"2","channel":"300","kind":"NEW","text":"cut "#.utf8))
        data.append(contentsOf: [0xE2, 0x80])
        data.append(Data("\"}\n".utf8))
        try data.write(to: config.ownerInboxURL)
        try "2\n".write(to: config.handledIdsURL, atomically: true, encoding: .utf8)

        let resolved = ChannelResolver(config: config).resolve()
        #expect(resolved.id == "300")
        #expect(resolved.source == .lastHandled)
        #expect(resolved.lastMessage?.hasPrefix("cut ") == true)
    }
}
