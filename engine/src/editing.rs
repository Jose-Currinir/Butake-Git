use crate::git::{self, error, Result};
use serde::Serialize;
use std::path::Path;

fn stale_hunk() -> git::GitError {
    error(
        "invalid_hunk",
        "El bloque cambió o no admite staging parcial. Actualiza las diferencias.",
    )
}
/// Header plus the `index`-th hunk of a single-file patch, byte for byte (the patch may not be UTF-8).
/// `expected` is the hunk's `@@ … @@` line as the UI showed it: a different one means the file changed since.
pub fn select_hunk_bytes(
    diff: &[u8],
    index: usize,
    expected: Option<&str>,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut header = Vec::new();
    let mut hunks: Vec<Vec<u8>> = Vec::new();
    for line in diff.split_inclusive(|byte| *byte == b'\n') {
        if line.starts_with(b"@@ ") {
            hunks.push(line.to_vec());
        } else if let Some(hunk) = hunks.last_mut() {
            hunk.extend_from_slice(line);
        } else {
            header.extend_from_slice(line);
        }
    }
    let selected = hunks.into_iter().nth(index).ok_or_else(stale_hunk)?;
    if let Some(expected) = expected.map(str::trim).filter(|e| !e.is_empty()) {
        let first = selected.split(|byte| *byte == b'\n').next().unwrap_or(&[]);
        let first = String::from_utf8_lossy(first);
        // Compare the ranges only: the text after the second `@@` is context that display code may trim.
        let ranges = |line: &str| line.splitn(3, "@@").nth(1).map(|r| r.trim().to_string());
        if ranges(first.trim_end_matches('\r')) != ranges(expected) {
            return Err(stale_hunk());
        }
    }
    Ok((header, selected))
}
async fn apply(root: &Path, patch: &[u8], reverse: bool, check: bool) -> Result<()> {
    // --whitespace=nowarn: `apply.whitespace=fix` must not rewrite what the user chose to stage.
    let mut args = vec!["apply", "--cached", "--whitespace=nowarn", "-p1"];
    if reverse {
        args.push("--reverse");
    }
    if check {
        args.push("--check");
    }
    args.push("-");
    git::git_input(root, &args, patch).await.map(|_| ())
}
pub async fn stage_hunk(
    root: &Path,
    file: &str,
    staged: bool,
    index: usize,
    expected: Option<&str>,
) -> Result<()> {
    let diff = git::diff_bytes(root, file, staged).await?;
    let (mut header, hunk) = select_hunk_bytes(&diff, index, expected)?;
    if header.windows(13).any(|w| w == b"\nrename from ") {
        // A staged rename: reversing its header with one hunk would undo the whole move. The hunk is applied
        // as a plain edit of the new path instead, so only that block leaves the index.
        if file
            .chars()
            .any(|c| !c.is_ascii() || c.is_control() || c == '"' || c == '\\')
        {
            return Err(stale_hunk());
        }
        header = format!("diff --git a/{file} b/{file}\n--- a/{file}\n+++ b/{file}\n").into_bytes();
    }
    header.extend_from_slice(&hunk);
    apply(root, &header, staged, true).await?;
    apply(root, &header, staged, false).await
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
        // A side that does not exist (added on one branch only) reads as empty; other encodings are shown lossy.
        versions.push(
            git::git_lossy(root, &["show", &spec])
                .await
                .unwrap_or_default(),
        );
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
    if content.len() > 8_000_000 {
        return Err(error(
            "invalid_content",
            "El resultado es demasiado grande para guardarlo desde aquí.",
        ));
    }
    // A line of `=======` alone is legitimate content (Markdown/RST headings): only the opening and closing
    // markers prove an unresolved conflict.
    if content
        .lines()
        .any(|line| line.starts_with("<<<<<<< ") || line.starts_with(">>>>>>> "))
    {
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
        stage_hunk(root, "file.txt", false, 0, None).await.unwrap();
        let staged = git::diff(root, "file.txt", true).await.unwrap();
        assert!(staged.contains("+change first"));
        assert!(!staged.contains("+change second"));
        stage_hunk(root, "file.txt", true, 0, None).await.unwrap();
        assert!(git::diff(root, "file.txt", true).await.unwrap().is_empty());
        assert!(stage_hunk(root, "file.txt", false, 8, None).await.is_err());
    }

    #[tokio::test]
    async fn hunk_staging_survives_noprefix_other_encodings_and_checks_the_expected_block() {
        let temp = repository().await;
        let root = temp.path();
        git::git(root, &["config", "diff.noprefix", "true"])
            .await
            .unwrap();
        git::git(root, &["config", "apply.whitespace", "fix"])
            .await
            .unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        let base: Vec<u8> = (0..40)
            .flat_map(|n| {
                format!("l\u{ed}nea {n}\n")
                    .chars()
                    .map(|c| c as u8)
                    .collect::<Vec<_>>()
            })
            .collect();
        for file in ["src/a.txt", "a.txt"] {
            std::fs::write(root.join(file), &base).unwrap();
            git::git(root, &["add", file]).await.unwrap();
        }
        git::git(root, &["commit", "-qm", "latin"]).await.unwrap();
        let mut edited = b"primero   \n".to_vec();
        edited.extend_from_slice(&base);
        edited.extend_from_slice(b"ultimo\n");
        std::fs::write(root.join("src/a.txt"), &edited).unwrap();
        // A block that is not the one on screen is refused.
        assert_eq!(
            stage_hunk(root, "src/a.txt", false, 0, Some("@@ -9,9 +9,9 @@"))
                .await
                .unwrap_err()
                .code,
            "invalid_hunk"
        );
        let shown = git::diff(root, "src/a.txt", false).await.unwrap();
        let header = shown.lines().find(|l| l.starts_with("@@ ")).unwrap();
        stage_hunk(root, "src/a.txt", false, 0, Some(header))
            .await
            .unwrap();
        let files = git::status(root).await.unwrap();
        assert_eq!(files.len(), 1, "{files:?}");
        assert_eq!(files[0].path, "src/a.txt");
        assert_eq!(
            (files[0].index.as_str(), files[0].worktree.as_str()),
            ("M", "M")
        );
        // Trailing whitespace is staged as written, and the Latin-1 bytes are intact.
        let staged = std::process::Command::new("git")
            .current_dir(root)
            .args(["show", ":src/a.txt"])
            .output()
            .unwrap()
            .stdout;
        let mut expected = b"primero   \n".to_vec();
        expected.extend_from_slice(&base);
        assert_eq!(staged, expected);
    }
    #[tokio::test]
    async fn unstaging_one_hunk_of_a_staged_rename_keeps_the_rename() {
        let temp = repository().await;
        let root = temp.path();
        let text = std::fs::read_to_string(root.join("file.txt"))
            .unwrap()
            .replace("line 2\n", "change first\n")
            .replace("line 36\n", "change second\n");
        git::git(root, &["mv", "file.txt", "moved.txt"])
            .await
            .unwrap();
        std::fs::write(root.join("moved.txt"), text).unwrap();
        git::git(root, &["add", "moved.txt"]).await.unwrap();
        stage_hunk(root, "moved.txt", true, 0, None).await.unwrap();
        let files = git::status(root).await.unwrap();
        assert_eq!(files.len(), 1, "{files:?}");
        assert_eq!(files[0].index, "R");
        assert_eq!(files[0].original_path.as_deref(), Some("file.txt"));
        let staged = git::git(root, &["show", ":moved.txt"]).await.unwrap();
        assert!(staged.contains("line 2\n") && staged.contains("change second"));
    }
    #[tokio::test]
    async fn resolution_accepts_setext_headings_but_not_real_markers() {
        let temp = repository().await;
        let root = temp.path().canonicalize().unwrap();
        git::git(&root, &["switch", "-q", "-c", "other"])
            .await
            .unwrap();
        std::fs::write(root.join("file.txt"), "theirs\n").unwrap();
        git::git(&root, &["commit", "-qam", "theirs"])
            .await
            .unwrap();
        git::git(&root, &["switch", "-q", "develop"]).await.unwrap();
        std::fs::write(root.join("file.txt"), "ours\n").unwrap();
        git::git(&root, &["commit", "-qam", "ours"]).await.unwrap();
        assert!(git::git(&root, &["merge", "other"]).await.is_err());
        let loaded = conflict(&root, "file.txt").await.unwrap();
        assert_eq!(
            resolve(&root, "file.txt", "<<<<<<< ours\nx\n", &loaded.working)
                .await
                .unwrap_err()
                .code,
            "conflict_markers"
        );
        resolve(&root, "file.txt", "Title\n=======\nbody\n", &loaded.working)
            .await
            .unwrap();
        assert_eq!(git::status(&root).await.unwrap()[0].index, "M");
    }
}
