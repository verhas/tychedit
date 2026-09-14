import Foundation

/// Runs a short-lived process to completion and collects what it printed.
enum ProcessRunner {

    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false

        var combined: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.hasSuffix("\n") ? "" : "\n")
        }
    }

    /// Blocking: call it off the main thread. `onOutput` receives what the
    /// process prints as it prints it, standard output and error alike -- for
    /// a console that shows a long `pip install` while it runs.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    directory: URL? = nil, timeout: TimeInterval,
                    onOutput: (@Sendable (String) -> Void)? = nil) -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Both pipes are drained while the process runs; a process that fills
        // a pipe nobody reads would block forever.
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                    return
                }
                collected.append(data, error: isError)
                onOutput?(String(decoding: data, as: UTF8.self))
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            for pipe in [stdout, stderr] { pipe.fileHandleForReading.readabilityHandler = nil }
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        // A child that outlives the process can hold the pipes open; do not wait for it forever.
        _ = group.wait(timeout: .now() + 5)
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: collected.out, as: UTF8.self),
                      stderr: String(decoding: collected.err, as: UTF8.self),
                      timedOut: timedOut)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        var out: Data { lock.withLock { outData } }
        var err: Data { lock.withLock { errData } }
        func append(_ data: Data, error: Bool) {
            lock.withLock {
                if error { errData.append(data) } else { outData.append(data) }
            }
        }
    }
}

/// The login shell's environment, read once and shared by mdship and git.
enum ShellEnvironment {
    /// Computed on first use -- a second or so, so never first touched on the
    /// main thread. `static let` makes the one-time initialisation thread-safe.
    static let login: [String: String] = MdshipEnvironment.loginShellEnvironment()

    static func executable(_ name: String, in environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let fallback = URL(fileURLWithPath: "/usr/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }
}

/// Finding mdship the way the user's terminal would.
///
/// An app started from Finder or the Dock does not inherit the PATH a terminal
/// has: pyenv shims, `~/.local/bin`, Homebrew and virtual environments are set up
/// by the login shell's startup files. So the environment is taken from a login
/// shell once, and mdship runs with that.
enum MdshipEnvironment {

    static func shell() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    }

    /// The environment of an interactive login shell, with this process's
    /// environment underneath. Blocking.
    static func loginShellEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let marker = "__TYCHEDIT_ENVIRONMENT__"
        // Interactive too, because pyenv and friends are usually set up in .zshrc,
        // which a non-interactive login shell does not read.
        let output = ProcessRunner.run(shell(), ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env; printf '\(marker)'"],
                                       timeout: 15)
        let parts = output.stdout.components(separatedBy: marker)
        if parts.count >= 3 {
            for line in parts[1].split(separator: "\n") {
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<equals])
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                environment[key] = String(line[line.index(after: equals)...])
            }
        }
        // Rich wraps output to the terminal width and colours it; neither helps
        // when the output is parsed for line numbers.
        environment["COLUMNS"] = "10000"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// The mdship executable: the configured path, or the first `mdship` on PATH.
    ///
    /// Blocking.
    static func locate(explicitPath: String, environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        if !explicitPath.isEmpty {
            let path = (explicitPath as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("mdship")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `mdship --version`, without the program name. Blocking.
    static func version(of executable: URL, environment: [String: String]) -> String? {
        let output = ProcessRunner.run(executable, ["--version"], environment: environment, timeout: 20)
        guard output.status == 0 else { return nil }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("mdship ") ? String(text.dropFirst(7)) : text
    }
}
