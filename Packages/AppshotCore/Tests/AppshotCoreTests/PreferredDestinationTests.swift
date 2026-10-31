import Foundation
import Testing
@testable import AppshotCore

@Suite struct PreferredDestinationTests {
    private let clipboard = Destination(id: "target:clipboard", name: "Copy to Clipboard", kind: .clipboard)
    private let dm = ChannelOption(key: "dm", label: "My DM", id: "d1", kind: "direct")

    @Test func withoutAnAssistantTheLastDestinationIsUsed() {
        let index = DestinationIndex(pinned: [], catalog: nil, targets: [clipboard])
        #expect(index.preferred(resolved: nil, lastDestination: "target:clipboard") == clipboard)
    }

    @Test func withoutAnAssistantOrALastDestinationThereIsNone() {
        let index = DestinationIndex(pinned: [], catalog: nil, targets: [clipboard])
        #expect(index.preferred(resolved: nil, lastDestination: nil) == nil)
        #expect(index.preferred(resolved: nil, lastDestination: "target:removed") == nil)
    }

    @Test func aLastNonAssistantDestinationWinsOverTheConversation() {
        let index = DestinationIndex(pinned: [dm], catalog: nil, targets: [clipboard])
        let resolved = ResolvedChannel(id: "d1", label: "My DM", source: .lastHandled)
        #expect(index.preferred(resolved: resolved, lastDestination: "target:clipboard") == clipboard)
    }

    @Test func aLastAssistantDestinationDefersToTheConversation() {
        let index = DestinationIndex(pinned: [dm], catalog: nil, targets: [clipboard])
        let resolved = ResolvedChannel(id: "t9", label: "thread …t9", source: .lastReceived)
        // The assistant's current thread is not in the index, so it is named from the resolver.
        #expect(index.preferred(resolved: resolved, lastDestination: "d1") == Destination(id: "t9", name: "thread …t9", kind: .thread))
    }
}
