import XCTest
@testable import LLMPro

/// Regression tests for `Core/ProcessRunner.swift`.
///
/// A recent audit fix changed ProcessRunner's stream lifecycle:
///   - the pipe's `readabilityHandler` now owns stream-finish on EOF (it drains the
///     buffered remainder *then* calls `continuation.finish()`), instead of the exit
///     Task racing a `finish()` that could drop the final un-newline-terminated line;
///   - `continuation.onTermination` terminates the child if a consumer Task is
///     cancelled (so an abandoned stream doesn't orphan the process);
///   - `RunningProcess.kill()` was added (SIGKILL escalation).
///
/// These tests pin the exact behaviors that fix targets so a future regression is
/// caught. All commands use `/bin/sh` (always present on macOS) for deterministic
/// output. No network, no app state.
final class ProcessRunnerTests: XCTestCase {

    /// `/bin/sh` is always present on macOS. Declared as a file-scope helper so the
    /// `@Sendable` timeout closures capture a value (a URL), never `self`.
    private static let sh = URL(fileURLWithPath: "/bin/sh")

    // MARK: - Sendable line collector

    /// Thread-safe collector for the `onStdout` callback, which fires on the pipe's
    /// reader queue. Lets the `@Sendable` callback accumulate lines without capturing
    /// a mutable var (which Swift 6 strict concurrency forbids).
    private final class LineCollector: @unchecked Sendable {
        private var lines: [String] = []
        private let lock = NSLock()
        func append(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }; return lines
        }
    }

    // MARK: - Bounded-wait helper

    /// Awaits an async value, failing the test (rather than hanging the suite) if it
    /// does not resolve within `seconds`. A regression that fails to finish a stream
    /// or to reap a child therefore FAILS here instead of blocking forever.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ label: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError(label: label)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TimeoutError(label: label)
            }
            return first
        }
    }

    private struct TimeoutError: Error, CustomStringConvertible {
        let label: String
        var description: String { "timed out waiting for: \(label)" }
    }

    // MARK: - 1. Full stdout capture incl. the tail (the core fix)

    /// The old code could drop the final line because the exit Task's `finish()`
    /// raced the EOF drain. Emit 200 numbered lines via the streaming path and assert
    /// every one arrives, the LAST is exactly `line200` (the tail), the stream
    /// terminates (the `for await` loop ends → `finish()` fired), and exit code is 0.
    func testStreamingCapturesAllLinesIncludingTail() async throws {
        let proc = try await ProcessRunner.spawn(
            executable: Self.sh,
            arguments: ["-c", "for i in $(seq 1 200); do echo line$i; done"]
        )

        let stdout = proc.stdout
        let lines = try await withTimeout(10, "stdout stream to complete") {
            var collected: [String] = []
            for await line in stdout {
                collected.append(line)
            }
            return collected
        }

        XCTAssertEqual(lines.count, 200, "every emitted line must be delivered")
        XCTAssertEqual(lines.first, "line1")
        XCTAssertEqual(lines.last, "line200", "the final tail line must not be dropped")
        // Exact, in-order content check (catches any reordering or gap).
        XCTAssertEqual(lines, (1...200).map { "line\($0)" })

        let exitTask = proc.exit
        let exit = try await withTimeout(10, "exit to resolve") { try await exitTask.value }
        XCTAssertEqual(exit.code, 0)
        XCTAssertNil(exit.signal, "a normal exit must carry no signal")
    }

    /// A line that is NOT newline-terminated (the process exits with bytes still in
    /// the buffer) is the precise case the EOF-drain fix protects. `printf` (no
    /// trailing newline) must still surface as the final line.
    func testStreamingCapturesUnterminatedFinalLine() async throws {
        let proc = try await ProcessRunner.spawn(
            executable: Self.sh,
            arguments: ["-c", "printf 'first\\nlast-no-newline'"]
        )

        let stdout = proc.stdout
        let lines = try await withTimeout(10, "stdout stream (unterminated tail)") {
            var collected: [String] = []
            for await line in stdout {
                collected.append(line)
            }
            return collected
        }

        XCTAssertEqual(lines, ["first", "last-no-newline"],
                       "the un-newline-terminated final line must be drained before finish()")
    }

    // MARK: - 2. runCapturing returns full output

    /// runCapturing joins lines with "\n" and appends a trailing newline. Assert the
    /// complete known output — including the final line — is present in the return
    /// value and in the onStdout callbacks.
    func testRunCapturingReturnsFullOutput() async throws {
        let collector = LineCollector()

        let output = try await withTimeout(10, "runCapturing to complete") {
            try await ProcessRunner.runCapturing(
                executable: Self.sh,
                arguments: ["-c", "echo alpha; echo beta; echo gamma"],
                onStdout: { line in collector.append(line) }
            )
        }

        XCTAssertEqual(output, "alpha\nbeta\ngamma\n",
                       "runCapturing must return the complete stdout including the final line")
        XCTAssertEqual(collector.snapshot, ["alpha", "beta", "gamma"],
                       "onStdout must fire once per line, final line included")
    }

    // MARK: - 3. Non-zero exit + stderr tail

    /// runCapturing throws `nonZeroExit` carrying the stderr content. The audit's
    /// concern was the error tail being lost — assert both the code (3) and that the
    /// stderr "oops" survived to the thrown error.
    func testNonZeroExitThrowsWithStderrTail() async throws {
        do {
            _ = try await withTimeout(10, "runCapturing (non-zero exit)") {
                try await ProcessRunner.runCapturing(
                    executable: Self.sh,
                    arguments: ["-c", "echo oops 1>&2; exit 3"]
                )
            }
            XCTFail("runCapturing must throw on a non-zero exit")
        } catch let ProcessRunnerError.nonZeroExit(code, stderr) {
            XCTAssertEqual(code, 3, "the child's exit code must surface unchanged")
            XCTAssertTrue(stderr.contains("oops"),
                          "the stderr tail must be captured, not lost (got: \(stderr.debugDescription))")
        }
    }

    /// The same scenario via the streaming path: stderr stream carries "oops" and the
    /// exit code is 3 (no throw on this path — the caller inspects exit.code).
    func testStreamingNonZeroExitSurfacesCodeAndStderr() async throws {
        let proc = try await ProcessRunner.spawn(
            executable: Self.sh,
            arguments: ["-c", "echo oops 1>&2; exit 3"]
        )

        let stderr = proc.stderr
        let stderrLines = try await withTimeout(10, "stderr stream to complete") {
            var collected: [String] = []
            for await line in stderr {
                collected.append(line)
            }
            return collected
        }

        XCTAssertEqual(stderrLines, ["oops"], "stderr tail must be delivered via the stream")

        let exitTask = proc.exit
        let exit = try await withTimeout(10, "exit to resolve") { try await exitTask.value }
        XCTAssertEqual(exit.code, 3)
    }

    // MARK: - 4. Stream terminates on normal exit (no hang)

    /// Consuming BOTH stdout and stderr streams of a short command must complete.
    /// A regression that fails to finish a stream would hit the timeout and FAIL
    /// here rather than hanging the whole suite.
    func testBothStreamsTerminateOnNormalExit() async throws {
        let proc = try await ProcessRunner.spawn(
            executable: Self.sh,
            arguments: ["-c", "echo to-stdout; echo to-stderr 1>&2"]
        )

        let stdout = proc.stdout
        let stderr = proc.stderr
        let (out, err) = try await withTimeout(10, "both streams to complete") {
            async let outLines: [String] = {
                var c: [String] = []
                for await l in stdout { c.append(l) }
                return c
            }()
            async let errLines: [String] = {
                var c: [String] = []
                for await l in stderr { c.append(l) }
                return c
            }()
            return await (outLines, errLines)
        }

        XCTAssertEqual(out, ["to-stdout"])
        XCTAssertEqual(err, ["to-stderr"])

        let exitTask = proc.exit
        let exit = try await withTimeout(10, "exit to resolve") { try await exitTask.value }
        XCTAssertEqual(exit.code, 0)
    }

    // MARK: - 5. Cancellation reaps the child (onTermination → terminate)

    /// Spawn a long sleeper, consume its stdout in a child Task, cancel that Task,
    /// and assert the process is reaped promptly. Cancelling the consumer finishes
    /// the AsyncStream, which fires `continuation.onTermination`, which terminates the
    /// child — so `proc.exit.value` should resolve (with a signal) well within the
    /// timeout. The timeout is generous to avoid flakiness; a regression where the
    /// child is NOT reaped would otherwise run for 30s and blow past it.
    func testCancellingConsumerReapsChild() async throws {
        let proc = try await ProcessRunner.spawn(
            executable: Self.sh,
            arguments: ["-c", "sleep 30"]
        )

        let stdout = proc.stdout
        let consumer = Task {
            for await _ in stdout { /* drain; sleeper emits nothing */ }
        }

        // Give the child a beat to actually start, then cancel the consumer. Cancelling
        // the Task that owns the `for await` finishes the stream → onTermination fires.
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()

        let exitTask = proc.exit
        let exit = try await withTimeout(8, "child to be reaped after consumer cancel") {
            try await exitTask.value
        }

        // Reaped via SIGTERM (Process.terminate) → exit reports a signal, not code 0.
        XCTAssertNotEqual(exit.code, 0, "a terminated sleeper must not report a clean exit")
        XCTAssertNotNil(exit.signal, "termination must surface as a signal, proving the child was reaped")
    }
}
