import Foundation
import Observation

/// One entry in the mdship console.
struct ConsoleEntry: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable { case running, succeeded, failed }

    let id = UUID()
    let date: Date
    let title: String
    /// Grows while the command runs.
    var output: String
    var state: State
    let document: URL?

    var succeeded: Bool { state == .succeeded }
}

/// Everything about talking to mdship: finding it, installing it, running its
/// server, and remembering what it said.
@MainActor
@Observable
final class MdshipService {

    static let shared = MdshipService()

    enum Status: Equatable {
        case unknown
        case locating
        case missing
        case ready(version: String, path: String)
    }

    enum ServiceError: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "mdship is not installed, or not on the login shell's PATH. Install it from the mdship menu, or set its path in Settings."
            case .failed(let message): message
            }
        }
    }

    private(set) var status: Status = .unknown
    private(set) var entries: [ConsoleEntry] = []
    /// Set while installing.
    private(set) var activity: String?

    @ObservationIgnored private var environment: [String: String] = [:]
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var client: MCPClient?
    @ObservationIgnored private var locating: Task<Bool, Never>?

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    // MARK: - Finding mdship

    /// Finds mdship, once; `force` looks again, as after installing or changing the path.
    @discardableResult
    func locate(force: Bool = false) async -> Bool {
        if !force {
            if isReady { return true }
            if let locating { return await locating.value }
        }
        let explicit = Preferences.shared.mdshipPath
        status = .locating
        let task = Task<Bool, Never> {
            let found = await Task.detached(priority: .userInitiated) { () -> (URL?, [String: String], String?) in
                let environment = ShellEnvironment.login
                guard let executable = MdshipEnvironment.locate(explicitPath: explicit, environment: environment) else {
                    return (nil, environment, nil)
                }
                return (executable, environment, MdshipEnvironment.version(of: executable, environment: environment))
            }.value
            self.environment = found.1
            if let executable = found.0 {
                if executable != self.executable {
                    self.client?.stop()
                    self.client = nil
                }
                self.executable = executable
                self.status = .ready(version: found.2 ?? "unknown version", path: executable.path)
                return true
            }
            self.executable = nil
            self.status = .missing
            return false
        }
        locating = task
        let result = await task.value
        locating = nil
        return result
    }

    // MARK: - Running commands

    /// Runs `command` on the file at `url` and returns what mdship printed.
    /// Throws when mdship reports a failure.
    func run(_ command: MdshipCommand, on url: URL, lines: ClosedRange<Int>?) async throws -> (output: String, problems: Bool) {
        guard await locate(), let executable else {
            log(command.title, ServiceError.notInstalled.localizedDescription, succeeded: false, document: url)
            throw ServiceError.notInstalled
        }
        let preferences = Preferences.shared
        let options = MdshipCommand.Options(backup: preferences.keepBackups, numberingStyle: preferences.numberingStyle,
                                            skipTitle: preferences.numberingSkipsTitle, reflowWidth: preferences.reflowWidth)
        let entry = begin(command.title, document: url)
        do {
            switch command.request(path: url.path, lines: lines, options: options) {
            case .tool(let name, let arguments):
                let result = try await callTool(name, arguments: arguments)
                let output = MdshipOutput.cleaned(result.text)
                if result.isError {
                    throw ServiceError.failed(output)
                }
                let problems = command.reportsProblems(output, status: 0)
                finish(entry, output: output, succeeded: !problems)
                return (output, problems)

            case .cli(let arguments):
                let environment = self.environment
                let result = await Task.detached(priority: .userInitiated) {
                    ProcessRunner.run(executable, arguments, environment: environment,
                                      directory: url.deletingLastPathComponent(), timeout: 300) { chunk in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { MdshipService.shared.append(entry, chunk) }
                        }
                    }
                }.value
                await Task.yield()
                let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.timedOut { throw ServiceError.failed("mdship \(arguments.first ?? "") did not finish in time") }
                let problems = command.reportsProblems(output, status: result.status)
                if result.status != 0 && !problems {
                    throw ServiceError.failed(output)
                }
                finish(entry, output: output, succeeded: !problems)
                return (output, problems)
            }
        } catch let error as ServiceError {
            finish(entry, output: error.localizedDescription, succeeded: false)
            throw error
        } catch {
            finish(entry, output: error.localizedDescription, succeeded: false)
            throw ServiceError.failed(error.localizedDescription)
        }
    }

    /// Calls a tool on the shared server, starting it if needed, and once more
    /// on a fresh server if the old one had died.
    private func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPClient.ToolResult {
        guard let executable else { throw ServiceError.notInstalled }
        if client == nil {
            client = MCPClient(executable: executable, environment: environment)
        }
        do {
            return try await client!.callTool(name, arguments: arguments)
        } catch MCPClient.ClientError.exited {
            client = MCPClient(executable: executable, environment: environment)
            return try await client!.callTool(name, arguments: arguments)
        }
    }

    func restartServer() {
        client?.stop()
        client = nil
        log("Restart mdship MCP Server", "The MCP server stopped; it starts again with the next command.", succeeded: true, document: nil)
    }

    func shutdown() {
        client?.stop()
        client = nil
    }

    // MARK: - Installing

    /// `pip install --upgrade mdship` in a login shell, so it lands where the
    /// user's Python is.
    func install() async {
        guard activity == nil else { return }
        activity = "Installing mdship…"
        defer { activity = nil }
        shutdown()
        let command = "python3 -m pip install --upgrade mdship && { command -v pyenv >/dev/null 2>&1 && pyenv rehash; true; }"
        // The entry appears at once and fills in as pip prints.
        let id = begin("python3 -m pip install --upgrade mdship", document: nil)
        append(id, "$ \(command)\n")
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        let unbuffered = environment
        let result = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(MdshipEnvironment.shell(), ["-l", "-i", "-c", command], environment: unbuffered, timeout: 900) { chunk in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { MdshipService.shared.append(id, chunk) }
                }
            }
        }.value
        // Let the last streamed chunks land before the entry is closed.
        await Task.yield()
        finish(id, succeeded: result.status == 0)
        await locate(force: true)
    }

    // MARK: - Console

    /// A finished entry.
    func log(_ title: String, _ output: String, succeeded: Bool, document: URL?) {
        let id = begin(title, document: document)
        finish(id, output: output, succeeded: succeeded)
    }

    /// Starts an entry that shows as running; output follows with `append`.
    func begin(_ title: String, document: URL?) -> UUID {
        let entry = ConsoleEntry(date: Date(), title: title, output: "", state: .running, document: document)
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        return entry.id
    }

    func append(_ id: UUID, _ text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].output += text
    }

    /// Marks an entry done; `output` replaces what was streamed, when given.
    func finish(_ id: UUID, output: String? = nil, succeeded: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let output { entries[index].output = output }
        if entries[index].output.isEmpty { entries[index].output = "(no output)" }
        entries[index].state = succeeded ? .succeeded : .failed
    }

    func clearConsole() {
        entries.removeAll()
    }
}
