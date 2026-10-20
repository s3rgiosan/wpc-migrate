import XCTest
@testable import WPCMigrateKit

final class BootCodeRestoreTests: XCTestCase {
    private var folder: TemporaryFolder!

    override func setUpWithError() throws {
        folder = try TemporaryFolder()
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(path).path)
    }

    func testLeavesAParkedFileWhoseDestinationWasRecreated() throws {
        try folder.write("wp-content/object-cache.php", "<?php // parked\n")
        try folder.write("wp-content/mu-plugins/loader.php", "<?php\n")
        let parked = try BootCode.park(in: folder.url)
        try folder.write("wp-content/object-cache.php", "<?php // new\n")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("wp-content/mu-plugins"), withIntermediateDirectories: true)

        let left = try BootCode.restore(parked, in: folder.url)

        XCTAssertEqual(left, ["object-cache.php"])
        XCTAssertTrue(exists("wp-content/.wpc-migrate-parked/object-cache.php"))
        XCTAssertTrue(exists("wp-content/mu-plugins/loader.php"))
        let current = try String(contentsOf: folder.url.appendingPathComponent("wp-content/object-cache.php"), encoding: .utf8)
        XCTAssertEqual(current, "<?php // new\n")
    }

    func testSkipsAMissingParkedSourceAndRestoresTheRest() throws {
        try folder.write("wp-content/db.php", "<?php\n")
        try folder.write("wp-content/sunrise.php", "<?php\n")
        let parked = try BootCode.park(in: folder.url)
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("wp-content/.wpc-migrate-parked/db.php"))

        let left = try BootCode.restore(parked, in: folder.url)

        XCTAssertEqual(left, [])
        XCTAssertFalse(exists("wp-content/db.php"))
        XCTAssertTrue(exists("wp-content/sunrise.php"))
        XCTAssertFalse(exists("wp-content/.wpc-migrate-parked"))
    }

    func testReturnsCollidingChildrenOfAMergedFolder() throws {
        try folder.write("wp-content/mu-plugins/a.php", "<?php // parked\n")
        try folder.write("wp-content/mu-plugins/b.php", "<?php\n")
        let parked = try BootCode.park(in: folder.url)
        try folder.write("wp-content/mu-plugins/a.php", "<?php // new\n")

        let left = try BootCode.restore(parked, in: folder.url)

        XCTAssertEqual(left, ["mu-plugins/a.php"])
        XCTAssertTrue(exists("wp-content/mu-plugins/b.php"))
        XCTAssertTrue(exists("wp-content/.wpc-migrate-parked/mu-plugins/a.php"))
    }
}
