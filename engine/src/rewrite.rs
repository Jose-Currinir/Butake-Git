//! Guided history rewriting: reorder, squash, reword and drop *unpublished* commits without any editor.
//! Every rewrite stores a backup ref first so it can be undone with `reset --keep`.
use crate::git::{self, error, Result};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewriteCommit {
    pub hash: String,
    pub subject: String,
    pub message: String,
    pub author: String,
    pub timestamp: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewriteCandidates {
    pub branch: String,
    pub head: String,
    pub base: String,
    /// Oldest first.
    pub commits: Vec<RewriteCommit>,
    /// Why the list stops where it does: "upstream", "merge", "root" or "limit".
    pub boundary: String,
}

#[derive(Deserialize, Debug)]
pub struct RewriteStep {
    /// Oldest first; more than one hash squashes them into a single commit.
    pub hashes: Vec<String>,
    pub drop: bool,
    /// New full message (subject + body); `None` keeps the original.
    pub message: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct RewritePlan {
    pub head: String,
    pub base: String,
    pub steps: Vec<RewriteStep>,
}

#[derive(Serialize, Debug)]
pub struct RewriteResult {
    pub backup: String,
    pub head: String,
}

const LIMIT: usize = 60;

async fn current_branch(root: &Path) -> Result<String> {
    let branch = git::git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .map_err(|_| {
            error(
                "detached_head",
                "Cambia a una rama antes de organizar commits.",
            )
        })?;
    Ok(branch.trim().to_string())
}

/// Commits that can be rewritten safely: reachable from HEAD on the first-parent line, not yet in the
/// upstream (rewriting published commits would require force-push, which stays blocked).
pub async fn candidates(root: &Path) -> Result<RewriteCandidates> {
    let branch = current_branch(root).await?;
    let head = git::git(root, &["rev-parse", "--verify", "HEAD"])
        .await?
        .trim()
        .to_string();
    let upstream = git::git(root, &["rev-parse", "--verify", "--quiet", "@{upstream}"])
        .await
        .ok();
    let limit = format!("-{}", LIMIT + 1);
    let mut args = vec![
        "log",
        "--first-parent",
        &limit,
        "--format=%H%x1f%P%x1f%an%x1f%at%x1f%B%x1e",
        "HEAD",
    ];
    if upstream.is_some() {
        args.extend(["--not", "@{upstream}"]);
    }
    let raw = git::git(root, &args).await?;
    let mut commits = Vec::new();
    let mut boundary = if upstream.is_some() {
        "upstream"
    } else {
        "limit"
    }
    .to_string();
    for record in raw
        .split('\x1e')
        .map(|r| r.trim_start_matches('\n'))
        .filter(|r| !r.is_empty())
    {
        let f: Vec<_> = record.splitn(5, '\x1f').collect();
        if f.len() != 5 {
            continue;
        }
        let parents: Vec<_> = f[1].split_whitespace().collect();
        if parents.len() > 1 {
            boundary = "merge".into();
            break;
        }
        if parents.is_empty() {
            boundary = "root".into();
            break;
        }
        if commits.len() == LIMIT {
            boundary = "limit".into();
            break;
        }
        let message = f[4].trim_end().to_string();
        commits.push(RewriteCommit {
            hash: f[0].into(),
            subject: message.lines().next().unwrap_or("").to_string(),
            message,
            author: f[2].into(),
            timestamp: f[3].into(),
        });
    }
    let base = match commits.last() {
        Some(oldest) => git::git(root, &["rev-parse", &format!("{}^", oldest.hash)])
            .await?
            .trim()
            .to_string(),
        None => head.clone(),
    };
    commits.reverse();
    Ok(RewriteCandidates {
        branch,
        head,
        base,
        commits,
        boundary,
    })
}

/// Builds the rebase todo; messages go to files referenced by `exec git commit --amend -F`.
fn todo(plan: &RewritePlan, dir: &Path) -> Result<String> {
    let mut lines = Vec::new();
    for (index, step) in plan.steps.iter().enumerate() {
        if step.hashes.is_empty() {
            return Err(error("invalid_plan", "Paso vacío en el plan."));
        }
        if step.drop {
            lines.extend(step.hashes.iter().map(|h| format!("drop {h}")));
            continue;
        }
        lines.push(format!("pick {}", step.hashes[0]));
        lines.extend(step.hashes[1..].iter().map(|h| format!("fixup {h}")));
        if let Some(message) = &step.message {
            if message.trim().is_empty() {
                return Err(error("empty_message", "Un commit quedó sin mensaje."));
            }
            let path = dir.join(format!("message-{index}.txt"));
            std::fs::write(&path, format!("{}\n", message.trim_end()))
                .map_err(|e| error("plan_file", e.to_string()))?;
            let quoted = path.to_string_lossy().replace('\'', "'\\''");
            // --no-verify: hooks already ran for the original commits; only the message changes here.
            lines.push(format!(
                "exec git commit --amend --no-verify --allow-empty -F '{quoted}'"
            ));
        }
    }
    Ok(lines.join("\n") + "\n")
}

pub async fn apply(root: &Path, plan: &RewritePlan) -> Result<RewriteResult> {
    let state = git::snapshot(root).await?;
    if state.branch == state.primary_branch && state.main_protected {
        return Err(error(
            "protected_branch",
            "main está protegida en este repo.",
        ));
    }
    if !state.files.is_empty() || !state.operation.is_empty() {
        return Err(error(
            "dirty_rewrite",
            "Haz commit o guarda en stash tus cambios, y termina la operación en curso, antes de organizar commits.",
        ));
    }
    let current = candidates(root).await?;
    if current.head != plan.head || current.base != plan.base {
        return Err(error(
            "stale_plan",
            "El historial cambió. Vuelve a abrir «Organizar commits».",
        ));
    }
    let expected: HashSet<_> = current.commits.iter().map(|c| c.hash.as_str()).collect();
    let supplied: Vec<_> = plan
        .steps
        .iter()
        .flat_map(|s| s.hashes.iter().map(String::as_str))
        .collect();
    if supplied.len() != expected.len()
        || supplied.iter().copied().collect::<HashSet<_>>() != expected
    {
        return Err(error(
            "invalid_plan",
            "El plan debe contener cada commit exactamente una vez.",
        ));
    }
    if plan.steps.iter().all(|s| s.drop) {
        return Err(error("invalid_plan", "Debe quedar al menos un commit."));
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let backup = format!("refs/butake/backup/{}/{stamp}", current.branch);
    git::git(root, &["update-ref", &backup, &current.head]).await?;
    let dir = tempfile::tempdir().map_err(|e| error("plan_file", e.to_string()))?;
    let todo_path = dir.path().join("todo.txt");
    std::fs::write(&todo_path, todo(plan, dir.path())?)
        .map_err(|e| error("plan_file", e.to_string()))?;
    let editor = format!(
        "cp '{}'",
        todo_path.to_string_lossy().replace('\'', "'\\''")
    );
    let outcome = git::git_env(
        root,
        &[
            "rebase",
            "--interactive",
            "--keep-empty",
            "--no-autosquash",
            &plan.base,
        ],
        &[
            ("GIT_SEQUENCE_EDITOR", editor.as_str()),
            ("GIT_EDITOR", "true"),
        ],
    )
    .await;
    match outcome {
        Ok(_) => {
            let head = git::git(root, &["rev-parse", "HEAD"])
                .await?
                .trim()
                .to_string();
            Ok(RewriteResult { backup, head })
        }
        Err(failure) => {
            let conflicted =
                git::parse_status(&git::git(root, &["status", "--porcelain=v1", "-z"]).await?)
                    .iter()
                    .any(|f| f.index == "U" || f.worktree == "U");
            if conflicted {
                Err(error(
                    "rewrite_conflicts",
                    format!("Al reordenar, dos commits chocan. Resuelve el conflicto y pulsa «Continuar», o «Cancelar» para volver atrás. Respaldo: {backup}"),
                ))
            } else {
                let _ = git::git(root, &["rebase", "--abort"]).await;
                Err(failure)
            }
        }
    }
}

/// Restores the branch to a backup taken before a rewrite. `--keep` refuses to overwrite local changes.
pub async fn undo(root: &Path, backup: &str) -> Result<String> {
    let branch = current_branch(root).await?;
    if !backup.starts_with(&format!("refs/butake/backup/{branch}/")) || backup.contains("..") {
        return Err(error(
            "invalid_ref",
            "Respaldo inválido para la rama actual.",
        ));
    }
    git::git(root, &["rev-parse", "--verify", "--quiet", backup])
        .await
        .map_err(|_| error("invalid_ref", "El respaldo ya no existe."))?;
    git::git(root, &["reset", "--keep", backup]).await
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn repo() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        for args in [
            vec!["init", "-q", "-b", "develop"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "t@example.invalid"],
        ] {
            git::git(root, &args).await.unwrap();
        }
        for (file, message) in [
            ("base", "chore: base"),
            ("a", "feat: a"),
            ("b", "wip b"),
            ("c", "feat: c"),
            ("d", "feat: d"),
        ] {
            std::fs::write(root.join(file), format!("{file}\n")).unwrap();
            git::git(root, &["add", file]).await.unwrap();
            git::git(root, &["commit", "-qm", message]).await.unwrap();
        }
        temp
    }

    #[tokio::test]
    async fn squash_reword_reorder_drop_and_undo() {
        let temp = repo().await;
        let root = temp.path();
        let found = candidates(root).await.unwrap();
        assert_eq!(found.boundary, "root");
        let subjects: Vec<_> = found.commits.iter().map(|c| c.subject.as_str()).collect();
        assert_eq!(subjects, ["feat: a", "wip b", "feat: c", "feat: d"]);
        let h: Vec<String> = found.commits.iter().map(|c| c.hash.clone()).collect();
        let plan = RewritePlan {
            head: found.head.clone(),
            base: found.base.clone(),
            steps: vec![
                RewriteStep {
                    hashes: vec![h[0].clone(), h[1].clone()],
                    drop: false,
                    message: Some("feat: a y b\n\ndetalle".into()),
                },
                RewriteStep {
                    hashes: vec![h[3].clone()],
                    drop: false,
                    message: None,
                },
                RewriteStep {
                    hashes: vec![h[2].clone()],
                    drop: true,
                    message: None,
                },
            ],
        };
        let result = apply(root, &plan).await.unwrap();
        let log = git::git(root, &["log", "--format=%s", "-3"]).await.unwrap();
        assert_eq!(
            log.lines().collect::<Vec<_>>(),
            ["feat: d", "feat: a y b", "chore: base"]
        );
        assert!(!root.join("c").exists());
        assert!(root.join("b").exists());
        undo(root, &result.backup).await.unwrap();
        assert_eq!(
            git::git(root, &["rev-parse", "HEAD"]).await.unwrap().trim(),
            found.head
        );
        assert!(undo(root, "refs/heads/develop").await.is_err());
    }

    #[tokio::test]
    async fn rejects_stale_incomplete_and_dirty_plans() {
        let temp = repo().await;
        let root = temp.path();
        let found = candidates(root).await.unwrap();
        let one = RewritePlan {
            head: found.head.clone(),
            base: found.base.clone(),
            steps: vec![RewriteStep {
                hashes: vec![found.commits[0].hash.clone()],
                drop: false,
                message: None,
            }],
        };
        assert_eq!(apply(root, &one).await.unwrap_err().code, "invalid_plan");
        let stale = RewritePlan {
            head: "0".repeat(40),
            base: found.base.clone(),
            steps: vec![],
        };
        assert_eq!(apply(root, &stale).await.unwrap_err().code, "stale_plan");
        std::fs::write(root.join("dirty"), "x").unwrap();
        assert_eq!(apply(root, &one).await.unwrap_err().code, "dirty_rewrite");
    }
}
