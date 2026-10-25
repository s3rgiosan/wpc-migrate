import Foundation

/// One site from LocalWP's `sites.json`.
public struct LocalWPSite: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case running, halted, unknown
    }

    public enum Multisite: String, Sendable, Equatable {
        case none, subdirectory, subdomain

        /// The value `wpc create --multisite` takes, or nil for a single site.
        public var wpcValue: String? {
            switch self {
            case .none: return nil
            case .subdirectory: return "subdirectory"
            case .subdomain: return "subdomain"
            }
        }
    }

    public struct Database: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case mysql, mariadb
        }

        public var kind: Kind
        public var version: String
    }

    /// The login from `sites.json`'s `mysql` key; every LocalWP site uses
    /// `local` with `root`/`root`.
    public struct Credentials: Sendable, Equatable {
        public var database: String
        public var user: String
        public var password: String
    }

    public var id: String
    public var name: String
    public var domain: String
    /// The site folder; WordPress lives in `app/public` under it.
    public var path: URL
    public var status: Status
    public var multisite: Multisite
    public var phpVersion: String?
    public var database: Database?
    public var credentials: Credentials
    public var webServer: String?
    public var webServerVersion: String?
    public var xdebug: Bool
    public var redis: Bool
    public var elasticsearch: Bool

    public var wordpressFolder: URL {
        path.appendingPathComponent("app/public")
    }
}

