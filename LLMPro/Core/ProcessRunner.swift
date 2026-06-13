import Foundation
import Darwin

struct ProcessExit: Sendable {
    let code: Int32
    let signal: Int32?
    var isSuccess: Bool { code == 0 }
}

struct RunningProcess: @unchecked Sendable {
    let pid: Int32
    let stdout: AsyncStream<String>
    let stderr: AsyncStream<String>
    let exit: Task<ProcessExit, Error>
    private let process: Process

    init(process: Process, stdout: AsyncStream<String>, stderr: AsyncStream<String>, exit: Task<ProcessExit, Error>) {
        self.process = process
        self.pid = process.processIdentifier
        self.stdout = stdout
        self.stderr = stderr
        self.exit = exit
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func interrupt() {
        guard process.isRunning else { return }
        process.interrupt()
    }

    /// SIGKILL — the hard escalation when `terminate()` (SIGTERM) is ignored.
    /// `Process` has no kill API, so signal the PID directly.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func detach() {
        // Caller gives up termination rights; process continues independently.
    }
}

enum ProcessRunnerError: Error, LocalizedError {
    case spawnFailed(String)
    case nonZeroExit(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): "Failed to spawn process: \(m)"
        case .nonZeroExit(let code, let stderr): "Process exited with code \(code): \(stderr)"
        }
    }
}

enum ProcessRunner {
    /// Run a process, streaming stdout / stderr line-by-line. Throws on non-zero exit.
    @discardableResult
    static func runCapturing(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onStdout: (@Sendable (String) -> Void)? = nil,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let running = try await spawn(
            executable: executable, arguments: arguments,
            environment: environment, currentDirectory: currentDirectory
        )

        let stdoutTask = Task<String, Never> {
            var buf = ""
            for await line in running.stdout {
                onStdout?(line)
                buf.append(line); buf.append("\n")
            }
            return buf
        }
        let stderrTask = Task<String, Never> {
            var buf = ""
            for await line in running.stderr {
                onStderr?(line)
                buf.append(line); buf.append("\n")
            }
            return buf
        }

        let exit = try await running.exit.value
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        if exit.code != 0 {
            let tail = stderr.split(separator: "\n").suffix(5).joined(separator: " ⏎ ")
            Log.error("subprocess exit \(exit.code): \(executable.lastPathComponent) \(arguments.prefix(3).joined(separator: " ")) — \(tail)", .python)
            throw ProcessRunnerError.nonZeroExit(code: exit.code, stderr: stderr)
        }
        return stdout
    }

    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let (stdoutStream, stdoutCont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let (stderrStream, stderrCont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)

        // If the consumer abandons the stream (its awaiting Task is cancelled),
        // reap the child so it doesn't orphan, and tear down the readabilityHandler
        // so the continuation + LineBuffer aren't retained forever. `process` is a
        // reference type; capture it through a Sendable box for the @Sendable closure.
        let procBox = SendableBox(process)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        stdoutCont.onTermination = { @Sendable _ in
            outHandle.readabilityHandler = nil
            if procBox.value.isRunning { procBox.value.terminate() }
        }
        stderrCont.onTermination = { @Sendable _ in
            errHandle.readabilityHandler = nil
            if procBox.value.isRunning { procBox.value.terminate() }
        }

        // The readabilityHandler owns stream termination: it finishes the
        // continuation on EOF *after* draining the buffered remainder, so the final
        // traceback/error line is never lost to a racing finish() from the exit Task.
        attachLineReader(handle: outHandle, continuation: stdoutCont)
        attachLineReader(handle: errHandle, continuation: stderrCont)

        Log.info("spawn: \(executable.lastPathComponent) \(arguments.joined(separator: " "))", .python)
        do {
            try process.run()
        } catch {
            Log.error("spawn failed: \(executable.lastPathComponent)", .python, error: error)
            throw ProcessRunnerError.spawnFailed(error.localizedDescription)
        }

        let exitTask = Task<ProcessExit, Error> {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
            // Do NOT finish the continuations here — the readabilityHandler finishes
            // each stream itself once it has seen EOF and drained the buffered tail.
            // Finishing here would race the EOF drain and drop the final line.
            return ProcessExit(
                code: process.terminationStatus,
                signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
            )
        }

        return RunningProcess(process: process, stdout: stdoutStream, stderr: stderrStream, exit: exitTask)
    }

    private static func attachLineReader(handle: FileHandle, continuation: AsyncStream<String>.Continuation) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                if let remainder = buffer.drainRemainder() {
                    continuation.yield(remainder)
                }
                fh.readabilityHandler = nil
                // EOF: this reader owns termination — finish only after the
                // buffered remainder has been yielded, so the tail is never lost.
                continuation.finish()
                return
            }
            for line in buffer.append(chunk) {
                continuation.yield(line)
            }
        }
    }
}

/// Wraps a non-Sendable reference in a Sendable container so it can be captured
/// by a @Sendable continuation-termination closure. Safe here because the only
/// access is `isRunning` / `terminate()`, which `Process` serializes internally.
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe line buffer for piped stdout/stderr.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let nlIdx = data.firstIndex(of: 0x0a) {
            let lineData = data.subdata(in: data.startIndex..<nlIdx)
            data.removeSubrange(data.startIndex...nlIdx)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    func drainRemainder() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let s = String(data: data, encoding: .utf8)
        data.removeAll(keepingCapacity: false)
        return s
    }
}
