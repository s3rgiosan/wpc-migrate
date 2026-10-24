import Foundation

/// WordPress's standard single-site rewrite rules. LocalWP serves sites with
/// nginx, so its sites have no `.htaccess`, and Apache needs one for pretty
/// permalinks. nginx sites get one too, so a switch to Apache keeps working.
public enum Htaccess {
    public static let singleSite = """
        # BEGIN WordPress
        <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteBase /
        RewriteRule ^index\\.php$ - [L]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule . /index.php [L]
        </IfModule>
        # END WordPress

        """

    /// Writes the single-site rules unless the folder already has an
    /// `.htaccess`. Returns whether it wrote one.
    @discardableResult
    public static func writeIfMissing(wordpressFolder: URL) throws -> Bool {
        let url = wordpressFolder.appendingPathComponent(".htaccess")
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try singleSite.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
