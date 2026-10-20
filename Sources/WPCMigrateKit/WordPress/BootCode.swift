import Foundation

/// The code WordPress runs on every request whether or not it is activated:
/// must-use plugins and `wp-content` drop-ins.
///
/// wp-container installs WordPress on a site's first start, before the
/// LocalWP database is imported. Site code that expects its own tables can
/// stop that install, so it is parked until the first start is done.
public enum BootCode {
    static let parkingFolder = ".wpc-migrate-parked"

    static let dropIns = [
        "advanced-cache.php", "blog-deleted.php", "blog-inactive.php", "blog-suspended.php",
        "db.php", "db-error.php", "fatal-error-handler.php", "install.php", "maintenance.php",
        "object-cache.php", "php-error.php", "sunrise.php",
    ]

    /// Moves the boot code out of `wp-content` and returns the moved paths,
    /// relative to `wp-content`.
    public static func park(in wordpressFolder: URL) throws -> [String] {
        let manager = FileManager.default
        let content = wordpressFolder.appendingPathComponent("wp-content")
        let parking = content.appendingPathComponent(parkingFolder)
        var parked: [String] = []
        for name in ["mu-plugins"] + dropIns where manager.fileExists(atPath: content.appendingPathComponent(name).path) {
            try manager.createDirectory(at: parking, withIntermediateDirectories: true)
            try manager.moveItem(at: content.appendingPathComponent(name), to: parking.appendingPathComponent(name))
            parked.append(name)
        }
        return parked
    }

    /// Moves parked code back and returns the paths, relative to the parking
    /// folder, that stayed there because the site already has something at the
    /// destination. A folder that reappeared in the meantime (a mount point
    /// inside `mu-plugins`) gets the parked entries merged into it.
    @discardableResult
    public static func restore(_ parked: [String], in wordpressFolder: URL) throws -> [String] {
        let manager = FileManager.default
        let content = wordpressFolder.appendingPathComponent("wp-content")
        let parking = content.appendingPathComponent(parkingFolder)
        var left: [String] = []
        for name in parked {
            let source = parking.appendingPathComponent(name)
            let destination = content.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            guard manager.fileExists(atPath: destination.path) else {
                do {
                    try manager.moveItem(at: source, to: destination)
                } catch {
                    left.append(name)
                }
                continue
            }
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue else {
                left.append(name)
                continue
            }
            let children = (try? manager.contentsOfDirectory(atPath: source.path)) ?? []
            for child in children.sorted() {
                let target = destination.appendingPathComponent(child)
                do {
                    guard !manager.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                    try manager.moveItem(at: source.appendingPathComponent(child), to: target)
                } catch {
                    left.append("\(name)/\(child)")
                }
            }
            try removeIfEmpty(source)
        }
        try removeIfEmpty(parking)
        return left
    }

    /// Removes `folder` only when it is empty, so anything still parked stays on disk.
    private static func removeIfEmpty(_ folder: URL) throws {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        if contents.isEmpty {
            try manager.removeItem(at: folder)
        }
    }
}
