import XCTest
@testable import WPCMigrateKit

final class LocalWPCatalogTests: XCTestCase {
    private func makeCatalog() throws -> (TemporaryFolder, LocalWPCatalog) {
        let folder = try TemporaryFolder()
        try folder.write("sites.json", """
            {
              "abc123XYZ": {
                "id": "abc123XYZ", "name": "Example Site", "domain": "example-site.test",
                "path": "~/Sites/example-site", "multiSite": "",
                "mysql": {"database": "local", "user": "root", "password": "root"},
                "services": {
                  "php": {"name": "php", "version": "8.2.10"},
                  "mysql": {"name": "mysql", "version": "8.0.35"},
                  "nginx": {"name": "nginx", "version": "1.26.1"}
                },
                "xdebugEnabled": true, "redisEnabled": false
              },
              "def456UVW": {
                "id": "def456UVW", "name": "Legacy Network", "domain": "legacy-network.test",
                "path": "/tmp/legacy-network", "multiSite": "ms-subdomain",
                "phpVersion": "7.4.1", "webServer": "nginx-1.16.0", "database": "mysql-8.0.16",
                "elasticsearchEnabled": true
              },
              "ghi789RST": {
                "id": "ghi789RST", "name": "Shared Name", "domain": "shared-one.test",
                "path": "/tmp/shared-one", "multiSite": "ms-subdir",
                "services": {"mariadb": {"name": "mariadb", "version": "10.4.10"}, "apache": {}}
              },
              "jkl012MNO": {
                "id": "jkl012MNO", "name": "shared name", "domain": "shared-two.test",
                "path": "/tmp/shared-two"
              }
            }
            """)
        try folder.write("site-statuses.json", #"{"abc123XYZ": "running", "def456UVW": "halted"}"#)
        return (folder, try LocalWPCatalog.load(root: folder.url))
    }

    func testParsesModernSite() throws {
        let (_, catalog) = try makeCatalog()
        let site = try catalog.find("abc123XYZ")

        XCTAssertEqual(site.name, "Example Site")
        XCTAssertEqual(site.status, .running)
        XCTAssertEqual(site.multisite, .none)
        XCTAssertEqual(site.phpVersion, "8.2.10")
        XCTAssertEqual(site.database, .init(kind: .mysql, version: "8.0.35"))
        XCTAssertEqual(site.webServer, "nginx")
        XCTAssertTrue(site.xdebug)
        XCTAssertFalse(site.redis)
        XCTAssertEqual(site.path.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites/example-site").path)
        XCTAssertEqual(site.wordpressFolder.lastPathComponent, "public")
    }

    func testFindsTheStockNginxTemplatesForTheSiteVersion() throws {
        let (folder, catalog) = try makeCatalog()
        try folder.write("lightning-services/nginx-1.26.1+3/conf/site.conf.hbs")
        try folder.write("lightning-services/nginx-1.16.0+7/conf/site.conf.hbs")

        let site = try catalog.find("abc123XYZ")
        let legacy = try catalog.find("legacy-network.test")

        XCTAssertEqual(site.webServerVersion, "1.26.1")
        XCTAssertEqual(catalog.stockNginxFolder(for: site)?.deletingLastPathComponent().lastPathComponent, "nginx-1.26.1+3")
        XCTAssertEqual(legacy.webServerVersion, "1.16.0")
        XCTAssertEqual(catalog.stockNginxFolder(for: legacy)?.deletingLastPathComponent().lastPathComponent, "nginx-1.16.0+7")
        XCTAssertNil(catalog.stockNginxFolder(for: try catalog.find("ghi789RST")))
    }

    func testReadsLegacyKeys() throws {
        let (_, catalog) = try makeCatalog()
        let site = try catalog.find("legacy-network.test")

        XCTAssertEqual(site.phpVersion, "7.4.1")
        XCTAssertEqual(site.database, .init(kind: .mysql, version: "8.0.16"))
        XCTAssertEqual(site.webServer, "nginx")
        XCTAssertEqual(site.multisite, .subdomain)
        XCTAssertTrue(site.elasticsearch)
        XCTAssertEqual(site.status, .halted)
        XCTAssertEqual(site.credentials, .init(database: "local", user: "root", password: "root"))
    }

    func testReadsMariaDBAndApache() throws {
        let (_, catalog) = try makeCatalog()
        let site = try catalog.find("ghi789RST")

        XCTAssertEqual(site.database, .init(kind: .mariadb, version: "10.4.10"))
        XCTAssertEqual(site.webServer, "apache")
        XCTAssertEqual(site.multisite, .subdirectory)
        XCTAssertEqual(site.status, .unknown)
    }

    func testFindsByNameCaseInsensitively() throws {
        let (_, catalog) = try makeCatalog()
        XCTAssertEqual(try catalog.find("EXAMPLE SITE").id, "abc123XYZ")
    }

    func testAmbiguousNameThrows() throws {
        let (_, catalog) = try makeCatalog()
        XCTAssertThrowsError(try catalog.find("Shared Name")) { error in
            guard case MigrateError.ambiguousSite(_, let matches) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(matches), ["ghi789RST", "jkl012MNO"])
        }
    }

    func testSharedDomainThrowsAmbiguous() throws {
        let folder = try TemporaryFolder()
        try folder.write("sites.json", """
            {
              "aaa111": {"id": "aaa111", "name": "First", "domain": "example-site.test", "path": "/tmp/first"},
              "bbb222": {"id": "bbb222", "name": "Second", "domain": "Example-Site.test", "path": "/tmp/second"}
            }
            """)
        let catalog = try LocalWPCatalog.load(root: folder.url)

        XCTAssertThrowsError(try catalog.find("example-site.test")) { error in
            guard case MigrateError.ambiguousSite(_, let matches) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(matches), ["aaa111", "bbb222"])
        }
    }

    func testUnknownSiteThrows() throws {
        let (_, catalog) = try makeCatalog()
        XCTAssertThrowsError(try catalog.find("missing")) { error in
            guard case MigrateError.siteNotFound = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingLocalThrows() throws {
        let folder = try TemporaryFolder()
        XCTAssertThrowsError(try LocalWPCatalog.load(root: folder.url)) { error in
            guard case MigrateError.localNotFound = error else { return XCTFail("\(error)") }
        }
    }
}
