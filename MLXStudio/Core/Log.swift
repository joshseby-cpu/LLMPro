import Foundation
import OSLog
import Darwin

// MARK: - Crash breadcrumb machinery (fileprivate top-level so the signal handler
// is a true context-free C function — a @convention(c) closure must not capture).

/// Append-mode fd to the log file, opened once at install for the signal handler.
/// -1 until installed. nonisolated(unsafe): only the (serialized) install path and
/// the signal handler touch it.
nonisolated(unsafe) private var crashFD: Int32 = -1
/// Pre-allocated backtrace frame buffer — allocating inside a signal handler is not
/// async-signal-safe, so we reserve it up front.
nonisolated(unsafe) private let crashBacktrace = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
/// Pre-encoded marker bytes (building a String inside the handler would allocate).
nonisolated(unsafe) private var crashMarker: [UInt8] = []

/// The fatal-signal handler. Best-effort: writes a marker + symbolicated backtrace
/// to our log fd using only async-signal-safe-ish calls (`write`, `backtrace`,
/// `backtrace_symbols_fd`, `fsync`), then restores the default handler and re-raises
/// so the OS still produces its full `.ips` crash report. This is what turns "the
/// app vanished" into "the app vanished AND left a stack trace in mlxstudio.log".
private let mlxCrashSignalHandler: @convention(c) (Int32) -> Void = { sig in
    if crashFD >= 0 {
        crashMarker.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { _ = write(crashFD, base, buf.count) }
        }
        let frames = backtrace(crashBacktrace, 128)
        backtrace_symbols_fd(crashBacktrace, frames, crashFD)
        fsync(crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - Public logging API

/// Central logging for MLX Studio. Every message fans out to TWO sinks:
///  1. **Apple unified logging** (`os.Logger`) — live in Console.app / `log stream
///     --predicate 'subsystem == "<bundle id>"'`, with level + category filtering.
///  2. **A persistent file** at `PathResolver.logsDir/mlxstudio.log` — survives
///     crashes and relaunches, greppable, attachable to a bug report without
///     Console.app. Rotated to `.1` when it passes ~5 MB.
///
/// Plus `Log.install()` wires an uncaught-exception handler and fatal-signal
/// handlers so the NEXT crash (like the May-27 `EXC_BAD_ACCESS`) leaves a backtrace
/// in our own log, not only in the OS `.ips`.
///
/// Usage: `Log.info("server ready on \(port)", .server)`,
/// `Log.error("download failed", .net, error: err)`. Call from anywhere/any thread.
enum Log {

    enum Category: String, CaseIterable {
        case app, python, training, server, agent, inspect, dataset, model, ui, net, data
    }

    enum Level: String {
        case debug = "DEBUG", info = "INFO", notice = "NOTE", error = "ERROR", fault = "FAULT"
    }

    // MARK: os.Logger sink (cached per category)

    nonisolated(unsafe) private static var loggers: [String: Logger] = [:]
    private static let loggersLock = NSLock()
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.josh.mlxstudio.MLXStudio"

    private static func osLogger(_ c: Category) -> Logger {
        loggersLock.lock(); defer { loggersLock.unlock() }
        if let l = loggers[c.rawValue] { return l }
        let l = Logger(subsystem: subsystem, category: c.rawValue)
        loggers[c.rawValue] = l
        return l
    }

    // MARK: File sink

    nonisolated(unsafe) private static let file = LogFileSink()

    /// The on-disk log file (for the Settings viewer / Reveal-in-Finder).
    static var fileURL: URL { LogFileSink.url }

    // MARK: Install (call once, as early as possible)

    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        file.rotateIfNeeded()
        installCrashHandlers()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        write(.notice, .app, "──────── MLX Studio launch · v\(v) (\(b)) · \(os) ────────",
              fileID: #fileID, line: #line)
    }

    private static func installCrashHandlers() {
        let path = LogFileSink.url.path
        crashFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        crashMarker = Array("\n\n=== MLX Studio CRASHED (fatal signal) — backtrace follows ===\n".utf8)

        // Obj-C / NSException path: we can capture a rich reason + symbols here.
        NSSetUncaughtExceptionHandler { exc in
            let syms = exc.callStackSymbols.joined(separator: "\n")
            Log.fault("Uncaught exception \(exc.name.rawValue): \(exc.reason ?? "(no reason)")\n\(syms)", .app)
        }
        // Fatal POSIX signals (SIGSEGV etc.) → backtrace breadcrumb, then re-raise.
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, mlxCrashSignalHandler)
        }
    }

    // MARK: Level entry points

    static func debug(_ message: @autoclosure () -> String, _ c: Category = .app,
                      fileID: String = #fileID, line: Int = #line) {
        #if DEBUG
        write(.debug, c, message(), fileID: fileID, line: line)
        #endif
    }

    static func info(_ message: String, _ c: Category = .app,
                     fileID: String = #fileID, line: Int = #line) {
        write(.info, c, message, fileID: fileID, line: line)
    }

    static func notice(_ message: String, _ c: Category = .app,
                       fileID: String = #fileID, line: Int = #line) {
        write(.notice, c, message, fileID: fileID, line: line)
    }

    static func error(_ message: String, _ c: Category = .app, error: Error? = nil,
                      fileID: String = #fileID, line: Int = #line) {
        let full = error.map { "\(message) — \($0.localizedDescription)" } ?? message
        write(.error, c, full, fileID: fileID, line: line)
    }

    static func fault(_ message: String, _ c: Category = .app,
                      fileID: String = #fileID, line: Int = #line) {
        write(.fault, c, message, fileID: fileID, line: line)
    }

    // MARK: Core write — fans out to both sinks

    private static func write(_ level: Level, _ c: Category, _ message: String,
                              fileID: String, line: Int) {
        // os.Logger (Console.app). Privacy .public so OUR diagnostics aren't redacted.
        let logger = osLogger(c)
        let osMsg = "\(message) (\(shortFile(fileID)):\(line))"
        switch level {
        case .debug:  logger.debug("\(osMsg, privacy: .public)")
        case .info:   logger.info("\(osMsg, privacy: .public)")
        case .notice: logger.notice("\(osMsg, privacy: .public)")
        case .error:  logger.error("\(osMsg, privacy: .public)")
        case .fault:  logger.fault("\(osMsg, privacy: .public)")
        }
        // File sink: "2026-05-31T19:40:01.123 ERROR [server] message (File.swift:42)"
        let stamp = LogFileSink.timestamp()
        file.append("\(stamp) \(level.rawValue) [\(c.rawValue)] \(message) (\(shortFile(fileID)):\(line))")
    }

    private static func shortFile(_ fileID: String) -> String {
        // #fileID is "Module/Path/File.swift" — keep just the file name.
        (fileID as NSString).lastPathComponent
    }
}

