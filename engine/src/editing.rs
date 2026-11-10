use crate::git::{self, error, Result};
use serde::Serialize;
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{io::AsyncWriteExt, process::Command};

pub fn select_hunk(diff: &str, index: usize) -> Result<String> {
    let mut header = String::new();
    let mut hunks: Vec<String> = Vec::new();
    for line in diff.split_inclusive('\n') {
        if line.starts_with("@@ ") {
            hunks.push(line.into());
        } else if let Some(hunk) = hunks.last_mut() {
            hunk.push_str(line);
        } else {
            header.push_str(line);
        }
    }
    let selected = hunks.get(index).ok_or_else(|| {
        error(
            "invalid_hunk",
            "El bloque cambió o no admite staging parcial. Actualiza las diferencias.",
        )
    })?;
    Ok(header + selected)
}
async fn apply(root: &Path, patch: &str, reverse: bool, check: bool) -> Result<()> {
    let mut command = Command::new("git");
    command
        .current_dir(root)
        .args(["--no-pager", "apply", "--cached"]);
    if reverse {
        command.arg("--reverse");
    }
    if check {
        command.arg("--check");
    }
    let mut child = command
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| error("git_unavailable", e.to_string()))?;
    if let Some(mut input) = child.stdin.take() {
        input
            .write_all(patch.as_bytes())
            .await
            .map_err(|e| error("git_failed", e.to_string()))?;
    }
    let output = tokio::time::timeout(Duration::from_secs(30), child.wait_with_output())
        .await
        .map_err(|_| error("timeout", "Git excedió el tiempo disponible."))?
        .map_err(|e| error("git_failed", e.to_string()))?;
    if !output.status.success() {
        return Err(error(
            "git_failed",
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ));
    }
    Ok(())
}
pub async fn stage_hunk(root: &Path, file: &str, staged: bool, index: usize) -> Result<()> {
    let diff = git::diff(root, file, staged).await?;
    let patch = select_hunk(&diff, index)?;
    apply(root, &patch, staged, true).await?;
    apply(root, &patch, staged, false).await
}
#[derive(Serialize)]
pub struct ConflictVersions {
    pub base: String,
    pub ours: String,
    pub theirs: String,
    pub working: String,
}
fn validate_path(path: &str) -> Result<()> {
    if path.is_empty()
        || Path::new(path).is_absolute()
        || Path::new(path)
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
    {
        return Err(error("invalid_path", "Ruta de archivo inválida."));
    }
    Ok(())
}
fn checked_path(root: &Path, path: &str) -> Result<std::path::PathBuf> {
    validate_path(path)?;
    let full = root
        .join(path)
        .canonicalize()
        .map_err(|e| error("invalid_path", e.to_string()))?;
    if !full.starts_with(root) || !full.is_file() {
        return Err(error(
            "invalid_path",
            "La resolución debe quedar dentro del repositorio.",
        ));
    }
    Ok(full)
}
async fn assert_conflict(root: &Path, file: &str) -> Result<()> {
    validate_path(file)?;
    let entries = git::git(root, &["ls-files", "--unmerged", "-z", "--", file]).await?;
    if entries.is_empty() {
        return Err(error(
            "stale_conflict",
            "El archivo ya no tiene un conflicto registrado en el índice.",
        ));
    }
    Ok(())
}
pub async fn conflict(root: &Path, file: &str) -> Result<ConflictVersions> {
    assert_conflict(root, file).await?;
    let full = checked_path(root, file)?;
    let mut versions = Vec::new();
    for stage in [1, 2, 3] {
        let spec = format!(":{stage}:{file}");
        versions.push(git::git(root, &["show", &spec]).await.unwrap_or_default());
    }
    let working = std::fs::read_to_string(full).map_err(|_| {
        error(
            "binary_conflict",
            "Este archivo requiere un resolvedor externo compatible con su formato.",
        )
    })?;
    Ok(ConflictVersions {
        base: versions.remove(0),
        ours: versions.remove(0),
        theirs: versions.remove(0),
        working,
    })
}
pub async fn resolve(root: &Path, file: &str, content: &str, expected: &str) -> Result<()> {
    assert_conflict(root, file).await?;
    let full = checked_path(root, file)?;
    if content.lines().any(|line| {
        line.starts_with("<<<<<<< ") || line.starts_with("=======") || line.starts_with(">>>>>>> ")
    }) {
        return Err(error(
            "conflict_markers",
            "Todavía hay marcadores de conflicto en el resultado.",
        ));
    }
    if std::fs::read_to_string(&full).map_err(|e| error("write_failed", e.to_string()))? != expected
    {
        return Err(error(
            "stale_conflict",
            "El archivo cambió mientras lo editabas. Vuelve a cargar la resolución.",
        ));
    }
    std::fs::write(full, content).map_err(|e| error("write_failed", e.to_string()))?;
    git::execute(root, git::Action::Stage, file, false).await?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    async fn repository() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        git::git(root, &["init", "-b", "develop"]).await.unwrap();
        git::git(root, &["config", "user.name", "Test"])
            .await
            .unwrap();
        git::git(root, &["config", "user.email", "test@example.invalid"])
            .await
            .unwrap();
        let text = (0..40).map(|n| format!("line {n}\n")).collect::<String>();
        std::fs::write(root.join("file.txt"), text).unwrap();
        git::execute(root, git::Action::Stage, "file.txt", false)
            .await
            .unwrap();
        git::execute(root, git::Action::Commit, "chore(test): base", false)
            .await
            .unwrap();
        temp
    }
    #[tokio::test]
    async fn stage_and_unstage_one_hunk_only() {
        let temp = repository().await;
        let root = temp.path();
        let text = std::fs::read_to_string(root.join("file.txt"))
            .unwrap()
            .replace("line 2\n", "change first\n")
            .replace("line 36\n", "change second\n");
        std::fs::write(root.join("file.txt"), text).unwrap();
        stage_hunk(root, "file.txt", false, 0).await.unwrap();
        let staged = git::diff(root, "file.txt", true).await.unwrap();
        assert!(staged.contains("+change first"));
        assert!(!staged.contains("+change second"));
        stage_hunk(root, "file.txt", true, 0).await.unwrap();
        assert!(git::diff(root, "file.txt", true).await.unwrap().is_empty());
        assert!(stage_hunk(root, "file.txt", false, 8).await.is_err());
    }
}
