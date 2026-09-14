import Foundation

/// A long-running `mdship mcp` server, spoken to over stdio.
///
/// One server for the whole app, started on first use and kept running:
/// starting Python and importing mdship costs about a second, which is too
/// slow to pay on every command. MCP over stdio is JSON-RPC 2.0, one message
/// per line.
@MainActor
final class MCPClient {

    struct ToolResult: Sendable {
        let text: String
        let isError: Bool
    }

    enum ClientError: LocalizedError {
        case launch(String)
        case exited(String)
        case timeout(String)
        case protocolError(String)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .launch(let detail): "mdship could not be started: \(detail)"
            case .exited(let detail): "The mdship server stopped.\(detail.isEmpty ? "" : " \(detail)")"
            case .timeout(let method): "mdship did not answer in time (\(method))."
            case .protocolError(let detail): "Unexpected answer from mdship: \(detail)"
            case .rpc(let message): message
            }
        }
    }

    private let executable: URL
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var startTask: Task<Void, Error>?
    private var stderrTail = ""

    init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    var isRunning: Bool { process?.isRunning == true }

    func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval = 600) async throws -> ToolResult {
        try await start()
        let data = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.protocolError("tools/call result is not an object")
        }
        let content = object["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ToolResult(text: text, isError: object["isError"] as? Bool ?? false)
    }

    func start() async throws {
        if let startTask {
            return try await startTask.value
        }
        let task = Task { try await self.launch() }
        startTask = task
        do {
            try await task.value
        } catch {
            startTask = nil
            throw error
        }
    }

    /// Closes the server's input, which ends it, and makes sure it is gone.
    func stop() {
        try? input?.close()
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    // MARK: - Process

    private func launch() async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Pipe callbacks arrive on a background queue. DispatchQueue.main keeps
        // them in order, which a Task per chunk would not promise.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(data) } }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didExit(status: status) } }
        }

        do {
            try process.run()
        } catch {
            throw ClientError.launch(error.localizedDescription)
        }
        self.process = process
        self.input = stdin.fileHandleForWriting

        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Tychedit", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
        ], timeout: 60)
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Data {
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(body)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fail(id, with: ClientError.timeout(method))
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        try write(try JSONSerialization.data(withJSONObject: message))
    }

    private func write(_ body: Data) throws {
        guard let input, isRunning else { throw ClientError.exited(stderrTail) }
        do {
            try input.write(contentsOf: body + Data([10]))
        } catch {
            throw ClientError.exited(error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: ClientError.rpc(error["message"] as? String ?? "mdship reported an error"))
            } else {
                let result = object["result"] ?? [String: Any]()
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClientError.protocolError("unreadable result"))
                }
            }
        }
    }

    private func receiveError(_ data: Data) {
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 4000 { stderrTail = String(stderrTail.suffix(4000)) }
    }

    private func fail(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func didExit(status: Int32) {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        for continuation in pending.values {
            continuation.resume(throwing: ClientError.exited(detail))
        }
        pending.removeAll()
        process = nil
        input = nil
        startTask = nil
        buffer.removeAll()
    }
}