// MARK: - File sink implementation

/// Thread-safe appending file writer with size-based rotation. All disk work runs
/// on a private serial queue, so `append` is safe to call from any thread.
private final class LogFileSink: @unchecked Sendable {
    static let url = PathResolver.logsDir.appendingPathComponent("mlxstudio.log")
    private static let rotatedURL = PathResolver.logsDir.appendingPathComponent("mlxstudio.log.1")
    private static let maxBytes = 5 * 1024 * 1024   // 5 MB before rotation

    private let queue = DispatchQueue(label: "com.mlxstudio.log.file", qos: .utility)
    private var handle: FileHandle?

    // ISO8601-ish timestamps, guarded (DateFormatter isn't thread-safe).
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let formatterLock = NSLock()

    static func timestamp() -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.string(from: Date())
    }

    func append(_ line: String) {
        queue.async { [self] in
            if handle == nil { open() }
            guard let h = handle, let data = (line + "\n").data(using: .utf8) else { return }
            try? h.write(contentsOf: data)
        }
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.url.path) {
            fm.createFile(atPath: Self.url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Self.url)
        try? handle?.seekToEnd()
    }

    /// Rotate the current log to `.1` if it's grown past the cap. Called once at
    /// install (synchronously on the queue) so a fresh launch starts a roll if the
    /// previous run left a huge file.
    func rotateIfNeeded() {
        queue.sync {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: Self.url.path),
                  let size = attrs[.size] as? Int, size > Self.maxBytes else { return }
            try? handle?.close(); handle = nil
            try? fm.removeItem(at: Self.rotatedURL)
            try? fm.moveItem(at: Self.url, to: Self.rotatedURL)
        }
    }

    /// Read the tail of the current log for the in-app viewer (last `maxBytes`).
    func tail(maxBytes: Int = 256 * 1024) -> String {
        queue.sync {
            try? handle?.synchronize()
            guard let data = try? Data(contentsOf: Self.url) else { return "" }
            if data.count <= maxBytes { return String(decoding: data, as: UTF8.self) }
            let slice = data.suffix(maxBytes)
            return "…(truncated)…\n" + String(decoding: slice, as: UTF8.self)
        }
    }
}

extension Log {
    /// Tail of the on-disk log, for the Settings viewer.
    static func tail(maxBytes: Int = 256 * 1024) -> String { file.tail(maxBytes: maxBytes) }
}
