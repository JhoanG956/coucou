import Foundation

// GitHub — CI for the branch you're on, and the pull requests waiting on you
// or on someone else. Same rules as windows/src-tauri/src/github.rs.
//
// "The branch you're on" is the branch checked out in the folder of the last
// Claude Code session, read straight from its .git directory: no `git` process
// and nothing to configure. Everything else comes from one GraphQL query per poll
// (GithubPoller).
//
// Events, at most one per poll, only for things that changed since the last
// poll: a CI run on that branch finishing, a new review on one of your pull
// requests, a new review requested from you. The first poll only fills the card.

// MARK: - The session's branch

struct GitHubBranchRef: Equatable, Sendable {
    var owner: String
    var name: String
    /// The branch's name on GitHub (its upstream), which is what CI ran on.
    var branch: String
}

enum GitHubBranch {
    /// The GitHub repository and branch checked out in `cwd`, if there is one.
    static func of(cwd: URL) -> GitHubBranchRef? {
        guard let (gitDir, commonDir) = findGitDir(cwd),
              let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        // Detached HEAD (rebase, bisect, checkout of a tag): no branch to follow.
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        let local = String(trimmed.dropFirst("ref: refs/heads/".count))
        guard let config = try? String(contentsOf: commonDir.appendingPathComponent("config"), encoding: .utf8)
        else { return nil }
        return resolveUpstream(config: config, local: local)
    }

    /// `.git` is a directory in a normal checkout and a `gitdir: …` file in a
    /// worktree, whose config then lives in the main repository (`commondir`).
    static func findGitDir(_ start: URL) -> (URL, URL)? {
        let fm = FileManager.default
        var dir = start.standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return (dotGit, dotGit) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : dir.appendingPathComponent(target).standardizedFileURL
                var common = gitDir
                if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                    let rel = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    common = rel.hasPrefix("/")
                        ? URL(fileURLWithPath: rel)
                        : gitDir.appendingPathComponent(rel).standardizedFileURL
                }
                return (gitDir, common)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return nil }
            dir = parent
        }
    }

    /// Follows `branch.<local>.remote` / `.merge` to the GitHub repo and remote
    /// branch name; a branch with no upstream is assumed to be pushed to origin
    /// under the same name.
    static func resolveUpstream(config: String, local: String) -> GitHubBranchRef? {
        let entries = parseGitConfig(config)
        func get(_ section: String, _ sub: String, _ key: String) -> String? {
            entries.first { $0.section == section && $0.sub == sub && $0.key == key }?.value
        }

        let remote = get("branch", local, "remote") ?? "origin"
        var branch = local
        if let merge = get("branch", local, "merge"), merge.hasPrefix("refs/heads/") {
            branch = String(merge.dropFirst("refs/heads/".count))
        }

        // No such remote: take whichever remote points at GitHub.
        guard let url = get("remote", remote, "url")
                ?? entries.first(where: { $0.section == "remote" && $0.key == "url" && parseGitHubURL($0.value) != nil })?.value,
              let (owner, name) = parseGitHubURL(url) else { return nil }
        return GitHubBranchRef(owner: owner, name: name, branch: branch)
    }

    /// (section, subsection, key, value) — just enough of git-config(1) for
    /// `[remote "x"]` and `[branch "x"]`. Section and key names are case-insensitive.
    static func parseGitConfig(_ text: String) -> [(section: String, sub: String, key: String, value: String)] {
        var out: [(section: String, sub: String, key: String, value: String)] = []
        var section = "", sub = ""
        let quotes = CharacterSet(charactersIn: "\"")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                if let space = header.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    section = header[..<space].lowercased()
                    sub = header[header.index(after: space)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: quotes)
                } else {
                    section = header.lowercased()
                    sub = ""
                }
                continue
            }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: quotes)
                out.append((section, sub, key, value))
            }
        }
        return out
    }

    /// `https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
    /// `ssh://git@github.com/o/r.git` → (o, r). Anything not on github.com → nil.
    static func parseGitHubURL(_ url: String) -> (String, String)? {
        guard let at = url.range(of: "github.com") else { return nil }
        var rest = Substring(url[at.upperBound...])
        guard rest.hasPrefix(":") || rest.hasPrefix("/") else { return nil }
        rest = rest.dropFirst()
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let owner = String(rest[..<slash])
        let name = String(rest[rest.index(after: slash)...])
        guard !owner.isEmpty, !name.isEmpty, !name.contains("/") else { return nil }
        return (owner, name)
    }
}

// MARK: - The query

