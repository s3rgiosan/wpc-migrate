import Foundation

/// What a LocalWP site becomes in wp-container, worked out before anything
/// runs.
public struct LocalWPPlan: Sendable {
    /// The oldest PHP version wp-container ships images for.
    public static let minimumPHP = "8.1"

    /// The file in the new site's `nginx/` folder that holds the rules added to
    /// LocalWP's `site.conf.hbs`.
    public static let siteRulesFileName = "site-rules.conf"

    /// Server-block directives wp-container sets itself, which the site's
    /// rules can't repeat.
    static let ownedNginxDirectives: Set<String> = [
        "listen", "server_name", "root", "index", "absolute_redirect",
        "client_max_body_size", "access_log", "error_log",
    ]

    /// Directives wp-container already sets to these values, or sets for
    /// itself, so the same lines in `site.conf.hbs` need no warning.
    static let redundantNginxStatements: Set<String> = ["absolute_redirect off;", "client_max_body_size 0;"]

    /// The nginx config files every LocalWP site has. Anything else in
    /// `conf/nginx` is a customization.
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
    /// Custom nginx files that `site.conf.hbs` includes and wp-container can
    /// include as they are: plain `.conf` files at the top of `conf/nginx`.
    public var nginxIncludes: [String] = []
    /// The statements added to LocalWP's stock `site.conf.hbs` server block
    /// that wp-container can include, or nil when there are none.
    public var nginxSiteRules: String?
    /// Whether `wp-content/object-cache.php` reads `WP_REDIS_*` constants, as
    /// the Redis Object Cache drop-in does. It needs a Redis server, which
    /// wp-container's Redis add-on runs and points `WP_REDIS_HOST` at.
    public var redisObjectCache = false
    public var warnings: [String]

    /// `stockNginxFolder` holds LocalWP's own nginx templates for the site's
    /// nginx version, which `site.conf.hbs` is compared with.
    public init(site: LocalWPSite, stockNginxFolder: URL? = nil) throws {
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

        let objectCache = try? Data(contentsOf: folder.appendingPathComponent("wp-content/object-cache.php"))
        redisObjectCache = objectCache?.range(of: Data("WP_REDIS_".utf8)) != nil

        let links = SymlinkScanner.scan(folder)
        externalLinks = links.externalLinks
        internalLinks = links.internalLinks
        for link in externalLinks where !link.targetExists {
            warnings.append("\(link.path) is a broken symlink (\(link.target)) and is skipped.")
        }

        if site.webServer == "nginx" {
            let nginxFolder = site.path.appendingPathComponent("conf/nginx")
            let custom = Self.customNginxFiles(siteFolder: site.path)
            let included = Self.includedNginxFiles(siteConf: nginxFolder.appendingPathComponent("site.conf.hbs"))
            let carried = custom.filter { name in
                guard included.contains(name), !name.contains("/"), name.hasSuffix(".conf") else { return false }
                let contents = try? String(contentsOf: nginxFolder.appendingPathComponent(name), encoding: .utf8)
                return contents.map { !$0.contains("{{") } ?? false
            }
            nginxIncludes = carried
            let left = custom.filter { !carried.contains($0) }

            let siteConf = try? String(contentsOf: nginxFolder.appendingPathComponent("site.conf.hbs"), encoding: .utf8)
            var rulesWarning: String?
            if let stockNginxFolder {
                let stockConf = try? String(contentsOf: stockNginxFolder.appendingPathComponent("site.conf.hbs"), encoding: .utf8)
                if let siteConf, let stockConf, let additions = NginxConf.additions(in: siteConf, comparedTo: stockConf) {
                    let (rules, dropped) = Self.siteRules(from: additions)
                    nginxSiteRules = rules
                    if !dropped.isEmpty {
                        rulesWarning = "Custom nginx rules in site.conf.hbs are not carried over: \(dropped.joined(separator: ", "))."
                    }
                } else if siteConf != nil {
                    rulesWarning = "site.conf.hbs could not be compared with LocalWP's stock template, so rules added to it are not carried over."
                }
            } else if siteConf != nil {
                rulesWarning = "LocalWP's stock nginx templates were not found, so rules added to site.conf.hbs are not carried over."
            }

            if !left.isEmpty {
                warnings.append("Custom nginx config is not carried over: \(left.joined(separator: ", ")).")
            }
            if let rulesWarning {
                warnings.append(rulesWarning)
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

    /// Splits the statements added to `site.conf.hbs` into the rules the new
    /// site includes and short labels for the ones it can't.
    static func siteRules(from additions: [NginxStatement]) -> (rules: String?, dropped: [String]) {
        var rules: [String] = []
        var dropped: [String] = []
        for statement in additions {
            // Includes are carried as files, and wp-container listens on its own port.
            if statement.name == "include" || statement.name == "listen" || redundantNginxStatements.contains(statement.key) {
                continue
            }
            if statement.isTemplated || ownedNginxDirectives.contains(statement.name) {
                dropped.append(statement.key.count > 60 ? statement.key.prefix(59) + "…" : statement.key)
            } else {
                rules.append(statement.text)
            }
        }
        return (rules.isEmpty ? nil : rules.joined(separator: "\n\n") + "\n", dropped)
    }

    /// The paths `site.conf.hbs` names in its `include` directives.
    static func includedNginxFiles(siteConf: URL) -> Set<String> {
        guard let contents = try? String(contentsOf: siteConf, encoding: .utf8) else { return [] }
        let paths = contents.matches(of: #/include\s+["']?([^"';\s]+)["']?\s*;/#).map { String($0.1) }
        return Set(paths)
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
