import Foundation
import Testing
@testable import AppshotCore

@Suite struct TargetSettingsDecodingTests {
    @Test func missingKeysKeepTheSavedAppsAndCommands() {
        let json = #"""
        {"apps":[{"bundleID":"com.example.notes","name":"Notes","paste":"files","pressReturn":true}],
         "commands":[{"id":"c1","name":"Archive","kind":"shell","template":"cp -R {folder} /tmp/x"}],"share":false}
        """#
        let decoded = TargetSettings.decode(Data(json.utf8))
        #expect(decoded.apps == [AppTarget(bundleID: "com.example.notes", name: "Notes", paste: .files, pressReturn: true)])
        #expect(decoded.commands.map(\.id) == ["c1"])
        #expect(!decoded.share)
        #expect(decoded.clipboard)
        #expect(decoded.folder)
        #expect(decoded.lastFolder == nil)
    }

    @Test func emptyObjectAndWrongTypesStillFallBack() {
        #expect(TargetSettings.decode(Data("{}".utf8)) == TargetSettings())
        #expect(TargetSettings.decode(Data(#"{"clipboard":"yes","apps":[]}"#.utf8)) == TargetSettings())
    }
}
