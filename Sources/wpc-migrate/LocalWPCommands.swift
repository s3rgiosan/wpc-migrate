import ArgumentParser
import Foundation
import WPCMigrateKit

struct LocalWPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localwp",
        abstract: "Migrate LocalWP sites.",
        discussion: "`wpc-migrate localwp <site>` is short for `wpc-migrate localwp migrate <site>`.",
        subcommands: [List.self, Migrate.self],
        defaultSubcommand: Migrate.self
    )
}

struct LocalWPLocation: ParsableArguments {
    @Option(help: ArgumentHelp("LocalWP's data folder.", visibility: .hidden))
    var localRoot: String?

    func catalog() throws -> LocalWPCatalog {
        let root = localRoot.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? LocalWPCatalog.defaultRoot
        return try LocalWPCatalog.load(root: root)
    }
}

extension SymlinkMode: ExpressibleByArgument {}

extension LocalWPCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List LocalWP sites.")

        @OptionGroup var location: LocalWPLocation

        @Flag(help: "Emit machine-readable JSON.")
        var json = false

        struct Row: Encodable {
            var id: String
            var name: String
            var domain: String
            var status: String
            var php: String?
            var database: String?
            var multisite: String
            var path: String
        }

        func run() throws {
            do {
                let rows = try location.catalog().sites.map { site in
                    Row(
                        id: site.id,
                        name: site.name,
                        domain: site.domain,
                        status: site.status.rawValue,
                        php: site.phpVersion,
                        database: site.database.map { "\($0.kind.rawValue) \($0.version)" },
                        multisite: site.multisite.rawValue,
                        path: site.path.path
                    )
                }
                if json {
                    try Console.printJSON(["sites": rows])
                    return
                }
                let header = ["ID", "NAME", "DOMAIN", "STATUS", "PHP", "DATABASE", "MULTISITE"]
                let table = rows.map { [$0.id, $0.name, $0.domain, $0.status, $0.php ?? "-", $0.database ?? "-", $0.multisite] }
                print(Self.format([header] + table))
            } catch {
                throw Console.fail(error, json: json)
            }
        }

        static func format(_ rows: [[String]]) -> String {
            let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
            return rows.map { row in
                row.enumerated().map { index, cell in
                    index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }.joined(separator: "  ")
            }.joined(separator: "\n")
        }
    }

    struct Migrate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a LocalWP site into a new wp-container site.",
            discussion: """
                Reads the site's files and database from LocalWP without changing them. \
                A stopped site is exported through a temporary MySQL server on a copy of its data, \
                so LocalWP does not need to be running.
                """
        )

        @Argument(help: "LocalWP site id, domain, or name.")
        var site: String

        @OptionGroup var location: LocalWPLocation

        @Option(help: "Name for the new site (default: the LocalWP site name).")
        var name: String?

        @Option(help: "Parent folder for the new site (default: wp-container's sites folder).")
        var path: String?

        @Option(help: "Custom domain for the new site, e.g. example-site.test.")
        var domain: String?

        @Option(help: "PHP version for the new site (default: the LocalWP site's).")
        var phpVersion: String?

        @Flag(help: "Turn on HTTPS for the new site.")
        var https = false

        @Flag(help: "Leave Mailpit off (LocalWP sites always have it).")
        var noMailpit = false

        @Option(help: "How to bring over symlinks that point outside the site: mount (live) or copy. Asked when omitted.")
        var symlinks: SymlinkMode?

        @Flag(help: "Create or reset wp-container's admin/password login after import.")
        var resetAdmin = false

        @Option(help: "Import this .sql or .sql.gz dump instead of exporting from LocalWP.")
        var dump: String?

        @Option(help: "The dump's site URL, when it can't be read from the database.")
        var sourceURL: String?

        @Flag(help: "Keep the exported dump in the new site's folder.")
        var keepDump = false

        @Flag(help: "Print the plan without changing anything.")
        var dryRun = false

        @Option(help: "Path to the wpc binary (default: found in PATH).")
        var wpc: String?

        @Flag(help: "Show wpc's own progress output.")
        var verbose = false

        @Flag(help: "Emit machine-readable JSON.")
        var json = false

        func run() throws {
            do {
                try migrate()
            } catch {
                throw Console.fail(error, json: json)
            }
        }

        private func migrate() throws {
            let catalog = try location.catalog()
            let localSite = try catalog.find(site)
            let plan = try LocalWPPlan(site: localSite)
            var options = makeOptions()

            let runner = ProcessRunner(echoStderr: verbose)
            let log: @Sendable (String) -> Void = { Console.step($0) }
            let dumper = LocalWPDumper(catalog: catalog, runner: runner, log: log)

            guard let executable = wpc.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? WPCClient.locate() else {
                throw MigrateError.wpcNotFound
            }
            let client = WPCClient(executable: executable, runner: runner)
            var migrator = Migrator(plan: plan, options: options, wpc: client, dumper: dumper, runner: runner, log: log)

            if dryRun {
                let summary = DryRun(
                    plan: plan,
                    options: options,
                    siteFolder: migrator.siteFolder.path,
                    strategy: options.dumpFile == nil ? dumper.strategy(for: localSite) : nil,
                    addons: migrator.addons + (migrator.usesHTTPS ? ["https"] : [])
                )
                if json {
                    try Console.printJSON(summary)
                } else {
                    print(summary.text)
                }
                return
            }

            try client.requireMinimumVersion()
            options.symlinks = try symlinkMode(for: plan.externalLinks.filter(\.targetExists))
            migrator.options = options
            plan.warnings.forEach(Console.warn)
            let result = try migrator.run()

            if json {
                try Console.printJSON(result)
                return
            }
            result.warnings.dropFirst(plan.warnings.count).forEach(Console.warn)
            print("Migrated \(localSite.name) to \(result.url)")
            print("  slug: \(result.slug)")
            print("  folder: \(result.path)")
            print(resetAdmin ? "  login: admin / password" : "  login: your LocalWP site's users and passwords")
            for (path, target) in result.mounts.sorted(by: { $0.key < $1.key }) {
                print("  mount: \(path) -> \(target)")
            }
            if let dumpFile = result.dumpFile { print("  dump: \(dumpFile)") }
        }

        /// `--symlinks` when given; otherwise asks on a terminal. A JSON or
        /// non-interactive run must pass `--symlinks`.
        private func symlinkMode(for links: [ExternalLink]) throws -> SymlinkMode {
            if let symlinks { return symlinks }
            guard !links.isEmpty else { return .mount }
            guard !json, isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
                throw ValidationError("The site has \(links.count) symlink(s) to folders outside it. Pass --symlinks mount or --symlinks copy.")
            }

            var prompt = "This site links to \(links.count) folder(s) outside it:\n"
            for link in links {
                prompt += "  \(link.path) -> \(link.target)\(link.isMountable ? "" : " (copied: can't be mounted)")\n"
            }
            prompt += "Mount them so they stay live, or copy their contents? [M/c] "
            FileHandle.standardError.write(Data(prompt.utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return answer.hasPrefix("c") ? .copy : .mount
        }

        private func makeOptions() -> MigrationOptions {
            var options = MigrationOptions()
            options.name = name
            options.parentFolder = path.map { ($0 as NSString).expandingTildeInPath }
            options.domain = domain
            options.phpVersion = phpVersion
            options.https = https
            options.mailpit = !noMailpit
            options.resetAdmin = resetAdmin
            options.symlinks = symlinks ?? .mount
            options.dumpFile = dump.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            options.sourceURL = sourceURL
            options.keepDump = keepDump
            return options
        }
    }
}

