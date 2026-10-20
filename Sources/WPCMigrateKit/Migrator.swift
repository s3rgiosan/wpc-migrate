import Foundation

public struct MigrationOptions: Sendable {
    public var name: String?
    public var parentFolder: String?
    public var domain: String?
    public var phpVersion: String?
    public var https = false
    public var mailpit = true
    public var resetAdmin = false
    public var symlinks = SymlinkMode.mount
    public var dumpFile: URL?
    public var sourceURL: String?
    public var keepDump = false

    public init() {}
}

public struct MigrationResult: Encodable, Sendable {
    public var localSiteID: String
    public var slug: String
    public var url: String
    public var path: String
    public var sourceURL: String?
    public var dumpStrategy: DumpStrategy?
    /// Set when the dump was kept with `--keep-dump`.
    public var dumpFile: String?
    /// WordPress-relative path to host folder, for each bind-mounted symlink.
    public var mounts: [String: String]
    public var addons: [String]
    public var warnings: [String]
}

/// Moves one LocalWP site into a new wp-container site.
///
/// The site's files go into the folder wpc will use before `wpc create` runs,
/// so wpc's first start finds a complete install and skips its own core copy.
/// Any failure removes the new site again; LocalWP's files and database are
/// only ever read.
public struct Migrator: Sendable {
    public var plan: LocalWPPlan
    public var options: MigrationOptions
    public var wpc: WPCClient
    public var dumper: DatabaseDumping
    public var runner: ProcessRunning
    public var log: @Sendable (String) -> Void

    public init(
        plan: LocalWPPlan,
        options: MigrationOptions,
        wpc: WPCClient,
        dumper: DatabaseDumping,
        runner: ProcessRunning,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.plan = plan
        self.options = options
        self.wpc = wpc
        self.dumper = dumper
        self.runner = runner
        self.log = log
    }

    /// The add-ons the new site gets, in the order they are turned on.
    public var addons: [String] {
        var addons: [String] = []
        if plan.site.xdebug { addons.append("xdebug") }
        if plan.site.redis { addons.append("redis") }
        if plan.site.elasticsearch { addons.append("elasticsearch") }
        if options.mailpit { addons.append("mailpit") }
        return addons
    }

    /// Subdomain networks reach their sites as `*.<slug>.localhost`, which
    /// wp-container serves only through its HTTPS proxy.
    public var usesHTTPS: Bool {
        options.https || plan.site.multisite == .subdomain
    }

    public var siteName: String {
        options.name ?? plan.site.name
    }

    public var siteFolder: URL {
        let parent = options.parentFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? WPCSlug.defaultSitesRoot
        return parent.appendingPathComponent(WPCSlug.make(siteName), isDirectory: true)
    }

    public func run() throws -> MigrationResult {
        var warnings = plan.warnings
        let site = plan.site
        let slug = WPCSlug.make(siteName)
        let folder = siteFolder

        if try wpc.slugs().contains(slug) {
            throw MigrateError.slugTaken(slug)
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            throw MigrateError.siteFolderExists(folder.path)
        }

        if site.multisite == .subdomain, !options.https {
            warnings.append("Turned on HTTPS: subdomain network sites are served as https://<site>.\(WPCSlug.make(siteName)).localhost.")
        }

        var symlinks = options.symlinks
        let mountable = plan.externalLinks.contains(where: \.isMountable)
        if symlinks == .mount, mountable, try !wpc.supportsMounts() {
            symlinks = .copy
            warnings.append("This wpc can't mount folders (no `create --mount`); linked folders were copied.")
        }

        let work = try LocalWPDumper.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }

        log(options.dumpFile == nil ? "Exporting the LocalWP database." : "Preparing the dump.")
        let dumpFile: URL
        var sourceURL = options.sourceURL
        var strategy: DumpStrategy?
        if let provided = options.dumpFile {
            dumpFile = try prepareProvidedDump(provided, in: work)
        } else {
            let result = try dumper.dump(site: site, tablePrefix: plan.tablePrefix, to: work.appendingPathComponent("\(site.id).sql"))
            dumpFile = result.file
            strategy = result.strategy
            sourceURL = sourceURL ?? result.homeURL
            if result.rewrittenLines > 0 {
                warnings.append("Rewrote MySQL 8 collations on \(result.rewrittenLines) schema line(s) for MariaDB.")
            }
        }

