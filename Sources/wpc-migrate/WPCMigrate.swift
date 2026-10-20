import ArgumentParser
import Foundation
import WPCMigrateKit

@main
struct WPCMigrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wpc-migrate",
        abstract: "Move WordPress sites from other local tools into wp-container.",
        version: WPCMigrateVersion.current,
        subcommands: [LocalWPCommand.self]
    )
}

/// Progress and warnings go to stderr so stdout carries only the result.
enum Console {
    static func step(_ message: String) {
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// Reports an error as `{error, detail}` on stderr when `json` is set, the
    /// same shape wpc uses.
    static func fail(_ error: Error, json: Bool) -> Error {
        guard json else { return error }
        let code: String
        switch error {
        case let error as MigrateError: code = error.code
        case let error as WPCError: code = error.code ?? "wpc_failed"
        case is ValidationError: code = "bad_args"
        default: code = "failed"
        }
        let payload = ["error": code, "detail": String(describing: error)]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        }
        return ExitCode.failure
    }
}