/// What `--dry-run` reports.
struct DryRun: Encodable {
    var localSiteID: String
    var name: String
    var wordpressFolder: String
    var siteFolder: String
    var status: String
    var php: String?
    var wordpress: String?
    var database: String?
    var multisite: String
    var tablePrefix: String
    var dumpStrategy: DumpStrategy?
    var externalLinks: [ExternalLink]
    var addons: [String]
    var warnings: [String]

    init(plan: LocalWPPlan, options: MigrationOptions, siteFolder: String, strategy: DumpStrategy?, addons: [String]) {
        localSiteID = plan.site.id
        name = options.name ?? plan.site.name
        wordpressFolder = plan.site.wordpressFolder.path
        self.siteFolder = siteFolder
        status = plan.site.status.rawValue
        php = options.phpVersion ?? plan.phpVersion
        wordpress = plan.wordpressVersion
        database = plan.site.database.map { "\($0.kind.rawValue) \($0.version)" }
        multisite = plan.site.multisite.rawValue
        tablePrefix = plan.tablePrefix
        dumpStrategy = strategy
        externalLinks = plan.externalLinks
        self.addons = addons
        warnings = plan.warnings
    }

    var text: String {
        var lines = [
            "Site:          \(name) (\(localSiteID), \(status))",
            "Files:         \(wordpressFolder)",
            "New folder:    \(siteFolder)",
            "WordPress:     \(wordpress ?? "unknown")",
            "PHP:           \(php ?? "wpc default")",
            "Database:      \(database ?? "unknown"), table prefix \(tablePrefix)",
            "Multisite:     \(multisite)",
            "Export via:    \(dumpStrategy?.summary ?? "the --dump file")",
            "Add-ons:       \(addons.isEmpty ? "none" : addons.joined(separator: ", "))",
        ]
        lines += externalLinks.filter(\.targetExists).map { "Symlink:       \($0.path) -> \($0.target)" }
        lines += warnings.map { "warning: \($0)" }
        return lines.joined(separator: "\n")
    }
}
