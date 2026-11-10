use crate::git::{self, error, Result};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::Write,
    path::{Component, Path, PathBuf},
};

async fn reference(root: &Path, name: &str) -> Result<String> {
    let reference = format!("refs/heads/{name}");
    git::git(root, &["check-ref-format", &reference]).await?;
    git::git(root, &["show-ref", "--verify", "--hash", &reference]).await?;
    Ok(reference)
}
pub async fn branch_details(root: &Path, name: &str, base: &str) -> Result<Value> {
    let branch = reference(root, name).await?;
    let base_ref = reference(root, base).await?;
    // Resolve once: every statistic and the comparison refer to the same snapshot.
    let head = git::git(root, &["rev-parse", &branch])
        .await?
        .trim()
        .to_string();
    let base_head = git::git(root, &["rev-parse", &base_ref])
        .await?
        .trim()
        .to_string();
    let counts = git::git(
        root,
        &[
            "rev-list",
            "--left-right",
            "--count",
            &format!("{base_head}...{head}"),
        ],
    )
    .await?;
    let counts: Vec<u64> = counts
        .split_whitespace()
        .filter_map(|s| s.parse().ok())
        .collect();
    let total = git::git(root, &["rev-list", "--count", &head])
        .await?
        .trim()
        .parse::<u64>()
        .unwrap_or(0);
    let merge_base = git::git(root, &["merge-base", &base_head, &head])
        .await
        .ok()
        .map(|s| s.trim().to_string());
    let mut authors = BTreeMap::<String, u64>::new();
    for name in git::git(
        root,
        &["log", "--format=%aN", &format!("{base_head}..{head}")],
    )
    .await?
    .lines()
    {
        *authors.entry(name.to_string()).or_default() += 1;
    }
    let authors: Vec<Value> = authors
        .into_iter()
        .map(|(name, count)| json!({"name":name,"count":count}))
        .collect();
    let log = git::git(
        root,
        &[
            "log",
            "--topo-order",
            "-100",
            "--format=%H%x1f%P%x1f%aN%x1f%at%x1f%s%x1f%D",
            &head,
            &base_head,
            "--",
        ],
    )
    .await?;
    let commits: Vec<Value> = log.lines().filter_map(|line| { let p: Vec<_> = line.split('\x1f').collect(); (p.len() == 6).then(|| json!({"hash":p[0],"parents":p[1].split_whitespace().collect::<Vec<_>>(),"author":p[2],"timestamp":p[3],"subject":p[4],"refs":p[5]})) }).collect();
    let upstream = git::git(
        root,
        &["for-each-ref", "--format=%(upstream:short)", &branch],
    )
    .await?
    .trim()
    .to_string();
    let tracking = if upstream.is_empty() {
        None
    } else {
        git::git(
            root,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{branch}...{branch}@{{upstream}}"),
            ],
        )
        .await
        .ok()
        .map(|s| {
            s.split_whitespace()
                .filter_map(|n| n.parse::<u64>().ok())
                .collect::<Vec<_>>()
        })
    };
    let reflog = git::git(
        root,
        &[
            "reflog",
            "show",
            "--date=unix",
            "--format=%gN%x1f%gs%x1f%gD",
            &branch,
        ],
    )
    .await
    .unwrap_or_default();
    let creation = reflog.lines().rev().find_map(|line| {
        let p: Vec<_> = line.split('\x1f').collect();
        if p.len() != 3 || !p[1].starts_with("branch: Created from ") {
            return None;
        }
        let timestamp = p[2]
            .rsplit_once("@{")?
            .1
            .trim_end_matches('}')
            .parse::<i64>()
            .ok()?;
        Some(json!({"actor":p[0],"timestamp":timestamp,"event":p[1]}))
    });
    let comparison = merge_base.as_ref().unwrap_or(&base_head);
    let numstat = git::git(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--numstat",
            "-z",
            comparison,
            &head,
            "--",
        ],
    )
    .await?;
    let files: Vec<Value> = numstat.split('\0').filter_map(|entry| { let mut p = entry.splitn(3,'\t'); let additions = p.next()?; let deletions = p.next()?; let path = p.next()?; Some(json!({"path":path,"additions":additions.parse::<u64>().ok(),"deletions":deletions.parse::<u64>().ok()})) }).collect();
    Ok(
        json!({"name":name,"base":base,"head":head,"baseHead":base_head,"mergeBase":merge_base,"total":total,"ahead":counts.get(1).copied().unwrap_or(0),"behind":counts.first().copied().unwrap_or(0),"upstream":upstream,"tracking":tracking,"creation":creation,"authors":authors,"commits":commits,"files":files}),
    )
}
pub async fn branch_diff(root: &Path, head: &str, base: &str, file: &str) -> Result<String> {
    for hash in [head, base] {
        if hash.len() != 40 && hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(error("invalid_ref", "Comparación inválida."));
        }
    }
    git::git(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-color",
            base,
            head,
            "--",
            file,
        ],
    )
    .await
}
fn file_path(root: &Path, file: &str) -> Result<PathBuf> {
    if file.is_empty() || Path::new(file).is_absolute() {
        return Err(error("invalid_path", "Ruta inválida."));
    }
    let mut path = root.to_path_buf();
    for component in Path::new(file).components() {
        match component {
            Component::Normal(name) if !name.eq_ignore_ascii_case(".git") => path.push(name),
            _ => return Err(error("invalid_path", "Ruta protegida o inválida.")),
        }
        if std::fs::symlink_metadata(&path)
            .map_err(|e| error("invalid_path", e.to_string()))?
            .file_type()
            .is_symlink()
        {
            return Err(error("invalid_path", "No se editan enlaces simbólicos."));
        }
    }
    if !path.is_file()
        || !path
            .canonicalize()
            .map_err(|e| error("invalid_path", e.to_string()))?
            .starts_with(root)
    {
        return Err(error("invalid_path", "Archivo fuera del repositorio."));
    }
    Ok(path)
}
async fn head(root: &Path) -> Result<String> {
    Ok(git::git(root, &["rev-parse", "--verify", "HEAD"])
        .await
        .unwrap_or_default()
        .trim()
        .to_string())
}
fn read(path: &Path) -> Result<String> {
    if std::fs::metadata(path)
        .map_err(|e| error("read_failed", e.to_string()))?
        .len()
        > 2_000_000
    {
        return Err(error(
            "large_file",
            "El editor admite archivos de hasta 2 MB.",
        ));
    }
    let text = std::fs::read_to_string(path).map_err(|_| {
        error(
            "binary_file",
            "Este archivo requiere un editor externo; se admite texto UTF-8.",
        )
    })?;
    if text.contains('\0') {
        return Err(error("binary_file", "El archivo contiene datos binarios."));
    }
    Ok(text)
}
async fn branch_name(root: &Path) -> Result<String> {
    Ok(
        git::git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
            .await
            .unwrap_or_default()
            .trim()
            .to_string(),
    )
}
pub async fn read_file(root: &Path, file: &str) -> Result<Value> {
    let revision = head(root).await?;
    let branch = branch_name(root).await?;
    let content = read(&file_path(root, file)?)?;
    if revision != head(root).await? || branch != branch_name(root).await? {
        return Err(error(
            "stale_file",
            "La rama cambió mientras se leía el archivo.",
        ));
    }
    Ok(json!({"content":content,"head":revision,"branch":branch}))
}
pub async fn save_file(
    root: &Path,
    file: &str,
    content: &str,
    expected: &str,
    expected_head: &str,
    expected_branch: &str,
) -> Result<()> {
    let branch = git::git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default();
    if branch.trim() == git::primary_branch(root).await && git::main_protected(root).await {
        return Err(error(
            "protected_main",
            "Cambia a una rama de trabajo antes de editar.",
        ));
    }
    if head(root).await? != expected_head || branch.trim() != expected_branch {
        return Err(error(
            "stale_file",
            "La rama o HEAD cambió. Recarga el archivo.",
        ));
    }
    if !git::git(root, &["ls-files", "--unmerged", "--", file])
        .await?
        .is_empty()
    {
        return Err(error(
            "conflict",
            "Usa el resolvedor de conflictos para este archivo.",
        ));
    }
    let path = file_path(root, file)?;
    if read(&path)? != expected {
        return Err(error(
            "stale_file",
            "El archivo cambió fuera del editor. Recarga antes de guardar.",
        ));
    }
    if content.len() > 2_000_000 || content.contains('\0') {
        return Err(error(
            "invalid_content",
            "Contenido no válido para el editor de texto.",
        ));
    }
    let permissions = std::fs::metadata(&path)
        .map_err(|e| error("write_failed", e.to_string()))?
        .permissions();
    let mut temporary = tempfile::NamedTempFile::new_in(path.parent().unwrap())
        .map_err(|e| error("write_failed", e.to_string()))?;
    temporary
        .write_all(content.as_bytes())
        .map_err(|e| error("write_failed", e.to_string()))?;
    temporary
        .as_file()
        .set_permissions(permissions)
        .map_err(|e| error("write_failed", e.to_string()))?;
    temporary
        .persist(path)
        .map_err(|e| error("write_failed", e.to_string()))?;
    Ok(())
}