        log("Copying WordPress files.")
        let wordpress = folder.appendingPathComponent("wordpress")
        let mounts: [String: String]
        let parked: [String]
        do {
            mounts = try placeFiles(in: wordpress, symlinks: symlinks)
            parked = try BootCode.park(in: wordpress)
        } catch {
            discardFolder(folder)
            throw error
        }

        log(mounts.isEmpty ? "Creating the wp-container site." : "Creating the wp-container site with \(mounts.count) mounted folder(s).")
        let created: WPCSite
        do {
            created = try wpc.create(
                name: siteName,
                parentFolder: folder.deletingLastPathComponent().path,
                domain: options.domain,
                phpVersion: options.phpVersion ?? plan.phpVersion,
                multisite: site.multisite.wpcValue,
                mounts: mounts
            )
        } catch {
            deleteIfRegistered(slug)
            discardFolder(folder)
            throw error
        }

        let importResult: WPCImportResult
        do {
            guard created.slug == slug,
                  URL(fileURLWithPath: created.path).standardizedFileURL == folder.standardizedFileURL else {
                throw MigrateError.unexpectedSite(slug: created.slug, path: created.path)
            }

            for addon in addons {
                log("Turning on \(addon).")
                try wpc.enable(addon, slug: created.slug)
            }
            if usesHTTPS {
                log("Turning on HTTPS.")
                try wpc.enableHTTPS(created.slug)
            }

            log("Starting the site.")
            try wpc.start(created.slug)
            let left = try BootCode.restore(parked, in: wordpress)
            if !left.isEmpty {
                warnings.append("Left in wp-content/\(BootCode.parkingFolder) because the site already has them: \(left.joined(separator: ", ")).")
            }

            log("Importing the database.")
            importResult = try wpc.importDatabase(
                slug: created.slug,
                dump: dumpFile,
                sourceURL: sourceURL,
                resetAdmin: options.resetAdmin
            )
            sourceURL = importResult.sourceURL ?? sourceURL
        } catch {
            log("Migration failed; removing the new site.")
            removeSite(created.slug)
            let createdFolder = URL(fileURLWithPath: created.path).standardizedFileURL
            if createdFolder != folder.standardizedFileURL {
                discardFolder(folder)
            }
            throw error
        }

        if usesHTTPS, let host = URL(string: importResult.localURL ?? created.url)?.host {
            log("Moving links to HTTPS.")
            warnings += upgradeToHTTPS(slug: created.slug, host: host)
        }

        if site.multisite != .none, let leftover = leftoverNetworkURLs(slug: created.slug, sourceURL: sourceURL) {
            warnings.append("Some network sites still point at the LocalWP domain: \(leftover.joined(separator: ", ")).")
        }

        var keptDump: String?
        if options.keepDump {
            if options.dumpFile != nil {
                warnings.append("Your own dump file was left where it is; nothing was copied.")
            } else {
                let destination = folder.appendingPathComponent("localwp-\(site.id).sql")
                do {
                    try FileManager.default.moveItem(at: dumpFile, to: destination)
                    keptDump = destination.path
                } catch {
                    warnings.append("Could not keep the dump (\(error.localizedDescription)).")
                }
            }
        }

