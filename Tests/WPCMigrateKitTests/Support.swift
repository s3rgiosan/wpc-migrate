import Foundation
@testable import WPCMigrateKit

/// A temporary folder removed when the test finishes.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpcm-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String = "") throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func folder(_ relativePath: String) throws -> URL {
        let folder = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Records every command and answers from `respond`. `/bin/cp` runs for real
/// so file placement can be checked.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let respond: @Sendable ([String]) -> ProcessResult

    init(respond: @escaping @Sendable ([String]) -> ProcessResult) {
        self.respond = respond
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, stdoutFile: URL?) throws -> ProcessResult {
        if executable.path == "/bin/cp" {
            return try ProcessRunner().run(executable, arguments, environment: environment, stdoutFile: stdoutFile)
        }
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        return respond(arguments)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ flag: Bool) {
        lock.lock()
        stored = flag
        lock.unlock()
    }
}

/// Writes a fabricated dump without running MySQL.
struct FakeDumper: DatabaseDumping {
    var homeURL = "http://example-site.test"

    func strategy(for site: LocalWPSite) -> DumpStrategy {
        .temporaryServer
    }

    func dump(site: LocalWPSite, tablePrefix: String, to file: URL) throws -> DumpResult {
        try "CREATE TABLE `\(tablePrefix)options` (id int);\n".write(to: file, atomically: true, encoding: .utf8)
        return DumpResult(file: file, homeURL: homeURL, strategy: .temporaryServer, rewrittenLines: 0)
    }
}

enum Fixtures {
    static let wpConfig = """
        <?php
        define( 'DB_NAME', 'local' );
        define( 'DB_USER', 'root' );
        define( 'DB_PASSWORD', 'root' );
        define( 'DB_HOST', 'localhost' );
        define( 'DB_CHARSET', 'utf8' );
        define( 'AUTH_KEY', 'example-auth-key' );
        $table_prefix = 'ex_';
        define( 'WP_DEBUG', false );
        define( 'WP_ALLOW_MULTISITE', true );
        define( 'MULTISITE', true ); // network
        define( 'DOMAIN_CURRENT_SITE', 'example-site.test' );
        if ( ! defined( 'ABSPATH' ) ) {
        \tdefine( 'ABSPATH', __DIR__ . '/' );
        }
        require_once ABSPATH . 'wp-settings.php';

        """

    /// A minimal WordPress install the plan accepts.
    @discardableResult
    static func wordpress(in folder: TemporaryFolder, at path: String, config: String? = wpConfig) throws -> URL {
        try folder.write("\(path)/wp-settings.php", "<?php\n")
        try folder.write("\(path)/index.php", "<?php\n")
        try folder.write("\(path)/wp-includes/version.php", "<?php\n$wp_version = '6.5.2';\n")
        try folder.write("\(path)/local-xdebuginfo.php", "<?php\n")
        if let config { try folder.write("\(path)/wp-config.php", config) }
        return folder.url.appendingPathComponent(path)
    }

    static func site(path: URL, multisite: LocalWPSite.Multisite = .none, php: String? = "8.2.10") -> LocalWPSite {
        LocalWPSite(
            id: "abc123XYZ",
            name: "Example Site",
            domain: "example-site.test",
            path: path,
            status: .halted,
            multisite: multisite,
            phpVersion: php,
            database: .init(kind: .mysql, version: "8.0.35"),
            credentials: .init(database: "local", user: "root", password: "root"),
            webServer: "nginx",
            xdebug: true,
            redis: false,
            elasticsearch: false
        )
    }
}
