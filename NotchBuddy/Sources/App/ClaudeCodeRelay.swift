import Foundation

// MARK: - The Claude Code relay (GitHub build)
//
// With no Anthropic API key saved, the chat is answered by the user's own Claude
// Code (`claude -p`), signed in with their own account: their Claude plan, no key.
// Coucou reads no credential and makes no network call of its own; Claude Code
// answers exactly as it does in a terminal. Same design as the Windows and Linux
// relay (windows/src-tauri/src/claude_code.rs, #903).
//
// Each run is kept apart from the user's sessions: no settings file is loaded (so
// no hooks: Coucou's own would show the relay's runs as sessions), no MCP server,
// no skill or slash command, nothing saved to resume, and it runs in an empty
// folder of Coucou's, so no CLAUDE.md is picked up. It may only use the tools it
// is given: web search for the chat or, with no web at all, reading the one
// dropped file, copied alone into a folder of its own.
//
// The App Store build is sandboxed and can't start `claude`: there the chat still
// needs a key.

enum ClaudeCodeRelay {

    #if APPSTORE
    static var isAvailable: Bool { false }
    #else
    static var isAvailable: Bool { executable() != nil }
    #endif

    /// Where `claude` usually lives; the app doesn't get the shell's PATH.
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Request: Sendable {
        var model: String
        var system: String
        var prompt: String
        /// Built-in tools the run may use; none at all when empty.
        var tools: [String]
        /// A folder the run may read from, besides its own.
        var readDir: URL?
        var timeout: TimeInterval
    }

    enum Failure: LocalizedError {
        case notInstalled, timedOut, noAnswer, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code is not installed."
            case .timedOut: return "Claude Code took too long to answer."
            case .noAnswer: return "Claude Code gave no answer."
            case .failed(let why): return why
            }
        }
    }

    /// The command line of one run. Pure, so it can be tested.
    static func arguments(_ r: Request) -> [String] {
        var out = ["-p", "--output-format", "json", "--model", r.model, "--system-prompt", r.system,
                   "--tools", r.tools.joined(separator: ",")]
        if !r.tools.isEmpty { out += ["--allowedTools", r.tools.joined(separator: ",")] }
        if let dir = r.readDir { out += ["--add-dir", dir.path] }
        out += ["--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"]
        return out
    }

    /// The answer's text from `claude -p --output-format json`, or why there is none.
    static func parse(_ stdout: Data) -> Result<String, Failure> {
        guard let json = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else {
            return .failure(.noAnswer)
        }
        let result = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if json["is_error"] as? Bool == true {
            return .failure(.failed(result.isEmpty ? "Claude Code could not answer." : result))
        }
        return result.isEmpty ? .failure(.noAnswer) : .success(result)
    }

    /// One chat turn as a single prompt: the earlier turns, the context the first
    /// question carries, then the question.
    static func chatPrompt(history: [(user: String, assistant: String)], context: String?, query: String) -> String {
        var out = ""
        if !history.isEmpty {
            out += "The conversation so far:\n<conversation>\n"
            for turn in history {
                out += "<user>\n\(turn.user)\n</user>\n<assistant>\n\(turn.assistant)\n</assistant>\n"
            }
            out += "</conversation>\n\nThe user's new message:\n"
        }
        if let context { out += context + "\n\n" }
        return out + query
    }

    #if !APPSTORE
    /// Runs `claude -p` once and returns the text of its answer.
    static func ask(_ request: Request) async throws -> String {
        guard let exe = executable() else { throw Failure.notInstalled }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workdir = support.appendingPathComponent("NotchBuddy/relay", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

        let run = Run()
        run.process.executableURL = URL(fileURLWithPath: exe)
        run.process.arguments = arguments(request)
        run.process.currentDirectoryURL = workdir
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        // An npm install is a `#!/usr/bin/env node` script: its own folder and the
        // usual ones first on PATH so it finds its Node.
        let dir = (exe as NSString).deletingLastPathComponent
        env["PATH"] = ([dir, "/opt/homebrew/bin", "/usr/local/bin"] + [env["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
        run.process.environment = env
        run.process.standardInput = run.input
        run.process.standardOutput = run.output
        run.process.standardError = run.errors
        let prompt = Data(request.prompt.utf8)
        let timeout = request.timeout

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try run.process.run() } catch {
                    continuation.resume(throwing: Failure.failed("Could not start Claude Code: \(error.localizedDescription)"))
                    return
                }
                let timer = DispatchWorkItem { if run.process.isRunning { run.process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                run.input.fileHandleForWriting.write(prompt)
                try? run.input.fileHandleForWriting.close()
                // Read both pipes to the end before waiting, so a long answer can't fill one and stall.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { run.stderrData = run.errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let stdoutData = run.output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                run.process.waitUntilExit()
                timer.cancel()
                if run.process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure.timedOut)
                    return
                }
                switch parse(stdoutData) {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let failure):
                    let detail = String(decoding: run.stderrData, as: UTF8.self)
                        .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                    if detail.isEmpty { continuation.resume(throwing: failure) }
                    else { continuation.resume(throwing: Failure.failed("\(failure.localizedDescription) (\(detail))")) }
                }
            }
        }
    }

    /// One run's process and pipes, handed between the queues that drive it.
    private final class Run: @unchecked Sendable {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        var stderrData = Data()
    }

    /// A dropped file copied alone into a fresh folder, so the run can read that file and
    /// nothing else that was ever dropped. Removed by the caller once the run is over.
    static func isolate(_ file: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        return dir
    }
    #endif
}
