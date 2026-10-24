import Foundation

/// Rewrites a LocalWP `wp-config.php` so it runs under wp-container.
///
/// The database defines read wp-container's `WORDPRESS_DB_*` environment, and
/// the multisite and URL constants are removed because wp-container's
/// provisioning writes its own. A `WP_ENVIRONMENT_TYPE` set to a plain string
/// moves to the top, so code loaded earlier in the file sees it: WordPress
/// VIP's `000-pre-vip-config/requires.php` allows `wp db` only when the
/// environment is already `local`. The table prefix, salts, and every other
/// constant stay as they are.
public enum WPConfigTransformer {
    static let databaseDefaults: [(constant: String, variable: String, fallback: String)] = [
        ("DB_NAME", "WORDPRESS_DB_NAME", "wordpress"),
        ("DB_USER", "WORDPRESS_DB_USER", "wordpress"),
        ("DB_PASSWORD", "WORDPRESS_DB_PASSWORD", "wordpress"),
        ("DB_HOST", "WORDPRESS_DB_HOST", "localhost"),
    ]

    static let removedConstants = [
        "WP_ALLOW_MULTISITE", "MULTISITE", "SUBDOMAIN_INSTALL", "DOMAIN_CURRENT_SITE",
        "PATH_CURRENT_SITE", "SITE_ID_CURRENT_SITE", "BLOG_ID_CURRENT_SITE",
        "WP_HOME", "WP_SITEURL",
    ]

    public static func transform(_ source: String) -> String {
        var text = source
        for item in databaseDefaults {
            let replacement = "define( '\(item.constant)', getenv( '\(item.variable)' ) ?: '\(item.fallback)' );"
            text = replacingDefine(item.constant, in: text) { _ in replacement }
        }
        for constant in removedConstants {
            text = removingGuardedDefines(constant, in: text)
            text = removingDefineLines(constant, in: text)
        }
        return movingEnvironmentTypeToTop(in: text)
    }

    /// The `$table_prefix` value, or nil when it isn't a plain string literal.
    public static func tablePrefix(in source: String) -> String? {
        let pattern = #"^\s*\$table_prefix\s*=\s*['"]([A-Za-z0-9_]+)['"]\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let prefixRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[prefixRange])
    }

    /// A define's value: quoted PHP strings are opaque, so `;` and `)` inside them don't end it.
    private static let valuePattern = #"(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|[^;'"])*?"#

    private static func definePattern(_ constant: String) -> String {
        #"define\s*\(\s*['"]"# + constant + #"['"]\s*,"# + valuePattern + #"\)\s*;"#
    }

    private static func replacingDefine(_ constant: String, in text: String, with replacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: definePattern(constant)) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement(constant))
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Removes `if ( ! defined( 'X' ) ) { define( 'X', … ); }` blocks.
    private static func removingGuardedDefines(_ constant: String, in text: String) -> String {
        let guardPattern = #"^[ \t]*if\s*\(\s*!\s*defined\s*\(\s*['"]"# + constant + #"['"]\s*\)\s*\)\s*\{\s*"#
        let pattern = guardPattern + definePattern(constant) + #"[ \t]*(//[^\r\n]*)?\s*\}[ \t]*\r?\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Moves a line that defines `WP_ENVIRONMENT_TYPE` as a string literal to
    /// just after the opening `<?php` line.
    private static func movingEnvironmentTypeToTop(in text: String) -> String {
        let literal = #"(?:'[A-Za-z0-9_-]*'|"[A-Za-z0-9_-]*")"#
        let pattern = #"^[ \t]*define\s*\(\s*['"]WP_ENVIRONMENT_TYPE['"]\s*,\s*"# + literal + #"\s*\)\s*;[ \t]*(//[^\r\n]*)?\r?\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let opening = text.range(of: #"^<\?php[ \t]*\r?\n"#, options: .regularExpression),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              range.lowerBound >= opening.upperBound else { return text }
        return String(text[..<opening.upperBound]) + text[range] + text[opening.upperBound..<range.lowerBound] + text[range.upperBound...]
    }

    /// Removes lines whose only statement is the define, including a trailing
    /// `//` comment.
    private static func removingDefineLines(_ constant: String, in text: String) -> String {
        let pattern = #"^[ \t]*"# + definePattern(constant) + #"[ \t]*(//[^\r\n]*)?\r?\n?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
