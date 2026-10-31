import Foundation
import Testing
@testable import AppshotCore

@Suite struct TextClipTests {
    private func insideCodeBlock(_ markdown: String) -> (atMarker: Bool, atEnd: Bool) {
        var inside = false
        var atMarker = false
        var open = 0
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let run = line.prefix { $0 == "`" }.count
            if run >= 3 {
                if inside {
                    if run >= open { inside = false }
                } else {
                    inside = true
                    open = run
                }
                continue
            }
            if line.contains("characters omitted") { atMarker = inside }
        }
        return (atMarker, inside)
    }

    @Test func clipClosesACodeBlockItCutsInHalf() {
        let fence = String(repeating: "`", count: 3)
        let text = "intro\n\n\(fence)\n" + String(repeating: "a", count: 400) + "\n\(fence)\n\ntail\n"
        let clipped = TextComposer.clip(text, limit: 100)
        #expect(clipped.omitted == text.count - 100)
        let state = insideCodeBlock(clipped.text)
        #expect(!state.atMarker)
        #expect(!state.atEnd)
    }

    @Test func clipReopensACodeBlockTheTailStartsIn() {
        let fence = String(repeating: "`", count: 3)
        // The block runs to the end of the text, so the kept tail is still inside it.
        let text = "intro\n\n\(fence)\n" + String(repeating: "b", count: 400) + "\n"
        let clipped = TextComposer.clip(text, limit: 100)
        #expect(clipped.omitted == text.count - 100)
        #expect(!insideCodeBlock(clipped.text).atMarker)
    }

    @Test func clipKeepsLongerFencesMatched() {
        // A field holding Markdown gets a longer fence, which only a run at least as long can close.
        let fence = String(repeating: "`", count: 5)
        let body = String(repeating: "c", count: 200) + "\n```\nnested\n```\n" + String(repeating: "d", count: 200)
        let text = "\(fence)\n" + body + "\n\(fence)\n\nafter\n"
        let clipped = TextComposer.clip(text, limit: 120)
        let state = insideCodeBlock(clipped.text)
        #expect(!state.atMarker)
        #expect(!state.atEnd)
    }

    @Test func clipLeavesTextWithoutFencesByteForByte() {
        let text = String(repeating: "x", count: 200)
        let clipped = TextComposer.clip(text, limit: 10)
        #expect(clipped.text == String(repeating: "x", count: 7) + "\n\n_(190 characters omitted)_\n\n" + String(repeating: "x", count: 3))
        #expect(clipped.omitted == 190)
    }

    @Test func composeKeepsTheOmissionMarkerOutOfAFieldBlock() {
        let composed = TextComposer.compose(
            appName: "Editor", windowTitle: nil, url: nil, document: nil,
            lines: [TextLine(.field, String(repeating: "e", count: 500)), TextLine(.body, "closing line")],
            traversalTruncated: false, limit: 120
        )
        #expect(composed.truncated)
        let state = insideCodeBlock(composed.markdown)
        #expect(!state.atMarker)
        #expect(!state.atEnd)
    }
}
