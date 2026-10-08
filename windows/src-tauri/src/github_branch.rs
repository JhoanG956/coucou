// GitHub — CI for the branch you're on. Same rules as GitHubBranchCI.swift.
//
// "The branch you're on" is the branch checked out in the folder of the last
// Claude Code session, read straight from its .git directory: no `git` process,
// no console flash, and nothing to configure. Its CI comes back with the pulse
// (integrations.rs), as the `sessionBranch` part of the same GraphQL query, and
// lands in GitHubPulse::branch. GitHubPulse::events says when a run on it finishes.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::{json, Value};

use crate::github::{CiState, GitHubPr};

// ── The session's branch ──────────────────────────────────────────────────────

static SESSION_CWD: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Called for every Claude Code hook that carries a `cwd`.
pub fn note_cwd(cwd: &str) {
    if cwd.is_empty() {
        return;
    }
    *SESSION_CWD.lock().unwrap() = Some(PathBuf::from(cwd));
}

#[derive(Debug, Clone, PartialEq)]
pub struct BranchRef {
    pub owner: String,
    pub name: String,
    /// The branch's name on GitHub (its upstream), which is what CI ran on.
    pub branch: String,
}

/// The GitHub repository and branch checked out in `cwd`, if there is one.
fn branch_of(cwd: &Path) -> Option<BranchRef> {
    let (git_dir, common_dir) = find_git_dir(cwd)?;
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    // Detached HEAD (rebase, bisect, checkout of a tag): no branch to follow.
    let local = head.trim().strip_prefix("ref: refs/heads/")?.to_string();
    let config = std::fs::read_to_string(common_dir.join("config")).ok()?;
    resolve_upstream(&config, &local)
}

/// `.git` is a directory in a normal checkout and a `gitdir: …` file in a
/// worktree, whose config then lives in the main repository (`commondir`).
fn find_git_dir(start: &Path) -> Option<(PathBuf, PathBuf)> {
    for dir in start.ancestors() {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return Some((dot_git.clone(), dot_git));
        }
        if dot_git.is_file() {
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let target = text.trim().strip_prefix("gitdir:")?.trim();
            let git_dir = dir.join(target);
            let common = std::fs::read_to_string(git_dir.join("commondir"))
                .map(|c| git_dir.join(c.trim()))
                .unwrap_or_else(|_| git_dir.clone());
            return Some((git_dir, common));
        }
    }
    None
}

/// Follows `branch.<local>.remote` / `.merge` to the GitHub repo and remote
/// branch name; a branch with no upstream is assumed to be pushed to origin
/// under the same name.
fn resolve_upstream(config: &str, local: &str) -> Option<BranchRef> {
    let sections = parse_git_config(config);
    let get = |section: &str, sub: &str, key: &str| -> Option<String> {
        sections
            .iter()
            .find(|(s, n, k, _)| s == section && n == sub && k == key)
            .map(|(_, _, _, v)| v.clone())
    };

    let remote = get("branch", local, "remote").unwrap_or_else(|| "origin".into());
    let branch = get("branch", local, "merge")
        .and_then(|m| m.strip_prefix("refs/heads/").map(str::to_string))
        .unwrap_or_else(|| local.to_string());

    let url = get("remote", &remote, "url").or_else(|| {
        // No such remote: take whichever remote points at GitHub.
        sections
            .iter()
            .filter(|(s, _, k, _)| s == "remote" && k == "url")
            .map(|(_, _, _, v)| v.clone())
            .find(|v| parse_github_url(v).is_some())
    })?;
    let (owner, name) = parse_github_url(&url)?;
    Some(BranchRef { owner, name, branch })
}

/// (section, subsection, key, value) — just enough of git-config(1) for
/// `[remote "x"]` and `[branch "x"]`. Section and key names are case-insensitive.
fn parse_git_config(text: &str) -> Vec<(String, String, String, String)> {
    let mut out = Vec::new();
    let (mut section, mut sub) = (String::new(), String::new());
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(header) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            match header.split_once(char::is_whitespace) {
                Some((s, n)) => {
                    section = s.to_ascii_lowercase();
                    sub = n.trim().trim_matches('"').to_string();
                }
                None => {
                    section = header.to_ascii_lowercase();
                    sub.clear();
                }
            }
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let value = v.trim().trim_matches('"').to_string();
            out.push((section.clone(), sub.clone(), k.trim().to_ascii_lowercase(), value));
        }
    }
    out
}

