import AppshotCore
import Foundation

enum CatalogSync {
    enum Failure: Error, CustomStringConvertible {
        case command(String, Int32, String)

        var description: String {
            switch self {
            case .command(let args, let code, let stderr): "\(args) exited \(code): \(stderr.prefix(200))"
            }
        }
    }

    static func refresh(_ source: CatalogSource) async throws -> DiscordCatalog {
        try await Task.detached(priority: .utility) {
            let serversJSON = try run(source, ["server", "list"])
            struct Servers: Decodable { var servers: [Item] }
            struct Item: Decodable { var id: String }
            let ids = try JSONDecoder().decode(Servers.self, from: serversJSON).servers.map(\.id)
            var channels: [String: Data] = [:]
            var threads: [String: Data] = [:]
            for id in ids {
                channels[id] = try run(source, ["channel", "list", "--server", id])
                threads[id] = try run(source, ["thread", "list", "--server", id])
            }
            var catalog = try DiscordCatalog.assemble(servers: serversJSON, channels: channels, threads: threads)
            struct Bot: Decodable { var username: String; var global_name: String? }
            catalog.botName = (try? run(source, ["whoami"])).flatMap { try? JSONDecoder().decode(Bot.self, from: $0) }
                .map { $0.global_name ?? $0.username }
            try catalog.save(to: source.cacheURL)
            return catalog
        }.value
    }

    static func isStale(_ catalog: DiscordCatalog?, source: CatalogSource) -> Bool {
        guard let catalog else { return true }
        let minutes = Double(source.refreshMinutes ?? 15)
        return Date().timeIntervalSince(catalog.updatedAt) > minutes * 60
    }

    static func messages(_ source: CatalogSource, channel: String, limit: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try run(source, ["message", "list", channel, "--limit", String(limit)])
        }.value
    }

    private static func run(_ source: CatalogSource, _ arguments: [String]) throws -> Data {
        let cli = (source.cli as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(filePath: cli)
        process.arguments = arguments + (source.bot.map { ["--bot", $0] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        let cliDir = (cli as NSString).deletingLastPathComponent
        environment["PATH"] = [cliDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]
            .joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        nonisolated(unsafe) var errData = Data()
        let errReader = DispatchQueue.global()
        let group = DispatchGroup()
        group.enter()
        errReader.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw Failure.command(arguments.joined(separator: " "), process.terminationStatus, String(decoding: errData, as: UTF8.self))
        }
        return data
    }
}
