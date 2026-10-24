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
}
