import XCTest
@testable import WPCMigrateKit

final class WPCClientTests: XCTestCase {
    private let siteJSON = #"{"name": "Example Site", "slug": "example-site", "path": "/tmp/example-site", "url": "http://127.0.0.1:8899", "port": 8899}"#

    func testCreateArguments() throws {
        let json = siteJSON
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: json) }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        let site = try client.create(name: "Example Site", parentFolder: "/tmp", domain: nil, phpVersion: "8.2", multisite: "subdirectory")

        XCTAssertEqual(site.slug, "example-site")
        XCTAssertEqual(site.wordpressFolder.path, "/tmp/example-site/wordpress")
        XCTAssertEqual(runner.calls, [["create", "Example Site", "--path", "/tmp", "--php-version", "8.2", "--multisite", "subdirectory", "--json"]])
    }

    func testCreatePassesMountsInPathOrder() throws {
        let json = siteJSON
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: json) }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        _ = try client.create(name: "Example Site", parentFolder: nil, domain: nil, phpVersion: nil, multisite: nil, mounts: [
            "wp-content/themes/example": "/repos/example-theme",
            "wp-content/plugins/example": "/repos/example-plugin",
        ])

        XCTAssertEqual(runner.calls.first, [
            "create", "Example Site",
            "--mount", "/repos/example-plugin:wp-content/plugins/example",
            "--mount", "/repos/example-theme:wp-content/themes/example",
            "--json",
        ])
    }

    func testFailureCarriesWPCErrorPayload() {
        let runner = FakeRunner { _ in
            ProcessResult(exitCode: 1, stderr: "Starting example-site…\n{\n  \"detail\" : \"wp core install failed\",\n  \"error\" : \"start_failed\"\n}\n")
        }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        XCTAssertThrowsError(try client.start("example-site")) { error in
            guard let error = error as? WPCError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.command, "start")
            XCTAssertEqual(error.code, "start_failed")
            XCTAssertEqual(error.detail, "wp core install failed")
        }
    }

    func testFailureWithoutJSONKeepsTheLastLines() {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 64, stderr: "Error: Unknown option '--example'\n") }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        XCTAssertThrowsError(try client.enableHTTPS("example-site")) { error in
            guard let error = error as? WPCError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.command, "https enable")
            XCTAssertNil(error.code)
            XCTAssertEqual(error.detail, "Error: Unknown option '--example'")
        }
    }

    func testImportArguments() throws {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: #"{"localURL": "http://127.0.0.1:8899", "sourceURL": "https://example-site.test"}"#) }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        let result = try client.importDatabase(slug: "example-site", dump: URL(fileURLWithPath: "/tmp/dump.sql"), sourceURL: "https://example-site.test", resetAdmin: false)

        XCTAssertEqual(result.localURL, "http://127.0.0.1:8899")
        XCTAssertEqual(runner.calls.first, [
            "db", "import", "example-site", "/tmp/dump.sql", "--no-scrub", "--media", "skip", "--no-admin",
            "--source-url", "https://example-site.test", "--json",
        ])
    }

    func testWPUnwrapsTheResult() throws {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 1, stdout: #"{"stdout": "", "stderr": "Error: example", "exitCode": 1}"#) }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)

        let result = try client.wp("example-site", ["option", "get", "home"])

        XCTAssertEqual(result, ProcessResult(exitCode: 1, stdout: "", stderr: "Error: example"))
        XCTAssertEqual(runner.calls.first, ["wp", "--json", "example-site", "--", "option", "get", "home"])
    }

    func testSlugsIncludeEnvs() throws {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: #"{"sites": [{"slug": "one"}], "envs": [{"slug": "one-feature"}]}"#) }
        let client = WPCClient(executable: URL(fileURLWithPath: "/usr/local/bin/wpc"), runner: runner)
        XCTAssertEqual(try client.slugs(), ["one", "one-feature"])
    }
}

final class LocalWPDumperTests: XCTestCase {
    func testPicksHighestBuildWithBinaries() throws {
        let folder = try TemporaryFolder()
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin"
        #endif
        for name in ["mysql-8.0.35", "mysql-8.0.35+4", "mysql-8.0.35+9", "mysql-8.0.3+12"] {
            _ = try folder.folder("lightning-services/\(name)/bin/\(platform)/bin")
        }
        // +9 has no mysqldump, so +4 wins.
        for name in ["mysql-8.0.35", "mysql-8.0.35+4", "mysql-8.0.3+12"] {
            let tool = try folder.write("lightning-services/\(name)/bin/\(platform)/bin/mysqldump", "#!/bin/sh\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        let bin = LocalWPDumper.binFolder(localRoot: folder.url, database: .init(kind: .mysql, version: "8.0.35"))

        XCTAssertEqual(bin?.pathComponents.suffix(4).first, "mysql-8.0.35+4")
        XCTAssertNil(LocalWPDumper.binFolder(localRoot: folder.url, database: .init(kind: .mysql, version: "5.7.0")))
    }

    func testIgnoresBuildSuffixInSiteVersion() throws {
        let folder = try TemporaryFolder()
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin"
        #endif
        _ = try folder.folder("lightning-services/mysql-8.0.35+5/bin/\(platform)/bin")
        let tool = try folder.write("lightning-services/mysql-8.0.35+5/bin/\(platform)/bin/mysqldump", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let bin = LocalWPDumper.binFolder(localRoot: folder.url, database: .init(kind: .mysql, version: "8.0.35+4"))

        XCTAssertEqual(bin?.pathComponents.suffix(4).first, "mysql-8.0.35+5")
    }

    func testMySQL8OnlyFlagsAreVersionGated() {
        let work = URL(fileURLWithPath: "/tmp/wpcm-example")
        let old = LocalWPDumper.dumpArguments(socket: "/s", user: "root", database: "local", version: "5.7.40")
        let new = LocalWPDumper.dumpArguments(socket: "/s", user: "root", database: "local", version: "8.0.35")
        let unknown = LocalWPDumper.dumpArguments(socket: "/s", user: "root", database: "local", version: "latest")
        XCTAssertFalse(old.contains("--column-statistics=0"))
        XCTAssertTrue(new.contains("--column-statistics=0"))
        XCTAssertTrue(unknown.contains("--column-statistics=0"))
        for arguments in [old, new] {
            XCTAssertTrue(arguments.contains("--no-tablespaces"))
            XCTAssertTrue(arguments.contains("--set-gtid-purged=OFF"))
        }

        let oldServer = LocalWPDumper.serverArguments(work: work, data: work, socket: work, errorLog: work, version: "5.7.40")
        let newServer = LocalWPDumper.serverArguments(work: work, data: work, socket: work, errorLog: work, version: "8.0.35")
        XCTAssertFalse(oldServer.contains("--mysqlx=OFF"))
        XCTAssertTrue(newServer.contains("--mysqlx=OFF"))
    }

    func testBuildNumber() {
        XCTAssertEqual(LocalWPDumper.build(of: "mysql-8.4.0+2"), 2)
        XCTAssertEqual(LocalWPDumper.build(of: "mysql-8.4.0"), 0)
    }

    func testWorkFolderSocketFits() throws {
        let work = try LocalWPDumper.makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        XCTAssertLessThanOrEqual(work.appendingPathComponent("mysqld.sock").path.utf8.count, LocalWPDumper.maxSocketPathLength)
    }
}
