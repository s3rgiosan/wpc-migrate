import Foundation

/// The slug and folder wpc gives a new site, worked out ahead of `wpc create`
/// so the site's files can be in place before wpc first starts it.
public enum WPCSlug {
    /// Lowercase, ASCII-folded, reduced to `[a-z0-9-]` with single dashes;
    /// `site` when nothing is left.
    public static func make(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var slug = ""
        var lastDash = false
        for character in folded {
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) {
                slug.append(character)
                lastDash = false
            } else if "-_ ./".contains(character), !slug.isEmpty, !lastDash {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "site" : slug
    }

    /// wp-container's sites folder: the app's `defaultSitesRoot` setting, else
    /// `~/WP Container Sites`.
    public static var defaultSitesRoot: URL {
        let setting = UserDefaults(suiteName: "com.fabiankaegy.wpcontainer")?.string(forKey: "defaultSitesRoot")
        if let setting, !setting.isEmpty {
            return URL(fileURLWithPath: setting, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WP Container Sites", isDirectory: true)
    }
}
