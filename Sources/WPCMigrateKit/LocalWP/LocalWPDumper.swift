import Foundation

public enum DumpStrategy: String, Sendable, Encodable {
    /// The site is running in LocalWP; dump through its MySQL socket.
    case runningSite = "running-site"
    /// The site is stopped; boot a throwaway MySQL server on an APFS clone of
    /// its data folder.
    case temporaryServer = "temporary-server"

    public var summary: String {
        switch self {
        case .runningSite: return "LocalWP's running MySQL"
        case .temporaryServer: return "a temporary MySQL server on a copy of LocalWP's data"
        }
    }
}

public struct DumpResult: Sendable {
    public var file: URL
    /// The `home` option read from the source database.
    public var homeURL: String?
    public var strategy: DumpStrategy
    public var rewrittenLines: Int
}

public protocol DatabaseDumping: Sendable {
    func strategy(for site: LocalWPSite) -> DumpStrategy
    func dump(site: LocalWPSite, tablePrefix: String, to file: URL) throws -> DumpResult
}

/// Dumps a LocalWP site's database with LocalWP's own MySQL binaries. It never
/// writes to LocalWP's data folder: a stopped site is dumped from a clone.
public struct LocalWPDumper: DatabaseDumping {
    public var catalog: LocalWPCatalog
    public var runner: ProcessRunning
    public var log: @Sendable (String) -> Void

    /// macOS limits a Unix socket path to 104 bytes, including the terminator.
    static let maxSocketPathLength = 103

    public init(catalog: LocalWPCatalog, runner: ProcessRunning, log: @escaping @Sendable (String) -> Void) {
        self.catalog = catalog
        self.runner = runner
        self.log = log
    }

    public func strategy(for site: LocalWPSite) -> DumpStrategy {
        let socket = liveSocket(for: site)
        return FileManager.default.fileExists(atPath: socket.path) ? .runningSite : .temporaryServer
    }

    public func dump(site: LocalWPSite, tablePrefix: String, to file: URL) throws -> DumpResult {
        let bin = try binFolder(for: site)
        let raw = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".raw")
        defer { try? FileManager.default.removeItem(at: raw) }

        let socket = liveSocket(for: site)
        var strategy = DumpStrategy.temporaryServer
        var homeURL: String?
        if FileManager.default.fileExists(atPath: socket.path), ping(bin: bin, socket: socket, site: site) {
            strategy = .runningSite
            log("Dumping from LocalWP's running MySQL.")
            homeURL = try dumpDatabase(bin: bin, socket: socket, site: site, tablePrefix: tablePrefix, to: raw)
        } else {
            log("Starting a temporary MySQL \(site.database?.version ?? "") server on a copy of the site's data.")
            homeURL = try withTemporaryServer(bin: bin, site: site) { socket in
                try dumpDatabase(bin: bin, socket: socket, site: site, tablePrefix: tablePrefix, to: raw)
            }
        }

