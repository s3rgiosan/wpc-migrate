import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a command to completion. Tests swap in a fake that records calls.
public protocol ProcessRunning: Sendable {
    /// Runs `executable` and waits for it. When `stdoutFile` is set, stdout is
    /// written there and `ProcessResult.stdout` stays empty.
    func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]?,
        stdoutFile: URL?
    ) throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
        try run(executable, arguments, environment: nil, stdoutFile: nil)
    }
}

public struct ProcessRunner: ProcessRunning {
    /// Copy the child's stderr to ours as it arrives, so long wpc steps
    /// (image pulls, imports) show progress.
    public var echoStderr: Bool

    public init(echoStderr: Bool = false) {
        self.echoStderr = echoStderr
    }

    public func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]?,
        stdoutFile: URL?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var outputHandle: FileHandle?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: stdoutFile)
            outputHandle = handle
            process.standardOutput = handle
        } else {
            process.standardOutput = stdoutPipe
        }
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes on their own threads so a chatty child can't fill a
        // pipe buffer and block before it exits.
        let group = DispatchGroup()
        let stdoutBuffer = DataBuffer()
        let stderrBuffer = DataBuffer()
        if stdoutFile == nil {
            drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer, echo: false, group: group)
        }
        drain(stderrPipe.fileHandleForReading, into: stderrBuffer, echo: echoStderr, group: group)

        process.waitUntilExit()
        group.wait()
        try outputHandle?.close()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.string,
            stderr: stderrBuffer.string
        )
    }

    private func drain(_ handle: FileHandle, into buffer: DataBuffer, echo: Bool, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if echo { FileHandle.standardError.write(chunk) }
            }
            group.leave()
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
