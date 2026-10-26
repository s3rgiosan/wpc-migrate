import XCTest
@testable import WPCMigrateKit

final class MigratorTests: XCTestCase {
    private var folder: TemporaryFolder!
    private var parent: URL!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
        parent = try folder.folder("sites")
    }

    /// A fake wpc that succeeds at everything; `fail` names a command to fail.
    private func makeRunner(
        fail: String? = nil,
        supportsMounts: Bool = true,
        supportsWebServer: Bool = true,
        existingSlugs: [String] = []
    ) -> FakeRunner {
        let parentPath = parent.path
        return FakeRunner { arguments in
            let command = WPCClient.commandName(arguments)
            if command == fail {
                return ProcessResult(exitCode: 1, stderr: #"{"error": "example_failure", "detail": "example detail"}"#)
            }
            switch command {
            case "list":
                let sites = existingSlugs.map { #"{"slug": "\#($0)"}"# }.joined(separator: ",")
                return ProcessResult(exitCode: 0, stdout: #"{"sites": [\#(sites)], "envs": []}"#)
            case "create" where arguments.contains("--help"):
                var help = ["--json"]
                if supportsMounts { help.append("--mount <host-folder:path>") }
                if supportsWebServer { help.append("--web-server <web-server>") }
                return ProcessResult(exitCode: 0, stdout: help.joined(separator: "\n"))
            case "create":
                let site = #"{"name": "Example Site", "slug": "example-site", "path": "\#(parentPath)/example-site", "url": "http://127.0.0.1:8899"}"#
                return ProcessResult(exitCode: 0, stdout: site)
            case "wp":
                return ProcessResult(exitCode: 0, stdout: #"{"stdout": "http://127.0.0.1:8899/\nhttp://127.0.0.1:8899/example/\n", "stderr": "", "exitCode": 0}"#)
            case "db import":
                return ProcessResult(exitCode: 0, stdout: #"{"localURL": "http://127.0.0.1:8899", "sourceURL": "https://example-site.test"}"#)
            default:
                return ProcessResult(exitCode: 0, stdout: "{}")
            }
        }
    }

    private func makeMigrator(
        runner: FakeRunner,
        dumper: FakeDumper = FakeDumper(),
        configure: (inout MigrationOptions) -> Void = { _ in }
    ) throws -> Migrator {
        let plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("local/example-site")))
        var options = MigrationOptions()
        options.parentFolder = parent.path
        configure(&options)
        return Migrator(
            plan: plan,
            options: options,
            wpc: WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner),
            dumper: dumper,
            runner: runner,
            log: { _ in }
        )
    }

    func testRunsWPCStepsInOrderAndPlacesFiles() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner).run()

        XCTAssertEqual(runner.calls.map(WPCClient.commandName), ["list", "create", "create", "xdebug", "mailpit", "start", "db import"])
        XCTAssertEqual(runner.calls[1], ["create", "--help"])
        XCTAssertTrue(runner.calls[2].contains("--path"))
        XCTAssertTrue(runner.calls[6].contains("--no-admin"))
        XCTAssertEqual(result.url, "http://127.0.0.1:8899")
        XCTAssertEqual(result.sourceURL, "https://example-site.test")
        XCTAssertEqual(result.addons, ["xdebug", "mailpit"])

        let wordpress = parent.appendingPathComponent("example-site/wordpress")
        let config = try String(contentsOf: wordpress.appendingPathComponent("wp-config.php"), encoding: .utf8)
        XCTAssertTrue(config.contains("getenv( 'WORDPRESS_DB_NAME' )"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wordpress.appendingPathComponent(".htaccess").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wordpress.appendingPathComponent("index.php").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wordpress.appendingPathComponent("local-xdebuginfo.php").path))
    }

    func testCreatesTheSiteOnTheLocalWPDomain() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        _ = try makeMigrator(runner: runner).run()

        let create = try XCTUnwrap(runner.calls.first { WPCClient.commandName($0) == "create" && !$0.contains("--help") })
        let index = try XCTUnwrap(create.firstIndex(of: "--domain"))
        XCTAssertEqual(create[index + 1], "example-site.test")
    }

    func testDomainOptionReplacesTheLocalWPDomain() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        _ = try makeMigrator(runner: runner) { $0.domain = "other-site.test" }.run()

        let create = try XCTUnwrap(runner.calls.first { WPCClient.commandName($0) == "create" && !$0.contains("--help") })
        let index = try XCTUnwrap(create.firstIndex(of: "--domain"))
        XCTAssertEqual(create[index + 1], "other-site.test")
    }

    func testTurnsOnHTTPSWhenTheLocalWPSiteUsesIt() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner, dumper: FakeDumper(homeURL: "https://example-site.test")).run()

        let commands = runner.calls.map(WPCClient.commandName)
        XCTAssertEqual(Array(commands.prefix(7)), ["list", "create", "create", "xdebug", "mailpit", "https enable", "start"])
        XCTAssertEqual(result.addons.last, "https")
    }

    func testTurnsOnRedisForARedisObjectCacheDropIn() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/app/public/wp-content/object-cache.php", Fixtures.redisObjectCache)
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner).run()

        let commands = runner.calls.map(WPCClient.commandName)
        XCTAssertEqual(Array(commands.prefix(7)), ["list", "create", "create", "xdebug", "redis", "mailpit", "start"])
        XCTAssertEqual(result.addons, ["xdebug", "redis", "mailpit"])
        XCTAssertTrue(result.warnings.contains("Turned on Redis: wp-content/object-cache.php is a Redis object-cache drop-in."))
    }

    func testCreatesNginxSitesOnNginx() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner).run()

        let create = try XCTUnwrap(runner.calls.first { WPCClient.commandName($0) == "create" && !$0.contains("--help") })
        let index = try XCTUnwrap(create.firstIndex(of: "--web-server"))
        XCTAssertEqual(create[index + 1], "nginx")
        XCTAssertEqual(result.webServer, .nginx)
    }

    func testRunsOnApacheWhenWPCHasNoNginx() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner(supportsWebServer: false)

        let result = try makeMigrator(runner: runner).run()

        XCTAssertFalse(runner.calls.contains { $0.contains("--web-server") })
        XCTAssertEqual(result.webServer, .apache)
        XCTAssertTrue(result.warnings.contains("This wpc can't run nginx (no `create --web-server`); the site runs on Apache."))
    }

    func testApacheNeedsNoWebServerFlag() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner) { $0.webServer = .apache }.run()

        XCTAssertFalse(runner.calls.contains { $0.contains("--help") || $0.contains("--web-server") })
        XCTAssertEqual(result.webServer, .apache)
    }

    func testCopiesIncludedNginxConfigForNginxSites() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/conf/nginx/example-proxy.conf", "location /example/ { return 204; }\n")
        let runner = makeRunner()
        var migrator = try makeMigrator(runner: runner)
        migrator.plan.nginxIncludes = ["example-proxy.conf"]

        _ = try migrator.run()

        let copied = parent.appendingPathComponent("example-site/nginx/example-proxy.conf")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "location /example/ { return 204; }\n")
    }

    func testWritesSiteConfRulesForNginxSites() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner()
        var migrator = try makeMigrator(runner: runner)
        migrator.plan.nginxSiteRules = "location /example/ { return 204; }\n"

        _ = try migrator.run()

        let written = parent.appendingPathComponent("example-site/nginx/\(LocalWPPlan.siteRulesFileName)")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "location /example/ { return 204; }\n")
    }

    func testLeavesNginxConfigOutOfApacheSites() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/conf/nginx/example-proxy.conf", "location /example/ { return 204; }\n")
        let runner = makeRunner()
        var migrator = try makeMigrator(runner: runner) { $0.webServer = .apache }
        migrator.plan.nginxIncludes = ["example-proxy.conf"]
        migrator.plan.nginxSiteRules = "location /example/ { return 204; }\n"

        let result = try migrator.run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("example-site/nginx").path))
        XCTAssertTrue(result.warnings.contains("Custom nginx config is not carried over to Apache: example-proxy.conf, the rules added to site.conf.hbs."))
    }

    func testParksMustUsePluginsUntilTheFirstStart() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/app/public/wp-content/mu-plugins/loader.php", "<?php\n")
        let muPlugins = parent.appendingPathComponent("example-site/wordpress/wp-content/mu-plugins").path
        let seenAtStart = LockedFlag()
        let base = makeRunner()
        let runner = FakeRunner { arguments in
            if arguments.first == "start" { seenAtStart.set(FileManager.default.fileExists(atPath: muPlugins)) }
            return base.respond(arguments)
        }

        _ = try makeMigrator(runner: runner).run()

        XCTAssertEqual(seenAtStart.value, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: muPlugins + "/loader.php"))
    }

    func testParksTheObjectCacheDropInUntilTheImportIsDone() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/app/public/wp-content/mu-plugins/loader.php", "<?php\n")
        try folder.write("local/example-site/app/public/wp-content/object-cache.php", Fixtures.redisObjectCache)
        let content = parent.appendingPathComponent("example-site/wordpress/wp-content").path
        let muPluginsAtImport = LockedFlag()
        let objectCacheAtImport = LockedFlag()
        let base = makeRunner()
        let runner = FakeRunner { arguments in
            if WPCClient.commandName(arguments) == "db import" {
                muPluginsAtImport.set(FileManager.default.fileExists(atPath: content + "/mu-plugins/loader.php"))
                objectCacheAtImport.set(FileManager.default.fileExists(atPath: content + "/object-cache.php"))
            }
            return base.respond(arguments)
        }

        let result = try makeMigrator(runner: runner).run()

        XCTAssertEqual(muPluginsAtImport.value, true)
        XCTAssertEqual(objectCacheAtImport.value, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: content + "/object-cache.php"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: content + "/\(BootCode.parkingFolder)"))
        XCTAssertFalse(result.warnings.contains { $0.contains(BootCode.parkingFolder) })
    }

    func testImportFailureDeletesTheSite() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner(fail: "db import")

        XCTAssertThrowsError(try makeMigrator(runner: runner).run()) { error in
            XCTAssertEqual((error as? WPCError)?.code, "example_failure")
        }
        XCTAssertEqual(runner.calls.last, ["delete", "example-site", "--json"])
    }

    func testCreateFailureTrashesThePlacedFiles() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner(fail: "create")

        XCTAssertThrowsError(try makeMigrator(runner: runner).run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("example-site").path))
        XCTAssertEqual(runner.calls.filter { $0.first == "list" }.count, 2)
        XCTAssertFalse(runner.calls.contains { $0.first == "delete" })
    }

    func testCreateFailureDeletesASiteWpcStillLists() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let base = makeRunner(fail: "create")
        let listCalls = Counter()
        let runner = FakeRunner { arguments in
            guard arguments.first == "list" else { return base.respond(arguments) }
            let slugs = listCalls.next() == 1 ? "" : #"{"slug": "example-site"}"#
            return ProcessResult(exitCode: 0, stdout: #"{"sites": [\#(slugs)], "envs": []}"#)
        }

        XCTAssertThrowsError(try makeMigrator(runner: runner).run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("example-site").path))
        XCTAssertEqual(runner.calls.last, ["delete", "example-site", "--json"])
    }

    func testFailedHTTPSUpgradeAfterImportKeepsTheSite() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let base = makeRunner()
        let runner = FakeRunner { arguments in
            guard arguments.contains("search-replace") else { return base.respond(arguments) }
            return ProcessResult(exitCode: 0, stdout: #"{"stdout": "", "stderr": "example wp failure", "exitCode": 1}"#)
        }

        let result = try makeMigrator(runner: runner) { $0.https = true }.run()

        XCTAssertFalse(runner.calls.contains { $0.first == "delete" })
        let warning = result.warnings.first { $0.contains("Moving links to HTTPS failed") }
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("example wp failure") == true)
        XCTAssertTrue(warning?.contains("rerun: wpc wp example-site -- search-replace http://127.0.0.1 https://127.0.0.1") == true)
    }

    func testRollbackLogsTheCleanupCommandWhenDeleteFails() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let base = makeRunner(fail: "db import")
        let runner = FakeRunner { arguments in
            guard arguments.first == "delete" else { return base.respond(arguments) }
            return ProcessResult(exitCode: 1, stderr: #"{"error": "delete_failed"}"#)
        }
        let logged = LogBox()
        var migrator = try makeMigrator(runner: runner)
        migrator.log = { logged.append($0) }

        XCTAssertThrowsError(try migrator.run()) { error in
            XCTAssertEqual((error as? WPCError)?.code, "example_failure")
        }
        XCTAssertTrue(logged.lines.contains { $0.contains("wpc delete example-site") })
    }

    func testKeepDumpWarnsWhenTheDumpWasProvided() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let provided = try folder.write("provided.sql.gz", "example")

        let result = try makeMigrator(runner: makeRunner()) {
            $0.keepDump = true
            $0.dumpFile = provided
        }.run()

        XCTAssertNil(result.dumpFile)
        XCTAssertTrue(result.warnings.contains { $0.contains("nothing was copied") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: provided.path))
    }

    func testTakenSlugStopsBeforeAnyChange() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let runner = makeRunner(existingSlugs: ["example-site"])

        XCTAssertThrowsError(try makeMigrator(runner: runner).run()) { error in
            guard case MigrateError.slugTaken("example-site") = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(runner.calls.map(WPCClient.commandName), ["list"])
    }

    func testMountsLinkedFolders() throws {
        let wordpress = try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let plugin = try folder.folder("repos/example-plugin")
        try folder.write("repos/example-plugin/plugin.php", "<?php\n")
        try FileManager.default.createDirectory(at: wordpress.appendingPathComponent("wp-content/plugins"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/example-plugin").path, withDestinationPath: plugin.path)
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner).run()

        XCTAssertEqual(result.mounts, ["wp-content/plugins/example-plugin": plugin.path])
        XCTAssertEqual(runner.calls.map(WPCClient.commandName), ["list", "create", "create", "xdebug", "mailpit", "start", "db import"])
        XCTAssertTrue(runner.calls[2].contains("\(plugin.path):wp-content/plugins/example-plugin"))
        let copied = parent.appendingPathComponent("example-site/wordpress/wp-content/plugins/example-plugin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testAppliesEachLinksOwnMode() throws {
        let wordpress = try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let plugins = wordpress.appendingPathComponent("wp-content/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        for name in ["mounted", "copied", "skipped"] {
            let plugin = try folder.folder("repos/\(name)")
            try folder.write("repos/\(name)/plugin.php", "<?php\n")
            try FileManager.default.createSymbolicLink(atPath: plugins.appendingPathComponent(name).path, withDestinationPath: plugin.path)
        }
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner) { options in
            options.symlinks = .mount
            options.symlinkChoices = ["wp-content/plugins/copied": .copy, "wp-content/plugins/skipped": .skip]
        }.run()

        let newPlugins = parent.appendingPathComponent("example-site/wordpress/wp-content/plugins")
        XCTAssertEqual(Array(result.mounts.keys), ["wp-content/plugins/mounted"])
        XCTAssertEqual(result.skippedLinks, ["wp-content/plugins/skipped"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPlugins.appendingPathComponent("copied/plugin.php").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newPlugins.appendingPathComponent("skipped").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: newPlugins.appendingPathComponent("skipped").path))
    }

    func testSkipOnlyLinksNeverChecksForMountSupport() throws {
        let wordpress = try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let plugin = try folder.folder("repos/example-plugin")
        try FileManager.default.createDirectory(at: wordpress.appendingPathComponent("wp-content/plugins"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/example-plugin").path, withDestinationPath: plugin.path)
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner) { options in
            options.symlinks = .skip
            options.webServer = .apache
        }.run()

        XCTAssertEqual(result.mounts, [:])
        XCTAssertEqual(runner.calls.map(WPCClient.commandName).filter { $0 == "create" }.count, 1)
    }

    func testMakesAbsoluteLinksIntoTheSiteRelative() throws {
        let wordpress = try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        try folder.write("local/example-site/app/public/wp-content/plugins/example-plugin/wp-content/db.php", "<?php\n")
        let dropIn = wordpress.appendingPathComponent("wp-content/plugins/example-plugin/wp-content/db.php")
        try FileManager.default.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/db.php").path, withDestinationPath: dropIn.path)
        let runner = makeRunner()

        let result = try makeMigrator(runner: runner).run()

        let link = parent.appendingPathComponent("example-site/wordpress/wp-content/db.php")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "plugins/example-plugin/wp-content/db.php")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(result.mounts, [:])
        XCTAssertEqual(result.skippedLinks, [])
    }

    func testCopiesLinkedFoldersWhenWPCCannotMount() throws {
        let wordpress = try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let plugin = try folder.folder("repos/example-plugin")
        try folder.write("repos/example-plugin/plugin.php", "<?php\n")
        try FileManager.default.createDirectory(at: wordpress.appendingPathComponent("wp-content/plugins"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wordpress.appendingPathComponent("wp-content/plugins/example-plugin").path, withDestinationPath: plugin.path)
        let runner = makeRunner(supportsMounts: false)

        let result = try makeMigrator(runner: runner).run()

        XCTAssertEqual(result.mounts, [:])
        XCTAssertTrue(result.warnings.contains { $0.contains("can't mount") })
        let copied = parent.appendingPathComponent("example-site/wordpress/wp-content/plugins/example-plugin")
        let isLink = (try? copied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
        XCTAssertFalse(isLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("plugin.php").path))
    }

    func testMultisiteSkipsHtaccess() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        var plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("local/example-site"), multisite: .subdirectory))
        plan.externalLinks = []
        let runner = makeRunner()
        var migrator = try makeMigrator(runner: runner)
        migrator.plan = plan

        _ = try migrator.run()

        let create = try XCTUnwrap(runner.calls.first { WPCClient.commandName($0) == "create" && !$0.contains("--help") })
        let index = try XCTUnwrap(create.firstIndex(of: "--multisite"))
        XCTAssertEqual(create[index + 1], "subdirectory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("example-site/wordpress/.htaccess").path))
        XCTAssertEqual(runner.calls.last?.prefix(4), ["wp", "--json", "example-site", "--"])
    }

    func testWarnsAboutNetworkSitesStillOnTheLocalDomain() throws {
        try Fixtures.wordpress(in: folder, at: "local/example-site/app/public")
        let parentPath = parent.path
        let runner = FakeRunner { arguments in
            switch WPCClient.commandName(arguments) {
            case "list": return ProcessResult(exitCode: 0, stdout: #"{"sites": []}"#)
            case "create": return ProcessResult(exitCode: 0, stdout: #"{"name": "n", "slug": "example-site", "path": "\#(parentPath)/example-site", "url": "http://127.0.0.1:8899"}"#)
            case "db import": return ProcessResult(exitCode: 0, stdout: #"{"sourceURL": "https://example-site.test"}"#)
            case "wp": return ProcessResult(exitCode: 0, stdout: #"{"stdout": "https://shop.example-site.test/\nhttps://blog.example-site.test/\n", "stderr": "", "exitCode": 0}"#)
            default: return ProcessResult(exitCode: 0, stdout: "{}")
            }
        }
        var migrator = try makeMigrator(runner: runner)
        migrator.plan.site.multisite = .subdomain

        let result = try migrator.run()

        let leftover = result.warnings.first { $0.contains("still point at the LocalWP domain") }
        XCTAssertEqual(leftover, "Some network sites still point at the LocalWP domain: https://shop.example-site.test/, https://blog.example-site.test/.")
        XCTAssertTrue(runner.calls.contains(["https", "enable", "example-site", "--json"]))
        XCTAssertEqual(result.addons.last, "https")
        XCTAssertTrue(runner.calls.contains { $0.contains("search-replace") })
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
}
