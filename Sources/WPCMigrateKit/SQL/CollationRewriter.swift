import Foundation

/// Rewrites MySQL 8 `utf8mb4_0900_*` collations, which MariaDB does not
/// support on every version, in a dump file.
///
/// Only schema lines change. `INSERT INTO` lines pass through byte for byte, so
/// row data that happens to mention a collation name is never altered.
public enum CollationRewriter {
    static let marker = Array("_0900_".utf8)
    static let insertPrefix = Array("INSERT INTO".utf8)

    /// Maps one collation name. `utf8mb4_0900_bin` keeps binary comparison;
    /// every other `utf8mb4_0900_*` becomes WordPress's default collation.
    public static func replacement(for collation: String) -> String {
        collation == "utf8mb4_0900_bin" ? "utf8mb4_bin" : "utf8mb4_unicode_520_ci"
    }

    public static func rewrite(line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "utf8mb4_0900_[a-z_]+") else { return line }
        var result = line
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(for: String(result[range])))
        }
        return result
    }

    /// Streams `input` to `output`, rewriting collations line by line. Returns
    /// the number of lines changed.
    @discardableResult
    public static func rewrite(input: URL, output: URL) throws -> Int {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        var changed = 0
        var pending = Data()
        let newline = UInt8(ascii: "\n")

        func emit(_ line: Data) {
            guard !line.starts(with: insertPrefix), line.firstRange(of: marker) != nil else {
                writer.write(line)
                return
            }
            let text = String(decoding: line, as: UTF8.self)
            let rewritten = rewrite(line: text)
            if rewritten != text { changed += 1 }
            writer.write(Data(rewritten.utf8))
        }

        while true {
            let chunk = try reader.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let index = pending[lineStart...].firstIndex(of: newline) {
                emit(pending[lineStart...index])
                lineStart = pending.index(after: index)
            }
            pending = Data(pending[lineStart...])
        }
        if !pending.isEmpty { emit(pending) }
        return changed
    }
}
