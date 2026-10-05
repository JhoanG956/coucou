import Foundation

// Same cases as the tests in windows/src-tauri/src/github.rs and time.rs.

@main
enum GitHubActivityTests {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String, line: Int = #line) {
        precondition(condition, "line \(line): \(what)")
        passed += 1
    }

    static func main() {
        dates()
        githubURLs()
        upstreamFromConfig()
        worktreeGitDir()
        parsesAGraphQLAnswer()
        firstPollIsSilentThenChangesAreAnnounced()
        ciIsAnnouncedOnlyOnAWatchedTransition()
        print("GitHub activity: \(passed) checks passed")
    }

    static func dates() {
        check(RFC3339.utc(0) == "1970-01-01T00:00:00Z", "epoch")
        check(RFC3339.utc(1_790_000_000) == "2026-09-21T14:13:20Z", "utc")
        check(RFC3339.parse("2026-09-21T14:13:20Z") == 1_790_000_000, "Z")
        check(RFC3339.parse("2026-09-21T16:13:20+02:00") == 1_790_000_000, "offset")
        check(RFC3339.parse("2026-09-21T09:13:20.250-05:00") == 1_790_000_000, "fraction + negative offset")
        check(RFC3339.parse("2024-02-29T00:00:00Z").map(RFC3339.utc) == "2024-02-29T00:00:00Z", "leap day")
        check(RFC3339.parse("2026-10-01") == nil, "a date alone is not a time")
        check(RFC3339.parse("") == nil, "empty")
    }

    static func githubURLs() {
        func ok(_ u: String) -> String? { GitHubBranch.parseGitHubURL(u).map { "\($0.0)/\($0.1)" } }
        check(ok("https://github.com/Louis-CFM/coucou.git") == "Louis-CFM/coucou", "https .git")
        check(ok("https://github.com/Louis-CFM/coucou") == "Louis-CFM/coucou", "https")
        check(ok("https://me@github.com/a/b/") == "a/b", "user + trailing slash")
        check(ok("git@github.com:a/b.git") == "a/b", "scp-like")
        check(ok("ssh://git@github.com/a/b.git") == "a/b", "ssh")
        check(ok("https://gitlab.com/a/b.git") == nil, "not GitHub")
        check(ok("https://github.com/a") == nil, "no repo")
    }

    static func upstreamFromConfig() {
        let config = """
        [core]
        \tbare = false
        [remote "origin"]
        \turl = git@github.com:Louis-CFM/coucou.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "fork"]
        \turl = https://github.com/jhoan/coucou.git
        [branch "main"]
        \tremote = origin
        \tmerge = refs/heads/main
        [branch "local-name"]
        \tremote = fork
        \tmerge = refs/heads/remote-name
        """
        let main = GitHubBranch.resolveUpstream(config: config, local: "main")
        check(main == GitHubBranchRef(owner: "Louis-CFM", name: "coucou", branch: "main"), "main")
        let forked = GitHubBranch.resolveUpstream(config: config, local: "local-name")
        check(forked?.owner == "jhoan" && forked?.branch == "remote-name", "fork upstream")
        // Never pushed: same name on origin.
        let fresh = GitHubBranch.resolveUpstream(config: config, local: "feat/x")
        check(fresh?.owner == "Louis-CFM" && fresh?.branch == "feat/x", "never pushed")
        // No origin at all: whichever remote points at GitHub.
        let other = GitHubBranch.resolveUpstream(config: "[remote \"up\"]\n\turl = https://github.com/x/y\n", local: "dev")
        check(other == GitHubBranchRef(owner: "x", name: "y", branch: "dev"), "any GitHub remote")
        check(GitHubBranch.resolveUpstream(config: "[remote \"origin\"]\n\turl = https://gitlab.com/x/y\n", local: "dev") == nil,
              "no GitHub remote")
    }

    static func worktreeGitDir() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coucou-gh-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: root) }
        let mainGit = root.appendingPathComponent("repo/.git")
        let wtGit = mainGit.appendingPathComponent("worktrees/wt")
        let wt = root.appendingPathComponent("wt")
        try! fm.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try! fm.createDirectory(at: wt.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! "[remote \"origin\"]\n\turl = https://github.com/a/b.git\n"
            .write(to: mainGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try! "ref: refs/heads/fix/thing\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try! "../..\n".write(to: wtGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try! "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let got = GitHubBranch.of(cwd: wt.appendingPathComponent("sub"))
        check(got == GitHubBranchRef(owner: "a", name: "b", branch: "fix/thing"), "worktree")

        // The main checkout itself, and a detached HEAD.
        try! "ref: refs/heads/main\n".write(to: mainGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(GitHubBranch.of(cwd: root.appendingPathComponent("repo")) == GitHubBranchRef(owner: "a", name: "b", branch: "main"),
              "normal checkout")
        try! "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
            .write(to: mainGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(GitHubBranch.of(cwd: root.appendingPathComponent("repo")) == nil, "detached HEAD")
        check(GitHubBranch.of(cwd: URL(fileURLWithPath: "/")) == nil, "no repository")
    }

    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func parsesAGraphQLAnswer() {
        let recent = RFC3339.utc(RFC3339.now() - 3600)
        let data = json("""
        {
          "viewer": {
            "login": "me",
            "repositories": { "totalCount": 2, "nodes": [{ "stargazerCount": 3 }, { "stargazerCount": 4 }] },
            "pullRequests": { "nodes": [
              { "number": 8, "title": "Calendar", "url": "u8", "isDraft": false, "headRefName": "feat/cal",
                "reviewDecision": null, "updatedAt": "\(recent)",
                "repository": { "nameWithOwner": "Louis-CFM/coucou" },
                "latestReviews": { "nodes": [{ "id": "r1", "state": "COMMENTED", "author": { "login": "louis" } }] } },
              { "number": 2, "title": "[Snyk] Fix", "url": "u2", "isDraft": false, "headRefName": "snyk-fix-1",
                "reviewDecision": null, "updatedAt": "2025-12-14T14:33:19Z",
                "repository": { "nameWithOwner": "me/old" }, "latestReviews": { "nodes": [] } }
            ] }
          },
          "requests": { "issueCount": 1, "nodes": [
            { "number": 9, "title": "Docs", "url": "u9", "author": { "login": "x" }, "repository": { "nameWithOwner": "a/b" } },
            {}
          ] },
          "repository": {
            "nameWithOwner": "Louis-CFM/coucou",
            "ref": { "target": {
              "oid": "abc", "url": "commit-url", "committedDate": "\(recent)",
              "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": [
                { "__typename": "CheckRun", "name": "lint", "conclusion": "SUCCESS", "detailsUrl": "l" },
                { "__typename": "CheckRun", "name": "build", "conclusion": "FAILURE", "detailsUrl": "job-url" }
              ] } }
            } }
          }
        }
        """)
        let target = GitHubBranchRef(owner: "Louis-CFM", name: "coucou", branch: "feat/cal")
        let s = GitHubActivity.parse(data, target: target)
        check(s.login == "me" && s.totalRepos == 2 && s.totalStars == 7, "totals")
        // The ten-month-old bot PR is gone.
        check(s.pulls.map(\.number) == [8], "stale pull requests left out")
        check(s.pulls.first?.reviews.first == GitHubActivity.Review(id: "r1", state: "COMMENTED", author: "louis"), "reviews")
        check(s.requests.map(\.number) == [9] && s.requestCount == 1, "requests (non-PR nodes skipped)")
        let b = s.branch
        check(b?.state == "FAILURE" && b?.failing == ["build"] && b?.url == "job-url" && b?.pr == 8 && b?.pushed == true,
              "branch CI")

        // A branch GitHub doesn't know yet, and a repository the token can't see.
        let unpushed = GitHubActivity.parse(json(#"{"viewer": {}, "repository": {"nameWithOwner": "a/b", "ref": null}}"#),
                                            target: GitHubBranchRef(owner: "a", name: "b", branch: "new"))
        check(unpushed.branch?.pushed == false && unpushed.branch?.state == nil, "not pushed")
        let hidden = GitHubActivity.parse(json(#"{"viewer": {}, "repository": null}"#),
                                          target: GitHubBranchRef(owner: "a", name: "b", branch: "new"))
        check(hidden.branch == nil, "repository not visible")
        check(GitHubActivity.parse(data, target: nil).branch == nil, "no session branch")
    }

    static func snapshot(_ state: String?, reviews: [(String, String)], requests: [String]) -> GitHubActivity {
        var s = GitHubActivity()
        s.login = "me"
        s.branch = .init(repo: "a/b", branch: "fix", pushed: true, oid: "abc", state: state,
                         failing: state == "FAILURE" ? ["build"] : [], url: "", committedAt: "", pr: 7)
        s.pulls = [.init(repo: "a/b", number: 7, title: "Fix", url: "u7", draft: false, head: "fix", decision: nil,
                         reviews: reviews.map { .init(id: $0.0, state: $0.1, author: "louis") })]
        s.requests = requests.map { .init(repo: "a/b", number: 9, title: "T", url: $0, author: "x") }
        return s
    }

    static func firstPollIsSilentThenChangesAreAnnounced() {
        var m = GitHubMemory()
        // Already red when first seen, an existing review, an existing request.
        check(m.diff(snapshot("FAILURE", reviews: [("r1", "COMMENTED")], requests: ["p1"])) == nil, "first poll silent")
        // Same again: nothing new.
        check(m.diff(snapshot("FAILURE", reviews: [("r1", "COMMENTED")], requests: ["p1"])) == nil, "nothing new")

        // A new review request.
        let e = m.diff(snapshot("FAILURE", reviews: [("r1", "COMMENTED")], requests: ["p1", "p2"]))
        check(e?.attention == true && e?.label.hasPrefix("Review requested") == true, "review requested")

        // An approval.
        let a = m.diff(snapshot("FAILURE", reviews: [("r2", "APPROVED")], requests: ["p1", "p2"]))
        check(a?.success == true && a?.label == "Approved · #7", "approval")

        // Your own review says nothing.
        var mine = snapshot("FAILURE", reviews: [("r3", "COMMENTED")], requests: [])
        mine.pulls[0].reviews[0].author = "me"
        check(m.diff(mine) == nil, "own review")
    }

    static func ciIsAnnouncedOnlyOnAWatchedTransition() {
        var m = GitHubMemory()
        check(m.diff(snapshot("PENDING", reviews: [], requests: [])) == nil, "pending first")
        let e = m.diff(snapshot("FAILURE", reviews: [], requests: []))
        check(e?.success == false && e?.label == "CI failed · fix" && e?.detail == "build", "CI failed")
        // Still red on the next poll: already said.
        check(m.diff(snapshot("FAILURE", reviews: [], requests: [])) == nil, "said once")

        // A red build outranks an approval landing in the same poll.
        var m2 = GitHubMemory()
        _ = m2.diff(snapshot("PENDING", reviews: [], requests: []))
        let both = m2.diff(snapshot("FAILURE", reviews: [("r9", "APPROVED")], requests: []))
        check(both?.label.hasPrefix("CI failed") == true, "priority")

        // Green after pending.
        var m3 = GitHubMemory()
        _ = m3.diff(snapshot("PENDING", reviews: [], requests: []))
        check(m3.diff(snapshot("SUCCESS", reviews: [], requests: []))?.label == "CI passed · fix", "CI passed")
    }
}
