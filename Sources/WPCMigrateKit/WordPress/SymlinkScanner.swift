import Foundation

/// A symlink in a LocalWP site that won't resolve inside the container: it is
/// absolute or points outside the WordPress folder.
public struct ExternalLink: Sendable, Equatable, Encodable {
    /// Path relative to the WordPress folder, e.g. `wp-content/plugins/foo`.
    public var path: String
    /// The fully resolved target on the host.
    public var target: String
    public var targetExists: Bool
    public var targetIsDirectory: Bool

    /// Whether wpc can bind-mount the target: a folder whose paths contain no
    /// `:`, which would split the mount argument.
    public var isMountable: Bool {
        targetExists && targetIsDirectory && !target.contains(":") && !path.contains(":")
    }
}

public enum SymlinkMode: String, Sendable, CaseIterable {
    /// Bind-mount each linked folder, so it stays live.
    case mount
    /// Copy what each link points to.
    case copy
}

public enum SymlinkScanner {
    /// Finds external symlinks under `root`. Linked folders are not walked.
    public static func scan(_ root: URL) -> [ExternalLink] {
        let manager = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        guard let enumerator = manager.enumerator(atPath: root.path) else { return [] }

        var links: [ExternalLink] = []
        for case let relative as String in enumerator {
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            let url = root.appendingPathComponent(relative)
            guard let destination = try? manager.destinationOfSymbolicLink(atPath: url.path) else { continue }

            var resolved = url.resolvingSymlinksInPath().path
            var exists = manager.fileExists(atPath: resolved)
            if !exists {
                let target = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
                resolved = target.standardizedFileURL.path
                exists = manager.fileExists(atPath: resolved)
            }
            let isInside = resolved == base || resolved.hasPrefix(base + "/")
            guard destination.hasPrefix("/") || !isInside else { continue }

            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: resolved, isDirectory: &isDirectory)
            links.append(ExternalLink(
                path: relative,
                target: resolved,
                targetExists: exists,
                targetIsDirectory: isDirectory.boolValue
            ))
        }
        return links.sorted { $0.path < $1.path }
    }
}
