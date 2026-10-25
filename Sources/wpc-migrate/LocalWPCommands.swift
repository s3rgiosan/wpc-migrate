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
extension WebServer: ExpressibleByArgument {}

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

        @Option(help: "Domain for the new site (default: the LocalWP site's domain).")
        var domain: String?

        @Option(help: "PHP version for the new site (default: the LocalWP site's).")
        var phpVersion: String?

        @Option(help: "Web server for the new site: apache or nginx (default: the LocalWP site's).")
        var webServer: WebServer?

        @Flag(help: "Turn on HTTPS for the new site.")
        var https = false

        @Flag(help: "Leave Mailpit off (LocalWP sites always have it).")
        var noMailpit = false

        @Option(help: "How to bring over symlinks that point outside the site: mount (live, folders only), copy, or skip. Asked per link when omitted.")
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
            let plan = try LocalWPPlan(site: localSite, stockNginxFolder: catalog.stockNginxFolder(for: localSite))
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
                    domain: migrator.domain,
                    webServer: migrator.webServer ?? .apache,
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
            if symlinks == nil {
                options.symlinkChoices = try askSymlinkModes(for: plan.externalLinks.filter(\.targetExists))
            }
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
            print("  web server: \(result.webServer.rawValue)")
            print(resetAdmin ? "  login: admin / password" : "  login: your LocalWP site's users and passwords")
            for (path, target) in result.mounts.sorted(by: { $0.key < $1.key }) {
                print("  mount: \(path) -> \(target)")
            }
            for path in result.skippedLinks {
                print("  skipped: \(path)")
            }
            if let dumpFile = result.dumpFile { print("  dump: \(dumpFile)") }
        }

        /// Asks how to bring over each link, on a terminal. A JSON or
        /// non-interactive run must pass `--symlinks`.
        private func askSymlinkModes(for links: [ExternalLink]) throws -> [String: SymlinkMode] {
            guard !links.isEmpty else { return [:] }
            guard !json, isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
                throw ValidationError("The site has \(links.count) symlink(s) to paths outside it. Pass --symlinks mount, copy, or skip.")
            }

            var legend = "This site has \(links.count) symlink(s) to paths outside it. For each one, answer:\n"
            if links.contains(where: \.isMountable) {
                legend += "  m  mount the linked folder, so edits in it show up in the site straight away\n"
            }
            legend += "  c  copy what the link points to into the site\n"
            legend += "  s  skip the link, leaving it out of the new site\n"
            legend += "Press Enter for the capitalized choice.\n"
            Self.prompt(legend)
            var modes: [String: SymlinkMode] = [:]
            for link in links {
                let kind = link.targetIsDirectory ? "folder" : "file"
                let choices = link.isMountable ? "[M/c/s]" : "[C/s]"
                Self.prompt("  \(link.path) -> \(link.target) (\(kind)) \(choices) ")
                modes[link.path] = Self.readSymlinkMode(allowsMount: link.isMountable)
            }
            return modes
        }

        /// Reads one answer, asking again until it is valid. An empty answer or
        /// the end of input picks the capitalized default.
        private static func readSymlinkMode(allowsMount: Bool) -> SymlinkMode {
            let fallback: SymlinkMode = allowsMount ? .mount : .copy
            while let line = readLine() {
                let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
                switch answer {
                case "":
                    return fallback
                case "m" where allowsMount, "mount" where allowsMount:
                    return .mount
                case "c", "copy":
                    return .copy
                case "s", "skip":
                    return .skip
                default:
                    prompt(allowsMount ? "  Answer m, c, or s: " : "  Answer c or s: ")
                }
            }
            return fallback
        }

        private static func prompt(_ text: String) {
            FileHandle.standardError.write(Data(text.utf8))
        }

        private func makeOptions() -> MigrationOptions {
            var options = MigrationOptions()
            options.name = name
            options.parentFolder = path.map { ($0 as NSString).expandingTildeInPath }
            options.domain = domain
            options.phpVersion = phpVersion
            options.webServer = webServer
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
    var domain: String?
    var webServer: WebServer
    var status: String
    var php: String?
    var wordpress: String?
    var database: String?
    var multisite: String
    var tablePrefix: String
    var dumpStrategy: DumpStrategy?
    var externalLinks: [ExternalLink]
    var internalLinks: [InternalLink]
    var nginxIncludes: [String]
    var nginxSiteRules: String?
    var addons: [String]
    var warnings: [String]

    init(plan: LocalWPPlan, options: MigrationOptions, siteFolder: String, domain: String?, webServer: WebServer, strategy: DumpStrategy?, addons: [String]) {
        localSiteID = plan.site.id
        name = options.name ?? plan.site.name
        wordpressFolder = plan.site.wordpressFolder.path
        self.siteFolder = siteFolder
        self.domain = domain
        self.webServer = webServer
        status = plan.site.status.rawValue
        php = options.phpVersion ?? plan.phpVersion
        wordpress = plan.wordpressVersion
        database = plan.site.database.map { "\($0.kind.rawValue) \($0.version)" }
        multisite = plan.site.multisite.rawValue
        tablePrefix = plan.tablePrefix
        dumpStrategy = strategy
        externalLinks = plan.externalLinks
        internalLinks = plan.internalLinks
        nginxIncludes = webServer == .nginx ? plan.nginxIncludes : []
        nginxSiteRules = webServer == .nginx ? plan.nginxSiteRules : nil
        if nginxSiteRules != nil {
            nginxIncludes.append("\(LocalWPPlan.siteRulesFileName) (rules added to site.conf.hbs)")
        }
        self.addons = addons
        warnings = plan.warnings
    }

    var text: String {
        var lines = [
            "Site:          \(name) (\(localSiteID), \(status))",
            "Files:         \(wordpressFolder)",
            "New folder:    \(siteFolder)",
            "Domain:        \(domain ?? "none")",
            "WordPress:     \(wordpress ?? "unknown")",
            "PHP:           \(php ?? "wpc default")",
            "Web server:    \(webServer.rawValue)",
            "Database:      \(database ?? "unknown"), table prefix \(tablePrefix)",
            "Multisite:     \(multisite)",
            "Export via:    \(dumpStrategy?.summary ?? "the --dump file")",
            "Add-ons:       \(addons.isEmpty ? "none" : addons.joined(separator: ", "))",
        ]
        lines += externalLinks.filter(\.targetExists).map { "Symlink:       \($0.path) -> \($0.target) (\($0.targetIsDirectory ? "folder" : "file"))" }
        lines += internalLinks.map { "Symlink:       \($0.path) -> \($0.destination) (made relative)" }
        lines += nginxIncludes.map { "nginx config:  \($0)" }
        lines += warnings.map { "warning: \($0)" }
        return lines.joined(separator: "\n")
    }
}