/// LocalWP's site list, read from its Application Support folder. Reading it
/// never changes anything LocalWP owns.
public struct LocalWPCatalog: Sendable {
    public var root: URL
    public var sites: [LocalWPSite]

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Local")
    }

    public init(root: URL, sites: [LocalWPSite]) {
        self.root = root
        self.sites = sites
    }

    public static func load(root: URL = defaultRoot) throws -> LocalWPCatalog {
        let sitesURL = root.appendingPathComponent("sites.json")
        guard FileManager.default.fileExists(atPath: sitesURL.path) else {
            throw MigrateError.localNotFound(root.path)
        }
        let sitesJSON = try readObject(sitesURL)
        let statusURL = root.appendingPathComponent("site-statuses.json")
        let statuses = (try? readObject(statusURL)) ?? [:]

        let sites = sitesJSON.compactMap { id, value -> LocalWPSite? in
            guard let entry = value as? [String: Any] else { return nil }
            return site(id: id, entry: entry, status: statuses[id] as? String)
        }
        return LocalWPCatalog(root: root, sites: sites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// Finds a site by id, domain, or name (case-insensitive), in that order.
    public func find(_ query: String) throws -> LocalWPSite {
        if let site = sites.first(where: { $0.id == query }) { return site }
        let lowered = query.lowercased()
        let byDomain = sites.filter { $0.domain.lowercased() == lowered }
        if byDomain.count > 1 { throw MigrateError.ambiguousSite(query, matches: byDomain.map(\.id)) }
        if byDomain.count == 1 { return byDomain[0] }
        let byName = sites.filter { $0.name.lowercased() == lowered }
        switch byName.count {
        case 1: return byName[0]
        case 0: throw MigrateError.siteNotFound(query)
        default: throw MigrateError.ambiguousSite(query, matches: byName.map(\.id))
        }
    }

    /// LocalWP's own nginx templates for the site's nginx version, from its
    /// downloaded services or, failing that, the services Local.app ships.
    public func stockNginxFolder(for site: LocalWPSite) -> URL? {
        guard site.webServer == "nginx", let version = site.webServerVersion else { return nil }
        let manager = FileManager.default
        for services in [root.appendingPathComponent("lightning-services"), Self.bundledServices] {
            let names = (try? manager.contentsOfDirectory(atPath: services.path)) ?? []
            let matches = names.filter { $0 == "nginx-\(version)" || $0.hasPrefix("nginx-\(version)+") }
            for name in matches.sorted().reversed() {
                let conf = services.appendingPathComponent(name).appendingPathComponent("conf")
                if manager.fileExists(atPath: conf.appendingPathComponent("site.conf.hbs").path) {
                    return conf
                }
            }
        }
        return nil
    }

    /// LocalWP's runtime folder for a site: the MySQL datadir, socket, and
    /// rendered configs.
    public func runFolder(for site: LocalWPSite) -> URL {
        root.appendingPathComponent("run").appendingPathComponent(site.id)
    }

    static func site(id: String, entry: [String: Any], status: String?) -> LocalWPSite? {
        guard let rawPath = entry["path"] as? String else { return nil }
        let services = entry["services"] as? [String: Any] ?? [:]
        let mysql = entry["mysql"] as? [String: Any] ?? [:]
        let credentials = LocalWPSite.Credentials(
            database: mysql["database"] as? String ?? "local",
            user: mysql["user"] as? String ?? "root",
            password: mysql["password"] as? String ?? "root"
        )

        return LocalWPSite(
            id: id,
            name: entry["name"] as? String ?? id,
            domain: entry["domain"] as? String ?? "",
            path: URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL,
            status: LocalWPSite.Status(rawValue: status ?? "") ?? .unknown,
            multisite: multisite(entry["multiSite"] as? String),
            phpVersion: serviceVersion(services, "php") ?? legacyVersion(entry["phpVersion"]),
            database: database(services: services, legacy: entry["database"] as? String),
            credentials: credentials,
            webServer: webServer(services: services, legacy: entry["webServer"] as? String),
            webServerVersion: webServerVersion(services: services, legacy: entry["webServer"] as? String),
            xdebug: entry["xdebugEnabled"] as? Bool ?? false,
            redis: entry["redisEnabled"] as? Bool ?? false,
            elasticsearch: entry["elasticsearchEnabled"] as? Bool ?? false
        )
    }

    private static func readObject(_ url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MigrateError.invalidLocalData(file: url.lastPathComponent, detail: "expected a JSON object")
            }
            return object
        } catch let error as MigrateError {
            throw error
        } catch {
            throw MigrateError.invalidLocalData(file: url.lastPathComponent, detail: error.localizedDescription)
        }
    }

    private static func multisite(_ raw: String?) -> LocalWPSite.Multisite {
        switch raw {
        case "ms-subdir": return .subdirectory
        case "ms-subdomain": return .subdomain
        default: return .none
        }
    }

    private static func serviceVersion(_ services: [String: Any], _ key: String) -> String? {
        (services[key] as? [String: Any])?["version"] as? String
    }

    private static func legacyVersion(_ raw: Any?) -> String? {
        raw as? String
    }

    /// `services.mysql` / `services.mariadb`, falling back to the legacy
    /// top-level `database` key (`"mysql-8.0.16"`).
    private static func database(services: [String: Any], legacy: String?) -> LocalWPSite.Database? {
        if let version = serviceVersion(services, "mysql") {
            return .init(kind: .mysql, version: version)
        }
        if let version = serviceVersion(services, "mariadb") {
            return .init(kind: .mariadb, version: version)
        }
        guard let legacy, let dash = legacy.firstIndex(of: "-"),
              let kind = LocalWPSite.Database.Kind(rawValue: String(legacy[..<dash])) else { return nil }
        return .init(kind: kind, version: String(legacy[legacy.index(after: dash)...]))
    }

    /// The lightning services Local.app ships in its bundle.
    static let bundledServices = URL(fileURLWithPath: "/Applications/Local.app/Contents/Resources/extraResources/lightning-services")

    /// `services.nginx` / `services.apache`, falling back to the legacy
    /// top-level `webServer` key (`"nginx-1.16.0"`).
    private static func webServerVersion(services: [String: Any], legacy: String?) -> String? {
        if let version = serviceVersion(services, "nginx") ?? serviceVersion(services, "apache") {
            return version
        }
        guard let legacy, let dash = legacy.firstIndex(of: "-") else { return nil }
        return String(legacy[legacy.index(after: dash)...])
    }

    private static func webServer(services: [String: Any], legacy: String?) -> String? {
        if services["nginx"] != nil { return "nginx" }
        if services["apache"] != nil { return "apache" }
        return legacy?.split(separator: "-").first.map(String.init)
    }
}
