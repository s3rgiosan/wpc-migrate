import Foundation

public enum MigrateError: Error, Sendable, CustomStringConvertible {
    case localNotFound(String)
    case invalidLocalData(file: String, detail: String)
    case siteNotFound(String)
    case ambiguousSite(String, matches: [String])
    case wordpressFolderMissing(String)
    case unsupportedDatabase(String)
    case mysqlBinariesMissing(String)
    case databaseServerFailed(String)
    case dumpFailed(String)
    case slugTaken(String)
    case siteFolderExists(String)
    case unexpectedSite(slug: String, path: String)
    case copyFailed(String)
    case wpcNotFound
    case wpcTooOld(found: String, required: String)

    /// A stable snake_case identifier for JSON output.
    public var code: String {
        switch self {
        case .localNotFound: return "local_not_found"
        case .invalidLocalData: return "invalid_local_data"
        case .siteNotFound: return "site_not_found"
        case .ambiguousSite: return "ambiguous_site"
        case .wordpressFolderMissing: return "wordpress_missing"
        case .unsupportedDatabase: return "unsupported_database"
        case .mysqlBinariesMissing: return "mysql_binaries_missing"
        case .databaseServerFailed: return "database_server_failed"
        case .dumpFailed: return "dump_failed"
        case .slugTaken: return "slug_taken"
        case .siteFolderExists: return "site_folder_exists"
        case .unexpectedSite: return "unexpected_site"
        case .copyFailed: return "copy_failed"
        case .wpcNotFound: return "wpc_not_found"
        case .wpcTooOld: return "wpc_too_old"
        }
    }

    public var description: String {
        switch self {
        case .localNotFound(let path):
            return "LocalWP data not found at \(path). Is LocalWP installed?"
        case .invalidLocalData(let file, let detail):
            return "\(file) could not be read: \(detail)"
        case .siteNotFound(let query):
            return "No LocalWP site matches \"\(query)\". Run `wpc-migrate localwp list` to see them."
        case .ambiguousSite(let query, let matches):
            return "\"\(query)\" matches several LocalWP sites (\(matches.joined(separator: ", "))). Use the site id."
        case .wordpressFolderMissing(let path):
            return "No WordPress install at \(path)."
        case .unsupportedDatabase(let detail):
            return "\(detail) Export the database from LocalWP and pass it with --dump."
        case .mysqlBinariesMissing(let version):
            return "LocalWP's MySQL \(version) binaries were not found in lightning-services. Export the database from LocalWP and pass it with --dump."
        case .databaseServerFailed(let detail):
            return "The temporary MySQL server did not start: \(detail)"
        case .dumpFailed(let detail):
            return "Database dump failed: \(detail)"
        case .slugTaken(let slug):
            return "wp-container already has a site or env named \(slug). Pass --name to choose another name."
        case .siteFolderExists(let path):
            return "\(path) already exists. Pass --name or --path to choose another folder."
        case .unexpectedSite(let slug, let path):
            return "wpc created \(slug) at \(path), not where its files were placed."
        case .copyFailed(let detail):
            return "Copying WordPress files failed: \(detail)"
        case .wpcNotFound:
            return "wpc was not found in PATH. Install the wp-container CLI first."
        case .wpcTooOld(let found, let required):
            return "wp-container \(found) is too old; wpc-migrate needs \(required) or newer."
        }
    }
}
