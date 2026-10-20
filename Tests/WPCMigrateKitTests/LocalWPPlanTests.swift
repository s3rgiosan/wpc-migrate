import XCTest
@testable import WPCMigrateKit

final class LocalWPPlanTests: XCTestCase {
    func testReadsVersionsAndPrefix() throws {
        let folder = try TemporaryFolder()
        try Fixtures.wordpress(in: folder, at: "example-site/app/public")
        let plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("example-site")))

        XCTAssertEqual(plan.phpVersion, "8.2")
        XCTAssertEqual(plan.wordpressVersion, "6.5.2")
        XCTAssertEqual(plan.tablePrefix, "ex_")
        XCTAssertNotNil(plan.wpConfig)
        XCTAssertEqual(plan.warnings, [])
    }

    func testClampsOldPHP() throws {
        let folder = try TemporaryFolder()
        try Fixtures.wordpress(in: folder, at: "example-site/app/public")
        let plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("example-site"), php: "7.4.30"))

        XCTAssertEqual(plan.phpVersion, "8.1")
        XCTAssertTrue(plan.warnings.contains { $0.contains("PHP 7.4") })
    }

    func testMissingConfigAssumesDefaultPrefix() throws {
        let folder = try TemporaryFolder()
        try Fixtures.wordpress(in: folder, at: "example-site/app/public", config: nil)
        let plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("example-site")))

        XCTAssertEqual(plan.tablePrefix, "wp_")
        XCTAssertNil(plan.wpConfig)
        XCTAssertTrue(plan.warnings.contains { $0.contains("No wp-config.php") })
    }

    func testWarnsAboutCustomNginxFiles() throws {
        let folder = try TemporaryFolder()
        try Fixtures.wordpress(in: folder, at: "example-site/app/public")
        for stock in LocalWPPlan.stockNginxFiles {
            try folder.write("example-site/conf/nginx/\(stock)")
        }
        try folder.write("example-site/conf/nginx/site.conf.hbs.bak")
        try folder.write("example-site/conf/nginx/uploads-proxy.conf")
        try folder.write("example-site/conf/nginx/.DS_Store")

        let plan = try LocalWPPlan(site: Fixtures.site(path: folder.url.appendingPathComponent("example-site")))

        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("uploads-proxy.conf"))
        XCTAssertFalse(plan.warnings[0].contains(".bak"))
        XCTAssertFalse(plan.warnings[0].contains(".DS_Store"))
    }

    func testMissingWordPressThrows() throws {
        let folder = try TemporaryFolder()
        XCTAssertThrowsError(try LocalWPPlan(site: Fixtures.site(path: folder.url))) { error in
            guard case MigrateError.wordpressFolderMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testVersionComparison() {
        XCTAssertTrue(LocalWPPlan.isOlder("7.4", than: "8.1"))
        XCTAssertTrue(LocalWPPlan.isOlder("0.2.9", than: "0.3.0"))
        XCTAssertFalse(LocalWPPlan.isOlder("8.10", than: "8.2"))
        XCTAssertFalse(LocalWPPlan.isOlder("0.3.0", than: "0.3.0"))
        XCTAssertNil(LocalWPPlan.majorMinor("8"))
    }
}