        return MigrationResult(
            localSiteID: site.id,
            slug: created.slug,
            url: importResult.localURL ?? created.url,
            path: created.path,
            sourceURL: sourceURL,
            dumpStrategy: strategy,
            dumpFile: keptDump,
            mounts: mounts,
            addons: addons + (usesHTTPS ? ["https"] : []),
            warnings: warnings
        )
    }

    /// Runs the collation rewrite on a user-supplied `.sql` dump. A `.gz`
    /// dump goes to wpc unchanged.
    private func prepareProvidedDump(_ file: URL, in work: URL) throws -> URL {
        guard file.pathExtension.lowercased() == "sql" else { return file }
        let output = work.appendingPathComponent(file.lastPathComponent)
        try CollationRewriter.rewrite(input: file, output: output)
        return output
    }

    /// Clones `app/public` into `destination`, resolves external symlinks, and
    /// writes the rewritten `wp-config.php` and, for single sites, Apache
    /// rewrite rules. Returns the folders to bind-mount.
    func placeFiles(in destination: URL, symlinks: SymlinkMode) throws -> [String: String] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try clone(plan.site.wordpressFolder.path + "/.", to: destination.path)
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("local-xdebuginfo.php"))

        var mounts: [String: String] = [:]
        for link in plan.externalLinks {
            let copied = destination.appendingPathComponent(link.path)
            try FileManager.default.removeItem(at: copied)
            guard link.targetExists else { continue }
            if symlinks == .mount, link.isMountable {
                mounts[link.path] = link.target
            } else {
                try clone(link.target, to: copied.path)
            }
        }

        if let config = plan.wpConfig {
            try WPConfigTransformer.transform(config)
                .write(to: destination.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
        }
        if plan.site.multisite == .none {
            try Htaccess.writeIfMissing(wordpressFolder: destination)
        }
        return mounts
    }

    /// Copies with APFS clones where the volume supports them.
    private func clone(_ source: String, to destination: String) throws {
        let result = try runner.run(URL(fileURLWithPath: "/bin/cp"), ["-c", "-R", source, destination])
        guard result.exitCode == 0 else {
            throw MigrateError.copyFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Rewrites `http://` links to the new host and, for a network, to each of
    /// its sites' hosts. The import keeps each link's scheme, and a LocalWP
    /// site without SSL stores plain `http://` links. Returns a warning with
    /// the command to rerun for each host that failed.
    private func upgradeToHTTPS(slug: String, host: String) -> [String] {
        var hosts = [host]
        if plan.site.multisite != .none,
           let sites = try? wpc.wp(slug, ["site", "list", "--field=url"]), sites.exitCode == 0 {
            let siteHosts = sites.stdout.split(separator: "\n").compactMap { URL(string: String($0))?.host }
            hosts += siteHosts.filter { $0 != host && $0.hasSuffix("." + host) }
        }
        var warnings: [String] = []
        for siteHost in hosts {
            let arguments = ["search-replace", "http://\(siteHost)", "https://\(siteHost)", "--all-tables", "--precise", "--skip-columns=guid"]
            let detail: String
            do {
                let result = try wpc.wp(slug, arguments)
                guard result.exitCode != 0 else { continue }
                detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                detail = "\(error)"
            }
            warnings.append("Moving links to HTTPS failed (\(detail)); rerun: wpc wp \(slug) -- \(arguments.joined(separator: " "))")
        }
        return warnings
    }

    /// Network site URLs that still contain the LocalWP host, or nil when
    /// none do or the check can't run.
    private func leftoverNetworkURLs(slug: String, sourceURL: String?) -> [String]? {
        guard let host = sourceURL.flatMap(URL.init(string:))?.host,
              let result = try? wpc.wp(slug, ["site", "list", "--field=url"]),
              result.exitCode == 0 else { return nil }
        let leftover = result.stdout.split(separator: "\n").map(String.init).filter { $0.contains(host) }
        return leftover.isEmpty ? nil : leftover
    }

    /// Deletes the registered site, telling the user how to when that fails.
    private func removeSite(_ slug: String) {
        do {
            try wpc.delete(slug)
        } catch {
            log("Could not remove the new site (\(error)). Run `wpc delete \(slug)` to clean up.")
        }
    }

    /// Deletes `slug` when wpc still lists it, as after a `create` that failed
    /// once the site was registered.
    private func deleteIfRegistered(_ slug: String) {
        guard let slugs = try? wpc.slugs(), slugs.contains(slug) else { return }
        removeSite(slug)
    }

    /// Moves a folder this run created to the Trash, or deletes it on volumes
    /// without one. The run checked that the folder did not exist beforehand.
    private func discardFolder(_ folder: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return }
        do {
            try manager.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            do {
                try manager.removeItem(at: folder)
            } catch {
                log("Could not remove \(folder.path). Remove it by hand.")
            }
        }
    }
}