/// `https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r.git` → (o, r). Anything not on github.com → None.
fn parse_github_url(url: &str) -> Option<(String, String)> {
    let at = url.find("github.com")?;
    let rest = &url[at + "github.com".len()..];
    let rest = rest.strip_prefix(':').or_else(|| rest.strip_prefix('/'))?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let (owner, name) = rest.split_once('/')?;
    if owner.is_empty() || name.is_empty() || name.contains('/') {
        return None;
    }
    Some((owner.to_string(), name.to_string()))
}

/// The repository and branch of the last Claude Code session, read now.
pub fn session_target() -> Option<BranchRef> {
    let cwd = SESSION_CWD.lock().unwrap().clone()?;
    branch_of(&cwd)
}

/// Variables for the pulse query: the `sessionBranch` part only runs when
/// there is a branch to follow.
pub fn query_variables(target: Option<&BranchRef>) -> Value {
    match target {
        Some(t) => json!({
            "owner": t.owner, "name": t.name,
            "ref": format!("refs/heads/{}", t.branch), "withBranch": true,
        }),
        None => json!({ "owner": "", "name": "", "ref": "", "withBranch": false }),
    }
}

// ── Its CI ────────────────────────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BranchCi {
    /// "owner/repo"
    pub repo: String,
    pub branch: String,
    /// False when GitHub doesn't know the branch yet (never pushed).
    pub pushed: bool,
    pub oid: String,
    pub ci: CiState,
    /// Names of the checks that failed.
    pub failing: Vec<String>,
    /// Straight to the failing job when there is one; the commit page (which
    /// lists every check) otherwise; "" when the branch isn't pushed.
    pub url: String,
    /// Your open pull request for this branch ("owner/repo#n"), if there is one.
    pub pr_id: Option<String>,
}