        let rewritten = try CollationRewriter.rewrite(input: raw, output: file)
        return DumpResult(file: file, homeURL: homeURL, strategy: strategy, rewrittenLines: rewritten)
    }

    /// The `bin` folder of the LocalWP MySQL service matching the site's
    /// version, preferring the highest `+build` and the native architecture.
    public static func binFolder(localRoot: URL, database: LocalWPSite.Database) -> URL? {
        let services = localRoot.appendingPathComponent("lightning-services")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: services.path) else { return nil }

        let version = database.version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? database.version
        let base = "\(database.kind.rawValue)-\(version)"
        let candidates = names
            .filter { $0 == base || $0.hasPrefix(base + "+") }
            .sorted { build(of: $0) > build(of: $1) }

        #if arch(arm64)
        let platforms = ["darwin-arm64", "darwin"]
        #else
        let platforms = ["darwin"]
        #endif

        for name in candidates {
            for platform in platforms {
                let bin = services.appendingPathComponent(name).appendingPathComponent("bin/\(platform)/bin")
                if FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("mysqldump").path) {
                    return bin
                }
            }
        }
        return nil
    }

    /// The leading integer of a version such as `8.0.35+4`, or nil when unparseable.
    static func majorVersion(_ version: String?) -> Int? {
        guard let version else { return nil }
        return Int(version.prefix { $0.isNumber })
    }

    /// MySQL 5.x rejects the 8-only flags; an unparseable version keeps them.
    static func supportsMySQL8Flags(_ version: String?) -> Bool {
        guard let major = majorVersion(version) else { return true }
        return major >= 8
    }

    static func dumpArguments(socket: String, user: String, database: String, version: String?) -> [String] {
        var arguments = ["--socket=\(socket)", "-u\(user)", "--single-transaction", "--set-gtid-purged=OFF"]
        if supportsMySQL8Flags(version) {
            arguments.append("--column-statistics=0")
        }
        arguments += ["--no-tablespaces", "--default-character-set=utf8mb4", database]
        return arguments
    }

    static func serverArguments(work: URL, data: URL, socket: URL, errorLog: URL, version: String?) -> [String] {
        var arguments = [
            "--no-defaults", "--datadir=\(data.path)", "--socket=\(socket.path)",
            "--pid-file=\(work.appendingPathComponent("mysqld.pid").path)",
            "--log-error=\(errorLog.path)", "--tmpdir=\(work.path)",
            "--skip-networking", "--skip-grant-tables",
        ]
        if supportsMySQL8Flags(version) {
            arguments.append("--mysqlx=OFF")
        }
        return arguments
    }

    static func build(of serviceFolder: String) -> Int {
        guard let plus = serviceFolder.lastIndex(of: "+") else { return 0 }
        return Int(serviceFolder[serviceFolder.index(after: plus)...]) ?? 0
    }

    /// A short scratch folder whose socket path fits macOS's limit.
    static func makeWorkFolder() throws -> URL {
        let suffix = String(UUID().uuidString.prefix(8))
        var folder = FileManager.default.temporaryDirectory.appendingPathComponent("wpcm-\(suffix)")
        if folder.appendingPathComponent("mysqld.sock").path.utf8.count > maxSocketPathLength {
            folder = URL(fileURLWithPath: "/tmp/wpcm-\(suffix)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func liveSocket(for site: LocalWPSite) -> URL {
        catalog.runFolder(for: site).appendingPathComponent("mysql/mysqld.sock")
    }

    private func binFolder(for site: LocalWPSite) throws -> URL {
        guard let database = site.database else {
            throw MigrateError.unsupportedDatabase("LocalWP does not record a database service for this site.")
        }
        guard database.kind == .mysql else {
            throw MigrateError.unsupportedDatabase("LocalWP ships no MariaDB client binaries.")
        }
        guard let bin = Self.binFolder(localRoot: catalog.root, database: database) else {
            throw MigrateError.mysqlBinariesMissing(database.version)
        }
        return bin
    }

    private func environment(_ site: LocalWPSite) -> [String: String] {
        ["MYSQL_PWD": site.credentials.password]
    }

    private func ping(bin: URL, socket: URL, site: LocalWPSite) -> Bool {
        let result = try? runner.run(
            bin.appendingPathComponent("mysqladmin"),
            ["--socket=\(socket.path)", "-u\(site.credentials.user)", "ping"],
            environment: environment(site),
            stdoutFile: nil
        )
        return result?.exitCode == 0
    }

    /// Writes the dump to `file` and returns the source `home` URL.
    private func dumpDatabase(bin: URL, socket: URL, site: LocalWPSite, tablePrefix: String, to file: URL) throws -> String? {
        let credentials = site.credentials
        let result = try runner.run(
            bin.appendingPathComponent("mysqldump"),
            Self.dumpArguments(
                socket: socket.path, user: credentials.user,
                database: credentials.database, version: site.database?.version
            ),
            environment: environment(site),
            stdoutFile: file
        )
        guard result.exitCode == 0 else {
            throw MigrateError.dumpFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let query = "SELECT option_value FROM `\(tablePrefix)options` WHERE option_name = 'home'"
        let home = try runner.run(
            bin.appendingPathComponent("mysql"),
            ["--socket=\(socket.path)", "-u\(credentials.user)", "-N", "-B", "-e", query, credentials.database],
            environment: environment(site),
            stdoutFile: nil
        )
        let url = home.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.exitCode == 0 && !url.isEmpty ? url : nil
    }

    /// Clones the site's data folder, serves it from a private socket for the
    /// length of `body`, then shuts the server down and deletes the clone.
    private func withTemporaryServer<T>(bin: URL, site: LocalWPSite, _ body: (URL) throws -> T) throws -> T {
        let source = catalog.runFolder(for: site).appendingPathComponent("mysql/data")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MigrateError.dumpFailed("LocalWP has no data folder for this site at \(source.path).")
        }

        let work = try Self.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let data = work.appendingPathComponent("data")
        let socket = work.appendingPathComponent("mysqld.sock")
        let errorLog = work.appendingPathComponent("mysqld.err")

        let copy = try runner.run(URL(fileURLWithPath: "/bin/cp"), ["-c", "-R", source.path, data.path])
        guard copy.exitCode == 0 else {
            throw MigrateError.dumpFailed("Copying the data folder failed: \(copy.stderr)")
        }

        let server = Process()
        server.executableURL = bin.appendingPathComponent("mysqld")
        server.arguments = Self.serverArguments(
            work: work, data: data, socket: socket, errorLog: errorLog, version: site.database?.version
        )
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        let signals = TerminationSignalGuard(serverPID: server.processIdentifier, work: work)
        defer { signals.cancel() }
        defer { stop(server, bin: bin, socket: socket, site: site) }

        try waitUntilReady(server, bin: bin, socket: socket, site: site, errorLog: errorLog)
        return try body(socket)
    }

    private func waitUntilReady(_ server: Process, bin: URL, socket: URL, site: LocalWPSite, errorLog: URL) throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            guard server.isRunning else {
                throw MigrateError.databaseServerFailed(Self.tail(of: errorLog))
            }
            if FileManager.default.fileExists(atPath: socket.path), ping(bin: bin, socket: socket, site: site) {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw MigrateError.databaseServerFailed("not ready after 60 seconds. \(Self.tail(of: errorLog))")
    }

    private func stop(_ server: Process, bin: URL, socket: URL, site: LocalWPSite) {
        guard server.isRunning else { return }
        _ = try? runner.run(
            bin.appendingPathComponent("mysqladmin"),
            ["--socket=\(socket.path)", "-u\(site.credentials.user)", "shutdown"],
            environment: environment(site),
            stdoutFile: nil
        )
        let deadline = Date().addingTimeInterval(30)
        while server.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if server.isRunning { server.terminate() }
        server.waitUntilExit()
    }

    private static func tail(of log: URL) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let errors = text.split(separator: "\n").filter { $0.contains("[ERROR]") }
        return (errors.isEmpty ? text.split(separator: "\n").suffix(3) : errors.suffix(3)).joined(separator: "\n")
    }
}

/// While a temporary server runs, SIGINT and SIGTERM stop it, delete the work
/// folder, and exit with the conventional 128+signal status.
private final class TerminationSignalGuard: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]
    private let queue = DispatchQueue(label: "wpc-migrate.signals")

    init(serverPID: Int32, work: URL) {
        let workPath = work.path
        var created: [DispatchSourceSignal] = []
        for (number, status) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                Self.stopServer(pid: serverPID)
                try? FileManager.default.removeItem(atPath: workPath)
                exit(status)
            }
            source.resume()
            created.append(source)
        }
        sources = created
    }

    func cancel() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    private static func stopServer(pid: Int32) {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(10)
        while kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
