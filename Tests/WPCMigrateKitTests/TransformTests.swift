import XCTest
@testable import WPCMigrateKit

final class WPConfigTransformerTests: XCTestCase {
    func testDatabaseDefinesReadTheEnvironment() {
        let output = WPConfigTransformer.transform(Fixtures.wpConfig)

        XCTAssertTrue(output.contains("define( 'DB_NAME', getenv( 'WORDPRESS_DB_NAME' ) ?: 'wordpress' );"))
        XCTAssertTrue(output.contains("define( 'DB_HOST', getenv( 'WORDPRESS_DB_HOST' ) ?: 'localhost' );"))
        XCTAssertFalse(output.contains("'local'"))
        XCTAssertFalse(output.contains("'root'"))
    }

    func testKeepsPrefixSaltsAndOtherConstants() {
        let output = WPConfigTransformer.transform(Fixtures.wpConfig)

        XCTAssertTrue(output.contains("$table_prefix = 'ex_';"))
        XCTAssertTrue(output.contains("define( 'AUTH_KEY', 'example-auth-key' );"))
        XCTAssertTrue(output.contains("define( 'DB_CHARSET', 'utf8' );"))
        XCTAssertTrue(output.contains("define( 'WP_DEBUG', false );"))
        XCTAssertTrue(output.contains("require_once ABSPATH . 'wp-settings.php';"))
    }

    func testRemovesMultisiteConstantLines() {
        let output = WPConfigTransformer.transform(Fixtures.wpConfig)

        XCTAssertFalse(output.contains("WP_ALLOW_MULTISITE"))
        XCTAssertFalse(output.contains("'MULTISITE'"))
        XCTAssertFalse(output.contains("// network"))
        XCTAssertFalse(output.contains("DOMAIN_CURRENT_SITE"))
    }

    func testRemovesGuardedMultisiteBlocks() {
        let source = """
            <?php
            if ( ! defined( "MULTISITE" ) ) {
            \tdefine( "MULTISITE", true ); // Example note.
            }
            if ( ! defined( 'WP_DEBUG' ) ) {
            \tdefine( 'WP_DEBUG', false );
            }

            """
        XCTAssertEqual(WPConfigTransformer.transform(source), """
            <?php
            if ( ! defined( 'WP_DEBUG' ) ) {
            \tdefine( 'WP_DEBUG', false );
            }

            """)
    }

    func testHandlesDoubleQuotes() {
        let output = WPConfigTransformer.transform(#"define("DB_USER","root");"#)
        XCTAssertEqual(output, "define( 'DB_USER', getenv( 'WORDPRESS_DB_USER' ) ?: 'wordpress' );")
    }

    func testQuotedValuesMayContainSemicolonsAndParentheses() {
        let semicolon = WPConfigTransformer.transform("define( 'DB_PASSWORD', 'ab;cd' );")
        XCTAssertEqual(semicolon, "define( 'DB_PASSWORD', getenv( 'WORDPRESS_DB_PASSWORD' ) ?: 'wordpress' );")

        let parenthesis = WPConfigTransformer.transform("define( 'DB_PASSWORD', 'a);b' );")
        XCTAssertEqual(parenthesis, "define( 'DB_PASSWORD', getenv( 'WORDPRESS_DB_PASSWORD' ) ?: 'wordpress' );")

        let removed = WPConfigTransformer.transform("<?php\ndefine( 'WP_HOME', 'http://example-site.test/?a=1;b=2' );\n$x = 1;\n")
        XCTAssertEqual(removed, "<?php\n$x = 1;\n")
    }

    func testRemovalInCRLFFilesLeavesNoEmptyLine() {
        let lines = [
            "<?php",
            "define( 'WP_HOME', 'http://example-site.test' ); // note",
            "if ( ! defined( 'MULTISITE' ) ) {",
            "\tdefine( 'MULTISITE', true );",
            "}",
            "define( 'WP_DEBUG', false );",
            "",
        ]
        let output = WPConfigTransformer.transform(lines.joined(separator: "\r\n"))

        XCTAssertEqual(output, "<?php\r\ndefine( 'WP_DEBUG', false );\r\n")
    }

    func testTablePrefix() {
        XCTAssertEqual(WPConfigTransformer.tablePrefix(in: Fixtures.wpConfig), "ex_")
        XCTAssertNil(WPConfigTransformer.tablePrefix(in: "$table_prefix = getenv( 'PREFIX' );"))
    }
}

final class CollationRewriterTests: XCTestCase {
    func testRewritesSchemaCollations() {
        XCTAssertEqual(
            CollationRewriter.rewrite(line: "  `name` varchar(20) COLLATE utf8mb4_0900_ai_ci DEFAULT NULL,"),
            "  `name` varchar(20) COLLATE utf8mb4_unicode_520_ci DEFAULT NULL,"
        )
        XCTAssertEqual(
            CollationRewriter.rewrite(line: ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;"),
            ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;"
        )
    }

    func testLeavesInsertDataAlone() throws {
        let folder = try TemporaryFolder()
        let input = try folder.write("in.sql", """
            CREATE TABLE `ex_items` (
              `name` varchar(20) COLLATE utf8mb4_0900_ai_ci
            ) COLLATE=utf8mb4_0900_ai_ci;
            INSERT INTO `ex_items` VALUES ('about utf8mb4_0900_ai_ci');
            SET NAMES utf8mb4;
            """)
        let output = folder.url.appendingPathComponent("out.sql")

        let changed = try CollationRewriter.rewrite(input: input, output: output)
        let text = try String(contentsOf: output, encoding: .utf8)

        XCTAssertEqual(changed, 2)
        XCTAssertTrue(text.contains("INSERT INTO `ex_items` VALUES ('about utf8mb4_0900_ai_ci');"))
        XCTAssertTrue(text.contains(") COLLATE=utf8mb4_unicode_520_ci;"))
        XCTAssertTrue(text.hasSuffix("SET NAMES utf8mb4;"))
    }

    func testStreamsLinesAcrossChunks() throws {
        let folder = try TemporaryFolder()
        let long = String(repeating: "x", count: 1_500_000)
        let input = try folder.write("in.sql", "INSERT INTO t VALUES ('\(long)');\nCOLLATE utf8mb4_0900_ai_ci\n")
        let output = folder.url.appendingPathComponent("out.sql")

        XCTAssertEqual(try CollationRewriter.rewrite(input: input, output: output), 1)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(text.count, 1_500_000 + "INSERT INTO t VALUES ('');\nCOLLATE utf8mb4_unicode_520_ci\n".count)
    }
}

final class SymlinkScannerTests: XCTestCase {
    func testFindsOnlyExternalAndAbsoluteLinks() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("site/public")
        let outside = try folder.folder("repos/example-plugin")
        try folder.write("site/public/wp-content/plugins/inside/plugin.php")
        try folder.write("repos/drop-in.php")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("wp-content/plugins"), withIntermediateDirectories: true)

        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/plugins/example-plugin").path, withDestinationPath: outside.path)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/plugins/relative").path, withDestinationPath: "inside")
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/db.php").path, withDestinationPath: folder.url.appendingPathComponent("repos/drop-in.php").path)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/broken").path, withDestinationPath: "/nonexistent/example")
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/gone").path, withDestinationPath: "../../../gone")
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("wp-content/plugins/absolute").path, withDestinationPath: root.appendingPathComponent("wp-content/plugins/inside").path)

        let scan = SymlinkScanner.scan(root)
        let links = scan.externalLinks

        XCTAssertEqual(links.map(\.path), ["wp-content/broken", "wp-content/db.php", "wp-content/gone", "wp-content/plugins/example-plugin"])
        XCTAssertEqual(links.map(\.isMountable), [false, false, false, true])
        XCTAssertEqual(links.map(\.targetExists), [false, true, false, true])
        XCTAssertEqual(links[0].target, "/nonexistent/example")
        XCTAssertEqual(links[3].target, outside.path)
        XCTAssertEqual(scan.internalLinks, [InternalLink(path: "wp-content/plugins/absolute", destination: "inside")])
    }

    func testRelativeDestinations() {
        XCTAssertEqual(SymlinkScanner.relativeDestination(from: "wp-content/db.php", to: "wp-content/plugins/example-plugin/wp-content/db.php"), "plugins/example-plugin/wp-content/db.php")
        XCTAssertEqual(SymlinkScanner.relativeDestination(from: "wp-content/plugins/a/link.php", to: "wp-content/themes/b/file.php"), "../../themes/b/file.php")
        XCTAssertEqual(SymlinkScanner.relativeDestination(from: "link", to: "wp-content/file.php"), "wp-content/file.php")
        XCTAssertEqual(SymlinkScanner.relativeDestination(from: "wp-content/link", to: "wp-content"), ".")
        XCTAssertEqual(SymlinkScanner.relativeDestination(from: "wp-content/plugins/link", to: ""), "../..")
    }
}

