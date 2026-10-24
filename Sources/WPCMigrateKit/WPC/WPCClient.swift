import Foundation

/// A failed `wpc` command, with wpc's `{error, detail}` payload when it printed one.
public struct WPCError: Error, Sendable, CustomStringConvertible {
    public var command: String
    public var code: String?
    public var detail: String

    public var description: String {
        let prefix = code.map { "wpc \(command) failed (\($0))" } ?? "wpc \(command) failed"
        return detail.isEmpty ? prefix : "\(prefix): \(detail)"
    }
}

/// The site object `wpc create --json` and `wpc list --json` print.
public struct WPCSite: Decodable, Sendable, Equatable {
    public var slug: String
    public var name: String
    public var path: String
    public var url: String

    public var wordpressFolder: URL {
        URL(fileURLWithPath: path).appendingPathComponent("wordpress")
    }
}

/// The summary `wpc db import --json` prints.
public struct WPCImportResult: Decodable, Sendable, Equatable {
    public var sourceURL: String?
    public var localURL: String?
    public var replacementsMade: Int?
    public var backupPath: String?
}

/// Drives wp-container through its public `wpc` CLI.
public struct WPCClient: Sendable {
    public static let minimumVersion = "0.3.0"

    public var executable: URL
    public var runner: ProcessRunning

    public init(executable: URL, runner: ProcessRunning) {
        self.executable = executable
        self.runner = runner
    }

    /// Finds `wpc`, or the `wp-container` binary it links to, in `PATH`.
    public static func locate(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let folders = (path ?? "").split(separator: ":").map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"]
        for name in ["wpc", "wp-container"] {
            for folder in folders {
                let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    public func version() throws -> String {
        try execute(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func requireMinimumVersion() throws {
        let found = try version()
        if LocalWPPlan.isOlder(found, than: Self.minimumVersion) {
            throw MigrateError.wpcTooOld(found: found, required: Self.minimumVersion)
        }
    }

    /// Creates the site without starting it. `mounts` maps each
    /// WordPress-relative path to the host folder bind-mounted there.
    public func create(
        name: String,
        parentFolder: String?,
        domain: String?,
        phpVersion: String?,
        multisite: String?,
        webServer: WebServer? = nil,
        mounts: [String: String] = [:]
    ) throws -> WPCSite {
        var arguments = ["create", name]
        if let parentFolder { arguments += ["--path", parentFolder] }
        if let domain { arguments += ["--domain", domain] }
        if let phpVersion { arguments += ["--php-version", phpVersion] }
        if let multisite { arguments += ["--multisite", multisite] }
        if let webServer { arguments += ["--web-server", webServer.rawValue] }
        for (path, folder) in mounts.sorted(by: { $0.key < $1.key }) {
            arguments += ["--mount", "\(folder):\(path)"]
        }
        arguments.append("--json")
        return try decode(WPCSite.self, from: try execute(arguments), command: "create")
    }

    /// The `wpc create` options this wpc lists in its help.
    public func createSupport() throws -> CreateSupport {
        let help = try runner.run(executable, ["create", "--help"]).stdout
        return CreateSupport(mounts: help.contains("--mount"), webServer: help.contains("--web-server"))
    }

    /// Slugs of every site and worktree env.
    public func slugs() throws -> Set<String> {
        struct Listing: Decodable {
            struct Entry: Decodable {
                var slug: String
            }
            var sites: [Entry]
            var envs: [Entry]?
        }
        let listing = try decode(Listing.self, from: execute(["list", "--json"]), command: "list")
        return Set(listing.sites.map(\.slug) + (listing.envs ?? []).map(\.slug))
    }

    public func start(_ slug: String) throws {
        _ = try execute(["start", slug, "--json"])
    }

    public func stop(_ slug: String) throws {
        _ = try execute(["stop", slug, "--json"])
    }

    /// Turns on `xdebug`, `redis`, `elasticsearch`, or `mailpit`.
    public func enable(_ addon: String, slug: String) throws {
        _ = try execute([addon, "on", slug, "--json"])
    }

    public func enableHTTPS(_ slug: String) throws {
        _ = try execute(["https", "enable", slug, "--json"])
    }

    public func importDatabase(slug: String, dump: URL, sourceURL: String?, resetAdmin: Bool) throws -> WPCImportResult {
        var arguments = ["db", "import", slug, dump.path, "--no-scrub", "--media", "skip"]
        arguments.append(resetAdmin ? "--admin" : "--no-admin")
        if let sourceURL { arguments += ["--source-url", sourceURL] }
        arguments.append("--json")
        return try decode(WPCImportResult.self, from: execute(arguments), command: "db import")
    }

    /// Runs wp-cli in the site and returns its output. A non-zero wp-cli exit
    /// is returned, not thrown.
    public func wp(_ slug: String, _ arguments: [String]) throws -> ProcessResult {
        let result = try runner.run(executable, ["wp", "--json", slug, "--"] + arguments)
        struct Wrapper: Decodable {
            var stdout: String
            var stderr: String
            var exitCode: Int32
        }
        if let wrapper = try? JSONDecoder().decode(Wrapper.self, from: Data(result.stdout.utf8)) {
            return ProcessResult(exitCode: wrapper.exitCode, stdout: wrapper.stdout, stderr: wrapper.stderr)
        }
        throw Self.error(command: "wp", result: result)
    }

    /// Deletes the site. Its folder goes to the Trash unless `keepFolder` is set.
    public func delete(_ slug: String, keepFolder: Bool = false) throws {
        _ = try execute(["delete", slug] + (keepFolder ? ["--keep-folder"] : []) + ["--json"])
    }

    private func execute(_ arguments: [String]) throws -> String {
        let result = try runner.run(executable, arguments)
        guard result.exitCode == 0 else {
            throw Self.error(command: Self.commandName(arguments), result: result)
        }
        return result.stdout
    }

    /// `db import` and `https enable` for grouped commands, else the first word.
    static func commandName(_ arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        switch first {
        case "db", "https":
            return arguments.prefix(2).joined(separator: " ")
        default:
            return first
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from output: String, command: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(output.utf8))
        } catch {
            throw WPCError(command: command, code: "unexpected_output", detail: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func error(command: String, result: ProcessResult) -> WPCError {
        if let payload = lastJSONObject(in: result.stderr) {
            let code = payload["error"] as? String
            let detail = (payload["detail"] as? String) ?? (payload["short"] as? String) ?? (payload["full"] as? String) ?? ""
            return WPCError(command: command, code: code, detail: detail)
        }
        let lines = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
        return WPCError(command: command, code: nil, detail: lines.isEmpty ? "exit code \(result.exitCode)" : lines)
    }

    /// wpc prints progress lines to stderr around its JSON error, so return the
    /// last top-level JSON object that has an `error` key and ignore any text
    /// before or after it.
    static func lastJSONObject(in text: String) -> [String: Any]? {
        var found: [String: Any]?
        var index = text.startIndex
        while let start = text[index...].firstIndex(of: "{") {
            guard let end = closingBrace(in: text, from: start),
                  let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
                index = text.index(after: start)
                continue
            }
            if object["error"] != nil { found = object }
            index = text.index(after: end)
        }
        return found
    }

    /// The `}` that closes the object opened at `start`, skipping braces inside strings.
    private static func closingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Optional `wpc create` options, which older wpc builds lack.
public struct CreateSupport: Sendable, Equatable {
    /// `--mount`, to bind-mount host folders.
    public var mounts: Bool
    /// `--web-server`, to run the site on nginx.
    public var webServer: Bool
}