enum GitHubQuery {
    static let text = """
    query($owner: String!, $name: String!, $ref: String!, $withRepo: Boolean!) {
      viewer {
        login
        repositories(ownerAffiliations: OWNER, first: 100, orderBy: {field: PUSHED_AT, direction: DESC}) {
          totalCount
          nodes { stargazerCount }
        }
        pullRequests(states: OPEN, first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft headRefName reviewDecision updatedAt
            repository { nameWithOwner }
            latestReviews(first: 10) { nodes { id state author { login } } }
          }
        }
      }
      requests: search(query: "is:open is:pr user-review-requested:@me archived:false", type: ISSUE, first: 5) {
        issueCount
        nodes { ... on PullRequest { number title url author { login } repository { nameWithOwner } } }
      }
      repository(owner: $owner, name: $name) @include(if: $withRepo) {
        nameWithOwner
        ref(qualifiedName: $ref) {
          target {
            ... on Commit {
              oid url committedDate
              statusCheckRollup {
                state
                contexts(first: 50) {
                  nodes {
                    __typename
                    ... on CheckRun { name conclusion detailsUrl }
                    ... on StatusContext { context state targetUrl }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    static func variables(for target: GitHubBranchRef?) -> [String: Any] {
        guard let t = target else { return ["owner": "", "name": "", "ref": "", "withRepo": false] }
        return ["owner": t.owner, "name": t.name, "ref": "refs/heads/\(t.branch)", "withRepo": true]
    }
}

// MARK: - What the query says

struct GitHubActivity: Equatable, Sendable {
    /// Pull requests nobody has touched in a month are abandoned, not "on the go".
    static let staleAfterSecs = 30 * 86_400

    var login = ""
    var totalRepos = 0
    var totalStars = 0
    var branch: Branch?
    var pulls: [Pull] = []
    var requests: [Request] = []
    var requestCount = 0

    struct Branch: Equatable, Sendable {
        var repo: String
        var branch: String
        /// False when the branch only exists locally.
        var pushed: Bool
        var oid: String
        /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED — nil when no check ran.
        var state: String?
        var failing: [String]
        var url: String
        var committedAt: String
        var pr: Int?
    }

    struct Pull: Equatable, Sendable {
        var repo: String
        var number: Int
        var title: String
        var url: String
        var draft: Bool
        var head: String
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
        var decision: String?
        var reviews: [Review]
    }

    struct Review: Equatable, Sendable {
        var id: String
        var state: String
        var author: String
    }

    struct Request: Equatable, Sendable {
        var repo: String
        var number: Int
        var title: String
        var url: String
        var author: String
    }

    /// `data` is the GraphQL answer's `data` object.
    static func parse(_ data: [String: Any], target: GitHubBranchRef?, now: Int = RFC3339.now()) -> GitHubActivity {
        let viewer = data["viewer"]
        var out = GitHubActivity()
        out.login = jsonString(viewer, "login")

        let repos = jsonValue(viewer, "repositories")
        out.totalRepos = jsonInt(jsonValue(repos, "totalCount")) ?? 0
        out.totalStars = (jsonValue(repos, "nodes") as? [Any] ?? [])
            .compactMap { jsonInt(jsonValue($0, "stargazerCount")) }
            .reduce(0, +)

        // Pull requests nobody has touched in a month are abandoned, not "on
        // the go" — bots opening them under your name leave plenty of those.
        // A new review bumps updatedAt, so one coming back to life reappears.
        let freshSince = now - staleAfterSecs
        out.pulls = (jsonValue(viewer, "pullRequests", "nodes") as? [Any] ?? [])
            .filter { p in
                guard let t = RFC3339.parse(jsonString(p, "updatedAt")) else { return true }
                return t >= freshSince
            }
            .map { p in
                Pull(
                    repo: jsonString(p, "repository", "nameWithOwner"),
                    number: jsonInt(jsonValue(p, "number")) ?? 0,
                    title: jsonString(p, "title"),
                    url: jsonString(p, "url"),
                    draft: jsonBool(jsonValue(p, "isDraft")) ?? false,
                    head: jsonString(p, "headRefName"),
                    decision: jsonValue(p, "reviewDecision") as? String,
                    reviews: (jsonValue(p, "latestReviews", "nodes") as? [Any] ?? []).map { r in
                        Review(id: jsonString(r, "id"), state: jsonString(r, "state"),
                               author: jsonString(r, "author", "login"))
                    }
                )
            }

        out.requests = (jsonValue(data, "requests", "nodes") as? [Any] ?? [])
            .filter { jsonValue($0, "url") != nil }
            .map { n in
                Request(
                    repo: jsonString(n, "repository", "nameWithOwner"),
                    number: jsonInt(jsonValue(n, "number")) ?? 0,
                    title: jsonString(n, "title"),
                    url: jsonString(n, "url"),
                    author: jsonString(n, "author", "login")
                )
            }
        out.requestCount = jsonInt(jsonValue(data, "requests", "issueCount")) ?? 0

        // A repository the token can't see comes back null: no CI row then.
        if let t = target, let repo = jsonValue(data, "repository") {
            let nameWithOwner = jsonString(repo, "nameWithOwner")
            let pr = out.pulls.first {
                $0.head == t.branch && $0.repo.lowercased() == nameWithOwner.lowercased()
            }?.number
            if let commit = jsonValue(repo, "ref", "target") {
                let rollup = jsonValue(commit, "statusCheckRollup")
                var failing: [String] = []
                var failingURL: String?
                for c in jsonValue(rollup, "contexts", "nodes") as? [Any] ?? [] {
                    let name: String, bad: Bool, url: String
                    switch jsonString(c, "__typename") {
                    case "CheckRun":
                        name = jsonString(c, "name")
                        bad = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"]
                            .contains(jsonString(c, "conclusion"))
                        url = jsonString(c, "detailsUrl")
                    case "StatusContext":
                        name = jsonString(c, "context")
                        bad = ["FAILURE", "ERROR"].contains(jsonString(c, "state"))
                        url = jsonString(c, "targetUrl")
                    default:
                        continue
                    }
                    if bad {
                        if failingURL == nil, !url.isEmpty { failingURL = url }
                        failing.append(name)
                    }
                }
                out.branch = Branch(
                    repo: nameWithOwner, branch: t.branch, pushed: true,
                    oid: jsonString(commit, "oid"),
                    state: jsonValue(rollup, "state") as? String,
                    failing: failing,
                    // Straight to the failing job when there is one; the commit page
                    // (which lists every check) otherwise.
                    url: failingURL ?? jsonString(commit, "url"),
                    committedAt: jsonString(commit, "committedDate"),
                    pr: pr
                )
            } else {
                out.branch = Branch(repo: nameWithOwner, branch: t.branch, pushed: false, oid: "",
                                    state: nil, failing: [], url: "", committedAt: "", pr: pr)
            }
        }
        return out
    }
}

// MARK: - What changed since the last poll

struct GitHubMemory {
    /// (repo@branch@commit, rollup state) at the last poll.
    private var ci: (key: String, state: String?)?
    /// nil until the first poll, which fills these without announcing anything.
    private var reviews: Set<String>?
    private var requests: Set<String>?

    private static func isPending(_ state: String?) -> Bool {
        state == "PENDING" || state == "EXPECTED"
    }

    /// Remembers this snapshot and returns the one event worth announcing.
    mutating func diff(_ now: GitHubActivity) -> IntegrationNews? {
        // (priority, event): lower wins. A red build beats everything else.
        var candidates: [(Int, IntegrationNews)] = []

        // CI: only a run we watched go from pending to done. Switching to another
        // repo or branch, or a commit that was already finished when first seen,
        // says nothing — that's old news, not something that just happened.
        if let b = now.branch, b.pushed {
            let key = "\(b.repo)@\(b.branch)@\(b.oid)"
            if let prev = ci, prev.key == key, Self.isPending(prev.state) {
                switch b.state {
                case "SUCCESS":
                    candidates.append((5, IntegrationNews(success: true, label: "CI passed · \(b.branch)",
                                                          detail: b.repo)))
                case "FAILURE", "ERROR":
                    candidates.append((0, IntegrationNews(success: false, label: "CI failed · \(b.branch)",
                                                          detail: b.failing.isEmpty ? b.repo : b.failing.joined(separator: ", "))))
                default:
                    break
                }
            }
            ci = (key, b.state)
        }

        // Reviews on your pull requests, by anyone but you.
        var reviewIds = Set<String>()
        for p in now.pulls {
            for r in p.reviews {
                if r.author == now.login || r.id.isEmpty { continue }
                reviewIds.insert(r.id)
                guard let seen = reviews, !seen.contains(r.id) else { continue }
                let on = "\(r.author) on \(p.title)"
                switch r.state {
                case "CHANGES_REQUESTED":
                    candidates.append((1, IntegrationNews(success: false, label: "Changes requested · #\(p.number)", detail: on)))
                case "APPROVED":
                    candidates.append((4, IntegrationNews(success: true, label: "Approved · #\(p.number)", detail: on)))
                case "COMMENTED":
                    candidates.append((3, IntegrationNews(success: true, label: "New review · #\(p.number)", detail: on, attention: true)))
                default:
                    break
                }
            }
        }
        reviews = reviewIds

        // Reviews someone asked of you.
        let requestURLs = Set(now.requests.map(\.url))
        if let seen = requests {
            for r in now.requests where !seen.contains(r.url) {
                candidates.append((2, IntegrationNews(success: true, label: "Review requested · #\(r.number)",
                                                      detail: "\(r.author): \(r.title)", attention: true)))
            }
        }
        requests = requestURLs

        // The first of the most pressing ones, like a stable sort would give.
        var best: (Int, IntegrationNews)?
        for c in candidates where best == nil || c.0 < best!.0 { best = c }
        return best?.1
    }
}
