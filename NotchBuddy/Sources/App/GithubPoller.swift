import Foundation

// MARK: - GithubPoller
// CI of the branch of the last Claude Code session, the reviews asked of you, and
// your open pull requests — one GraphQL query per minute (GitHubActivity.swift has
// the rules). Every minute rather than every five: a CI run or a review is only
// worth hearing about while it is still news.

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var sessionCwd: String?
    private var memory = GitHubMemory()
    private var polling = false
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 60)  // every minute
        t.setEventHandler {
            Task { @MainActor in
                // A pill the user switched off makes no network calls at all.
                guard AppState.shared.activeIntegrations.contains("integration_github") else { return }
                DispatchQueue.global(qos: .background).async { GithubPoller.shared.poll() }
            }
        }
        t.resume()
        timer = t
    }

    /// Called for every Claude Code hook that carries a `cwd`: the card follows
    /// the branch of whichever session spoke last.
    func noteCwd(_ cwd: String) {
        guard !cwd.isEmpty else { return }
        lock.withLock { sessionCwd = cwd }
    }

    func pollNow() { DispatchQueue.global(qos: .userInitiated).async { self.poll() } }

    private func poll() {
        guard let token = KeychainStore.shared.get("github-token") else { return }
        guard lock.withLock({ () -> Bool in
            if polling { return false }
            polling = true
            return true
        }) else { return }

        let cwd = lock.withLock { sessionCwd }
        let target = cwd.flatMap { GitHubBranch.of(cwd: URL(fileURLWithPath: $0)) }

        guard let url = URL(string: "https://api.github.com/graphql"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "query": GitHubQuery.text,
                  "variables": GitHubQuery.variables(for: target),
              ]) else {
            lock.withLock { polling = false }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Coucou", forHTTPHeaderField: "User-Agent")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            defer { self.lock.withLock { self.polling = false } }
            // Offline: say nothing, try again next poll.
            guard let http = response as? HTTPURLResponse else { return }

            guard (200..<300).contains(http.statusCode) else {
                let message: String
                switch http.statusCode {
                case 401: message = "Invalid API key (401)"
                case 403: message = "Token lacks the needed scope"
                default:  message = "API error \(http.statusCode)"
                }
                DispatchQueue.main.async { AppState.shared.githubError = message }
                return
            }

            let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            guard let answer = json["data"] as? [String: Any] else {
                let message = (jsonValue((json["errors"] as? [Any])?.first, "message") as? String)
                    ?? "Unexpected answer from GitHub"
                appendAppLog("integrations.log", "github graphql: \(message)")
                DispatchQueue.main.async { AppState.shared.githubError = String(message.prefix(80)) }
                return
            }

            let activity = GitHubActivity.parse(answer, target: target)
            let news = self.lock.withLock { self.memory.diff(activity) }
            DispatchQueue.main.async {
                let state = AppState.shared
                state.githubError = nil
                state.githubActivity = activity
                if let news { state.announce(news, for: "integration_github") }
            }
        }.resume()
    }
}
