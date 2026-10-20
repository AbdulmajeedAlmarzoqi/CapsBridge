import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

public enum ProcessRunner {
    /// Runs a program to its end and returns what it printed. Cancelling the task stops the program.
    public static func run(_ executable: URL, arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let collected = Collected()
                let readers = DispatchGroup()
                // Both pipes are drained while the program runs: a full pipe would stall it.
                for (pipe, isError) in [(outputPipe, false), (errorPipe, true)] {
                    readers.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        collected.set(data, isError: isError)
                        readers.leave()
                    }
                }
                process.terminationHandler = { finished in
                    readers.notify(queue: .global()) {
                        continuation.resume(returning: ProcessOutput(
                            status: finished.terminationStatus,
                            standardOutput: collected.output,
                            standardError: collected.error))
                    }
                }
                do {
                    try process.run()
                    // The cancellation handler ran before there was a process to stop.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outputData = Data()
        private var errorData = Data()

        func set(_ data: Data, isError: Bool) {
            lock.withLock {
                if isError { errorData = data } else { outputData = data }
            }
        }

        var output: Data { lock.withLock { outputData } }
        var error: Data { lock.withLock { errorData } }
    }
}
