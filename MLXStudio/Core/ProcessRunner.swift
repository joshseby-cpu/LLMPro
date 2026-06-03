import Foundation

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

        attachLineReader(handle: outPipe.fileHandleForReading, continuation: stdoutCont)
        attachLineReader(handle: errPipe.fileHandleForReading, continuation: stderrCont)

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
            stdoutCont.finish()
            stderrCont.finish()
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
                return
            }
            for line in buffer.append(chunk) {
                continuation.yield(line)
            }
        }
    }
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