impl BranchCi {
    /// The `sessionBranch` node of the pulse answer. A repository the token
    /// can't see comes back null: no CI row then.
    pub fn parse(node: Option<&Value>, target: &BranchRef, my_prs: &[GitHubPr]) -> Option<Self> {
        let node = node?;
        let repo = node.get("nameWithOwner")?.as_str()?.to_string();
        let pr_id = my_prs
            .iter()
            .find(|p| p.head_ref.as_deref() == Some(target.branch.as_str()) && p.repo.eq_ignore_ascii_case(&repo))
            .map(|p| p.id.clone());

        let Some(commit) = node.get("ref").and_then(|r| r.get("target")).filter(|c| c.is_object()) else {
            return Some(BranchCi {
                repo,
                branch: target.branch.clone(),
                pushed: false,
                oid: String::new(),
                ci: CiState::Unknown,
                failing: Vec::new(),
                url: String::new(),
                pr_id,
            });
        };

        let rollup = commit.get("statusCheckRollup");
        let contexts = rollup
            .and_then(|r| r.get("contexts"))
            .and_then(|c| c.get("nodes"))
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let mut failing = Vec::new();
        let mut failing_url: Option<String> = None;
        for c in contexts {
            let (name, bad, url) = match c.get("__typename").and_then(Value::as_str) {
                Some("CheckRun") => (
                    s(c, "name"),
                    matches!(
                        c.get("conclusion").and_then(Value::as_str),
                        Some("FAILURE" | "TIMED_OUT" | "STARTUP_FAILURE" | "ACTION_REQUIRED")
                    ),
                    s(c, "detailsUrl"),
                ),
                Some("StatusContext") => (
                    s(c, "context"),
                    matches!(c.get("state").and_then(Value::as_str), Some("FAILURE" | "ERROR")),
                    s(c, "targetUrl"),
                ),
                _ => continue,
            };
            if bad {
                if failing_url.is_none() && !url.is_empty() {
                    failing_url = Some(url);
                }
                failing.push(name);
            }
        }

        Some(BranchCi {
            repo,
            branch: target.branch.clone(),
            pushed: true,
            oid: s(commit, "oid"),
            ci: CiState::from_github(rollup.and_then(|r| r.get("state")).and_then(Value::as_str)),
            failing,
            url: failing_url.unwrap_or_else(|| s(commit, "url")),
            pr_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_urls() {
        let ok = |u: &str| parse_github_url(u).map(|(o, n)| format!("{o}/{n}"));
        assert_eq!(ok("https://github.com/Louis-CFM/coucou.git").as_deref(), Some("Louis-CFM/coucou"));
        assert_eq!(ok("https://github.com/Louis-CFM/coucou").as_deref(), Some("Louis-CFM/coucou"));
        assert_eq!(ok("https://me@github.com/a/b/").as_deref(), Some("a/b"));
        assert_eq!(ok("git@github.com:a/b.git").as_deref(), Some("a/b"));
        assert_eq!(ok("ssh://git@github.com/a/b.git").as_deref(), Some("a/b"));
        assert_eq!(ok("https://gitlab.com/a/b.git"), None);
        assert_eq!(ok("https://github.com/a"), None);
    }

    #[test]
    fn upstream_from_config() {
        let config = r#"
[core]
	bare = false
[remote "origin"]
	url = git@github.com:Louis-CFM/coucou.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[remote "fork"]
	url = https://github.com/jhoan/coucou.git
[branch "main"]
	remote = origin
	merge = refs/heads/main
[branch "local-name"]
	remote = fork
	merge = refs/heads/remote-name
"#;
        let main = resolve_upstream(config, "main").unwrap();
        assert_eq!((main.owner.as_str(), main.name.as_str(), main.branch.as_str()), ("Louis-CFM", "coucou", "main"));
        let forked = resolve_upstream(config, "local-name").unwrap();
        assert_eq!((forked.owner.as_str(), forked.branch.as_str()), ("jhoan", "remote-name"));
        // Never pushed: same name on origin.
        let fresh = resolve_upstream(config, "feat/x").unwrap();
        assert_eq!((fresh.owner.as_str(), fresh.branch.as_str()), ("Louis-CFM", "feat/x"));
    }

    #[test]
    fn worktree_git_dir() {
        let root = std::env::temp_dir().join(format!("coucou-gh-{}", std::process::id()));
        let main_git = root.join("repo").join(".git");
        let wt_git = main_git.join("worktrees").join("wt");
        let wt = root.join("wt");
        std::fs::create_dir_all(&wt_git).unwrap();
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        std::fs::write(main_git.join("config"), "[remote \"origin\"]\n\turl = https://github.com/a/b.git\n").unwrap();
        std::fs::write(wt_git.join("HEAD"), "ref: refs/heads/fix/thing\n").unwrap();
        std::fs::write(wt_git.join("commondir"), "../..\n").unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", wt_git.display())).unwrap();

        let got = branch_of(&wt.join("sub")).unwrap();
        assert_eq!(got, BranchRef { owner: "a".into(), name: "b".into(), branch: "fix/thing".into() });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parses_the_session_branch() {
        let target = BranchRef { owner: "Louis-CFM".into(), name: "coucou".into(), branch: "feat/cal".into() };
        let node = json!({
            "nameWithOwner": "Louis-CFM/coucou",
            "ref": { "target": {
                "oid": "abc", "url": "commit-url",
                "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": [
                    { "__typename": "CheckRun", "name": "lint", "conclusion": "SUCCESS", "detailsUrl": "l" },
                    { "__typename": "CheckRun", "name": "build", "conclusion": "FAILURE", "detailsUrl": "job-url" },
                ] } },
            } },
        });
        let b = BranchCi::parse(Some(&node), &target, &[]).unwrap();
        assert_eq!((b.ci, b.failing.as_slice(), b.url.as_str(), b.pushed), (CiState::Failure, &["build".to_string()][..], "job-url", true));

        // Never pushed: a row that says so, no CI.
        let fresh = json!({ "nameWithOwner": "Louis-CFM/coucou", "ref": null });
        let b = BranchCi::parse(Some(&fresh), &target, &[]).unwrap();
        assert!(!b.pushed && b.ci == CiState::Unknown && b.url.is_empty());

        // A repository the token can't see comes back null.
        assert!(BranchCi::parse(Some(&Value::Null), &target, &[]).is_none());
    }
}