pub async fn preview_file(expected: &str, content: &str) -> Result<String> {
    if expected.len() + content.len() > 4_000_000 {
        return Err(error(
            "large_file",
            "El editor admite archivos de hasta 2 MB.",
        ));
    }
    let temp = tempfile::tempdir().map_err(|e| error("preview_failed", e.to_string()))?;
    let original = temp.path().join("original");
    let edited = temp.path().join("edited");
    std::fs::write(&original, expected).map_err(|e| error("preview_failed", e.to_string()))?;
    std::fs::write(&edited, content).map_err(|e| error("preview_failed", e.to_string()))?;
    let output = tokio::process::Command::new("git")
        .args([
            "--no-pager",
            "diff",
            "--no-index",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--",
        ])
        .arg(original)
        .arg(edited)
        .kill_on_drop(true)
        .output()
        .await
        .map_err(|e| error("preview_failed", e.to_string()))?;
    if !matches!(output.status.code(), Some(0 | 1)) {
        return Err(error(
            "preview_failed",
            String::from_utf8_lossy(&output.stderr),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn repository() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        for args in [
            vec!["init", "-b", "develop"],
            vec!["config", "user.name", "Test Creator"],
            vec!["config", "user.email", "test@example.invalid"],
        ] {
            git::git(root, &args).await.unwrap();
        }
        std::fs::write(root.join("file.txt"), "base\n").unwrap();
        git::git(root, &["add", "file.txt"]).await.unwrap();
        git::git(root, &["commit", "-m", "base"]).await.unwrap();
        git::git(root, &["branch", "main"]).await.unwrap();
        temp
    }
    #[tokio::test]
    async fn branch_counts_creation_and_snapshot_diff_are_real() {
        let temp = repository().await;
        let root = temp.path();
        git::git(root, &["switch", "-c", "feature/stats"])
            .await
            .unwrap();
        std::fs::write(root.join("file.txt"), "base\nfeature\n").unwrap();
        git::git(root, &["commit", "-am", "feature"]).await.unwrap();
        git::git(root, &["switch", "main"]).await.unwrap();
        std::fs::write(root.join("other.txt"), "main\n").unwrap();
        git::git(root, &["add", "other.txt"]).await.unwrap();
        git::git(root, &["commit", "-m", "base moved"])
            .await
            .unwrap();
        let details = branch_details(root, "feature/stats", "main").await.unwrap();
        assert_eq!(details["total"], 2);
        assert_eq!(details["ahead"], 1);
        assert_eq!(details["behind"], 1);
        assert_eq!(details["creation"]["actor"], "Test Creator");
        assert!(details["creation"]["timestamp"].as_i64().unwrap() > 0);
        assert_eq!(details["authors"][0]["count"], 1);
        assert_eq!(details["files"].as_array().unwrap().len(), 1);
        assert_eq!(details["files"][0]["additions"], 1);
        let diff = branch_diff(
            root,
            details["head"].as_str().unwrap(),
            details["mergeBase"].as_str().unwrap(),
            "file.txt",
        )
        .await
        .unwrap();
        assert!(diff.contains("+feature"));
        git::git(
            root,
            &[
                "reflog",
                "expire",
                "--expire=all",
                "refs/heads/feature/stats",
            ],
        )
        .await
        .unwrap();
        assert!(branch_details(root, "feature/stats", "main").await.unwrap()["creation"].is_null());
        assert!(branch_details(root, "--all", "main").await.is_err());
        assert!(branch_diff(root, "--stat", "main", "file.txt")
            .await
            .is_err());
    }
    #[tokio::test]
    async fn editor_preserves_index_and_detects_external_change_and_branch_switch() {
        let temp = repository().await;
        let root = temp.path().canonicalize().unwrap();
        std::fs::write(root.join("file.txt"), "staged\n").unwrap();
        git::git(&root, &["add", "file.txt"]).await.unwrap();
        let loaded = read_file(&root, "file.txt").await.unwrap();
        let revision = loaded["head"].as_str().unwrap();
        save_file(
            &root, "file.txt", "edited\n", "staged\n", revision, "develop",
        )
        .await
        .unwrap();
        assert_eq!(
            git::git(&root, &["show", ":file.txt"]).await.unwrap(),
            "staged\n"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("file.txt")).unwrap(),
            "edited\n"
        );
        assert_eq!(
            save_file(
                &root,
                "file.txt",
                "overwrite\n",
                "staged\n",
                revision,
                "develop"
            )
            .await
            .unwrap_err()
            .code,
            "stale_file"
        );
        git::git(&root, &["switch", "-c", "same-head"])
            .await
            .unwrap();
        assert_eq!(
            save_file(
                &root,
                "file.txt",
                "overwrite\n",
                "edited\n",
                revision,
                "develop"
            )
            .await
            .unwrap_err()
            .code,
            "stale_file"
        );
        git::git(&root, &["switch", "main"]).await.unwrap();
        git::set_remote_protection(&root, "true").await.unwrap();
        assert_eq!(
            save_file(
                &root,
                "file.txt",
                "overwrite\n",
                "edited\n",
                revision,
                "main"
            )
            .await
            .unwrap_err()
            .code,
            "protected_main"
        );
    }
    #[tokio::test]
    async fn editor_rejects_metadata_symlinks_binary_and_previews_without_writes() {
        let temp = repository().await;
        let root = temp.path().canonicalize().unwrap();
        assert!(read_file(&root, ".git/config").await.is_err());
        assert!(read_file(&root, "../file.txt").await.is_err());
        std::os::unix::fs::symlink(root.join("file.txt"), root.join("link.txt")).unwrap();
        assert!(read_file(&root, "link.txt").await.is_err());
        std::fs::write(root.join("binary"), [0, 1, 2]).unwrap();
        assert!(read_file(&root, "binary").await.is_err());
        let diff = preview_file("base\n", "new\n").await.unwrap();
        assert!(diff.contains("-base"));
        assert!(diff.contains("+new"));
        assert_eq!(
            std::fs::read_to_string(root.join("file.txt")).unwrap(),
            "base\n"
        );
    }
}