final class HtaccessTests: XCTestCase {
    func testWritesOnlyWhenMissing() throws {
        let folder = try TemporaryFolder()
        XCTAssertTrue(try Htaccess.writeIfMissing(wordpressFolder: folder.url))
        try folder.write(".htaccess", "custom")
        XCTAssertFalse(try Htaccess.writeIfMissing(wordpressFolder: folder.url))
        XCTAssertEqual(try String(contentsOf: folder.url.appendingPathComponent(".htaccess"), encoding: .utf8), "custom")
    }
}

final class WPCSlugTests: XCTestCase {
    func testSlugRules() {
        XCTAssertEqual(WPCSlug.make("Example Site"), "example-site")
        XCTAssertEqual(WPCSlug.make("Café: Shop__2.0/"), "cafe-shop-2-0")
        XCTAssertEqual(WPCSlug.make("--Example--"), "example")
        XCTAssertEqual(WPCSlug.make("!!!"), "site")
    }
}

final class BootCodeTests: XCTestCase {
    func testParksAndRestoresBootCode() throws {
        let folder = try TemporaryFolder()
        try folder.write("wp-content/mu-plugins/loader.php", "<?php\n")
        try folder.write("wp-content/object-cache.php", "<?php\n")
        try folder.write("wp-content/plugins/example/plugin.php", "<?php\n")
        let content = folder.url.appendingPathComponent("wp-content")

        let parked = try BootCode.park(in: folder.url)

        XCTAssertEqual(parked, ["mu-plugins", "object-cache.php"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.appendingPathComponent("mu-plugins").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.appendingPathComponent("object-cache.php").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("plugins/example/plugin.php").path))

        // A mount point created inside mu-plugins while the code was parked.
        try folder.write("wp-content/mu-plugins/mounted/.keep")
        try BootCode.restore(parked, in: folder.url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("mu-plugins/loader.php").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("mu-plugins/mounted/.keep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("object-cache.php").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.appendingPathComponent(BootCode.parkingFolder).path))
    }

    func testKeepsParkedFilesThatCannotBeRestored() throws {
        let folder = try TemporaryFolder()
        try folder.write("wp-content/mu-plugins/loader.php", "parked")
        let parked = try BootCode.park(in: folder.url)
        try folder.write("wp-content/mu-plugins/loader.php", "newer")

        try BootCode.restore(parked, in: folder.url)

        let kept = folder.url.appendingPathComponent("wp-content/\(BootCode.parkingFolder)/mu-plugins/loader.php")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "parked")
    }
}
