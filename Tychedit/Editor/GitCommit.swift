import Foundation

/// Committing, and pushing, the one file being edited.
enum GitCommit {

    struct Failure: Error, Sendable {
        let message: String
    }

    /// Stages and commits only `url`, then pushes when asked. Blocking: call it
    /// off the main thread. Returns git's summary of the commit.
    static func commit(_ url: URL, message: String, push: Bool) throws -> String {
        let environment = ShellEnvironment.login
        guard let git = ShellEnvironment.executable("git", in: environment) else {
            throw Failure(message: "git was not found.")
        }
        let directory = url.deletingLastPathComponent().path
        let file = "./\(url.lastPathComponent)"

        func run(_ arguments: [String], timeout: TimeInterval = 30) -> ProcessRunner.Output {
            ProcessRunner.run(git, ["-C", directory] + arguments, environment: environment, timeout: timeout)
        }

        let added = run(["add", "--", file])
        guard added.status == 0 else { throw Failure(message: added.combined) }
        // `--` and a path commit that file alone, whatever else is staged.
        let committed = run(["commit", "-m", message, "--", file])
        guard committed.status == 0 else {
            throw Failure(message: committed.timedOut ? "git commit timed out." : committed.combined)
        }
        var summary = committed.stdout.split(separator: "\n").first.map(String.init) ?? "Committed"
        if push {
            let pushed = run(["push"], timeout: 120)
            guard pushed.status == 0 else {
                throw Failure(message: "Committed, but the push failed:\n" + (pushed.timedOut ? "git push timed out." : pushed.combined))
            }
            summary += " and pushed"
        }
        return summary
    }
}
