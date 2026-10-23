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

/// An absolute symlink whose target is inside the WordPress folder. It is
/// rewritten as a relative link, which resolves the same way in the container.
public struct InternalLink: Sendable, Equatable, Encodable {
    /// Path relative to the WordPress folder, e.g. `wp-content/db.php`.
    public var path: String
    /// The link's new destination, relative to the folder that holds it.
    public var destination: String
}

public struct SymlinkScan: Sendable, Equatable {
    public var externalLinks: [ExternalLink] = []
    public var internalLinks: [InternalLink] = []
}

public enum SymlinkMode: String, Sendable, CaseIterable {
    /// Bind-mount the linked folder, so it stays live.
    case mount
    /// Copy what the link points to.
    case copy
    /// Leave the link out of the new site.
    case skip
}

public enum SymlinkScanner {
    /// Finds the symlinks under `root` that won't resolve inside the
    /// container. Linked folders are not walked.
    public static func scan(_ root: URL) -> SymlinkScan {
        let manager = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        guard let enumerator = manager.enumerator(atPath: root.path) else { return SymlinkScan() }

        var scan = SymlinkScan()
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
            if isInside, exists {
                let target = String(resolved.dropFirst(base.count + 1))
                scan.internalLinks.append(InternalLink(path: relative, destination: relativeDestination(from: relative, to: target)))
                continue
            }

            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: resolved, isDirectory: &isDirectory)
            scan.externalLinks.append(ExternalLink(
                path: relative,
                target: resolved,
                targetExists: exists,
                targetIsDirectory: isDirectory.boolValue
            ))
        }
        scan.externalLinks.sort { $0.path < $1.path }
        scan.internalLinks.sort { $0.path < $1.path }
        return scan
    }

    /// The relative destination that takes a link at `path` to `target`, both
    /// relative to the same root.
    static func relativeDestination(from path: String, to target: String) -> String {
        let folder = path.split(separator: "/").dropLast()
        let target = target.split(separator: "/")
        var shared = 0
        while shared < folder.count, shared < target.count, folder[folder.startIndex + shared] == target[shared] {
            shared += 1
        }
        let parts = Array(repeating: "..", count: folder.count - shared) + target.dropFirst(shared).map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
