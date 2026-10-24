import Foundation
import Testing
@testable import AppshotCore

@Suite struct ShellTemplateTests {
    @Test func placeholdersInsideTemplateQuotesStayQuoted() {
        #expect(CommandTemplate.shell("say \"{title}\"", values: ["title": "$(x)"]) == "say \"\"'$(x)'\"\"")
        #expect(CommandTemplate.shell("echo '{note}' done", values: ["note": "it's"]) == "echo '''it'\\''s''' done")
        #expect(CommandTemplate.shell("echo `basename {folder}`", values: ["folder": "a`b"]) == "echo `basename 'a\\`b'`")
        #expect(CommandTemplate.shell("echo \"$(basename {folder})\"", values: ["folder": "/a b"]) == "echo \"$(basename '/a b')\"")
        #expect(CommandTemplate.shell("# Bob's copy\ncp -R {folder} ~/x", values: ["folder": "/a b"]) == "# Bob's copy\ncp -R '/a b' ~/x")
    }

    @Test func capturedTextDoesNotRunInTheShell() throws {
        // A window title or note can hold any of these; none may run `touch`.
        let payloads = ["$(touch pwned)", "`touch pwned`", "'; touch pwned; '", "\"; touch pwned; \"", "x'\"$(touch pwned)\"'y"]
        let cases: [(template: String, before: String, after: String)] = [
            ("printf %s {note}", "", ""),
            ("printf %s \"{note}\"", "", ""),
            ("printf %s '{note}'", "", ""),
            ("printf %s \"pre {note} post\"", "pre ", " post"),
            ("printf %s \"$(printf %s {note})\"", "", ""),
            ("printf %s \"it's {note}\"", "it's ", ""),
        ]
        for item in cases {
            for payload in payloads {
                let dir = FileManager.default.temporaryDirectory.appending(path: "appshot-shell-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let script = CommandTemplate.shell(item.template, values: ["note": payload])
                let output = try runShell(script, in: dir)
                let ran = FileManager.default.fileExists(atPath: dir.appending(path: "pwned").path)
                #expect(!ran, "\(script)")
                #expect(output == item.before + payload + item.after, "\(script)")
            }
        }
    }

    private func runShell(_ script: String, in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
