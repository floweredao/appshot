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

    @Test func dollarFormsKeepCapturedTextLiteral() throws {
        // `${note}`, ANSI-C `$'…'` strings, and double-quoted `${…}` defaults each change how the shell reads quotes.
        let payloads = ["$(touch pwned)", "`touch pwned`", "\\'; touch pwned; #", "\"; touch pwned; \"", "a}b\\c"]
        let cases: [(template: String, before: String, after: String)] = [
            ("printf %s ${note}", "", ""),
            ("printf %s \"${note}\"", "", ""),
            ("printf %s $'it\\'s {note}'", "it's ", ""),
            ("printf %s \"${X:-{note}}\"", "", ""),
            ("printf %s ${X:-{note}}", "", ""),
        ]
        for item in cases {
            for payload in payloads {
                let dir = FileManager.default.temporaryDirectory.appending(path: "appshot-shell-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let script = CommandTemplate.shell(item.template, values: ["note": payload])
                let output = try runShell(script, in: dir, values: ["note": payload])
                let ran = FileManager.default.fileExists(atPath: dir.appending(path: "pwned").path)
                #expect(!ran, "\(script)")
                #expect(output == item.before + payload + item.after, "\(script)")
            }
        }
    }

    @Test func hereDocumentBodiesKeepCapturedTextLiteral() throws {
        // A here-document body is not shell code, so the value needs no quotes there — and quotes would show up
        // in the text. An unquoted delimiter still expands `$…` and backticks in the body.
        let payloads = ["$(touch pwned)", "`touch pwned`", "'; touch pwned; '", "plain text", "EOF\ntouch pwned"]
        let cases: [(template: String, before: String, after: String)] = [
            ("cat <<EOF\n{note}\nEOF", "", "\n"),
            ("cat <<EOF\npre {note} post\nEOF", "pre ", " post\n"),
            ("cat <<-EOF\n\t{note}\n\tEOF", "", "\n"),
            ("cat <<\"EOF\"\n{note}\nEOF\n", "", "\n"),
            ("printf %s {note}; cat <<EOF\n{note}\nEOF", "", "\n"),
        ]
        for item in cases {
            for payload in payloads {
                // A line equal to the delimiter ends a quoted body early, which no quoting inside it can prevent.
                if item.template.contains("<<\""), payload.contains("EOF") { continue }
                let dir = FileManager.default.temporaryDirectory.appending(path: "appshot-shell-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let script = CommandTemplate.shell(item.template, values: ["note": payload])
                let output = try runShell(script, in: dir, values: ["note": payload])
                let ran = FileManager.default.fileExists(atPath: dir.appending(path: "pwned").path)
                let expected = item.template.hasPrefix("printf") ? payload + payload + item.after
                    : item.before + payload + item.after
                #expect(!ran, "\(script)")
                #expect(output == expected, "\(script)")
            }
        }
    }

    @Test func hereDocumentPlaceholdersRenderWithoutQuotes() {
        // A quoted delimiter makes the body literal, so the value goes in as it is.
        #expect(CommandTemplate.shell("cat <<'EOF'\n{note}\nEOF", values: ["note": "it's $PATH"]) == "cat <<'EOF'\nit's $PATH\nEOF")
        // An unquoted delimiter expands the body, so the value is read from the environment instead.
        #expect(CommandTemplate.shell("cat <<EOF\n{note}\nEOF", values: ["note": "x"]) == "cat <<EOF\n${APPSHOT_NOTE}\nEOF")
        // Only the body is treated as text: the same placeholder after the terminator is quoted as code again.
        #expect(
            CommandTemplate.shell("cat <<EOF\n{note}\nEOF\necho {note}", values: ["note": "a b"])
                == "cat <<EOF\n${APPSHOT_NOTE}\nEOF\necho 'a b'"
        )
        // `<<<` is a here-string, not a here-document.
        #expect(CommandTemplate.shell("cat <<<{note}", values: ["note": "a b"]) == "cat <<<'a b'")
    }

    /// Runs the script the way `TargetDelivery` does: `/bin/sh -c` with the values also in the environment.
    private func runShell(_ script: String, in directory: URL, values: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(CommandTemplate.environment(values)) { $1 }
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
