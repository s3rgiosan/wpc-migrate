import Foundation

/// What a LocalWP site becomes in wp-container, worked out before anything
/// runs.
public struct LocalWPPlan: Sendable {
    /// The oldest PHP version wp-container ships images for.
    public static let minimumPHP = "8.1"

    /// The nginx config files every LocalWP site has. Anything else in
    /// `conf/nginx` is a customization that wp-container won't apply.
    static let stockNginxFiles: Set<String> = [
        "nginx.conf.hbs", "site.conf.hbs",
        "includes/gzip.conf.hbs", "includes/mime-types.conf.hbs", "includes/restrictions.conf.hbs",
        "includes/wordpress-multi.conf.hbs", "includes/wordpress-single.conf.hbs",
    ]

    public var site: LocalWPSite
    /// `major.minor` for `wpc create --php-version`, or nil to use wpc's default.
    public var phpVersion: String?
    public var wordpressVersion: String?
    public var tablePrefix: String
    /// Symlinks to paths outside the site, which won't resolve inside the container.
    public var externalLinks: [ExternalLink]
    /// Absolute symlinks into the site, rewritten as relative links.
    public var internalLinks: [InternalLink]
    /// LocalWP's `wp-config.php`, or nil when the site has none in `app/public`.
    public var wpConfig: String?
    public var warnings: [String]

    public init(site: LocalWPSite) throws {
        let folder = site.wordpressFolder
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("wp-settings.php").path) else {
            throw MigrateError.wordpressFolderMissing(folder.path)
        }

        self.site = site
        var warnings: [String] = []

        let configURL = folder.appendingPathComponent("wp-config.php")
        let wpConfig = try? String(contentsOf: configURL, encoding: .utf8)
        self.wpConfig = wpConfig
        if let wpConfig, let prefix = WPConfigTransformer.tablePrefix(in: wpConfig) {
            tablePrefix = prefix
        } else {
            tablePrefix = "wp_"
            let reason = wpConfig == nil ? "No wp-config.php in app/public" : "The table prefix in wp-config.php is not a plain string"
            warnings.append("\(reason); assuming the wp_ table prefix.")
        }

        let versionFile = folder.appendingPathComponent("wp-includes/version.php")
        wordpressVersion = (try? String(contentsOf: versionFile, encoding: .utf8)).flatMap(Self.wordpressVersion(in:))

        phpVersion = site.phpVersion.flatMap(Self.majorMinor)
        if let php = phpVersion, Self.isOlder(php, than: Self.minimumPHP) {
            warnings.append("PHP \(php) has no wp-container image; the site will run on PHP \(Self.minimumPHP).")
            phpVersion = Self.minimumPHP
        }

        let links = SymlinkScanner.scan(folder)
        externalLinks = links.externalLinks
        internalLinks = links.internalLinks
        for link in externalLinks where !link.targetExists {
            warnings.append("\(link.path) is a broken symlink (\(link.target)) and is skipped.")
        }

        if site.webServer == "nginx" {
            let custom = Self.customNginxFiles(siteFolder: site.path)
            if !custom.isEmpty {
                warnings.append("Custom nginx config is not carried over: \(custom.joined(separator: ", ")).")
            }
        }

        self.warnings = warnings
    }

    static func majorMinor(_ version: String) -> String? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2, Int(parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        let lhs = version.split(separator: ".").compactMap { Int($0) }
        let rhs = other.split(separator: ".").compactMap { Int($0) }
        return lhs.lexicographicallyPrecedes(rhs)
    }

    static func wordpressVersion(in source: String) -> String? {
        guard let match = source.firstMatch(of: #/\$wp_version\s*=\s*'([^']+)'/#) else { return nil }
        return String(match.1)
    }

    static func customNginxFiles(siteFolder: URL) -> [String] {
        let folder = siteFolder.appendingPathComponent("conf/nginx")
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let base = folder.standardizedFileURL.path + "/"
        var custom: [String] = []
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile, !url.lastPathComponent.hasPrefix(".") else { continue }
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            if !stockNginxFiles.contains(relative), !relative.hasSuffix(".bak") {
                custom.append(relative)
            }
        }
        return custom.sorted()
    }
}
