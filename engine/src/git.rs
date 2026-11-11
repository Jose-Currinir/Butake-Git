use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{process::Command, sync::Mutex};

#[derive(Default)]
pub struct GitState {
    pub opened: Mutex<HashSet<PathBuf>>,
    pub operation: Arc<Mutex<()>>,
    pub terminal: Arc<std::sync::Mutex<Option<crate::terminal::TerminalSession>>>,
}

#[derive(Debug, Serialize)]
pub struct GitError {
    pub code: String,
    pub detail: String,
}
pub(crate) type Result<T> = std::result::Result<T, GitError>;
pub(crate) fn error(code: &str, detail: impl Into<String>) -> GitError {
    GitError {
        code: code.into(),
        detail: detail.into(),
    }
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub original_path: Option<String>,
    pub index: String,
    pub worktree: String,
}
impl ChangedFile {
    /// Unmerged entry: any `U`, or both sides added (`AA`) or deleted (`DD`).
    pub fn conflicted(&self) -> bool {
        self.index == "U"
            || self.worktree == "U"
            || (self.index == "A" && self.worktree == "A")
            || (self.index == "D" && self.worktree == "D")
    }
}
#[derive(Serialize)]
pub struct Commit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub timestamp: String,
    pub subject: String,
    pub refs: String,
}
#[derive(Serialize)]
pub struct Branch {
    pub name: String,
    pub current: bool,
    pub upstream: String,
    /// Commits ahead/behind its upstream; `gone` when the upstream branch was deleted.
    pub ahead: u64,
    pub behind: u64,
    pub gone: bool,
    /// Last commit date (epoch UTC).
    pub updated: i64,
}
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct RemoteBranch {
    /// `origin/feature/x`
    pub name: String,
    pub remote: String,
    /// `feature/x`
    pub short: String,
    pub updated: i64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub root: String,
    pub branch: String,
    pub files: Vec<ChangedFile>,
    pub commits: Vec<Commit>,
    pub branches: Vec<Branch>,
    pub operation: String,
    pub ahead: u64,
    pub behind: u64,
    pub remote: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stats: Option<Vec<FileStat>>,
    pub main_protected: bool,
    /// "true", "false" or "" (automatic) as stored in `butake.protectMain`.
    pub main_protection: String,
    /// Last protection state read from the hosting provider ("true", "false" or empty when unknown).
    pub main_protection_remote: String,
    /// `main`, or `master` where the repository uses it.
    pub primary_branch: String,
    pub remote_branches: Vec<RemoteBranch>,
    /// Configured remotes (`origin`, …); empty for a repository that only exists locally.
    pub remotes: Vec<String>,
}
#[derive(Serialize, Debug)]
pub struct FileStat {
    pub path: String,
    pub staged: bool,
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Stage,
    Unstage,
    Commit,
    Fetch,
    Pull,
    Push,
    CreateBranch,
    SwitchBranch,
    Merge,
    Rebase,
    RebaseContinue,
    RebaseAbort,
    Stash,
    StashPop,
    Revert,
    CherryPick,
    Discard,
    PullMerge,
    PullRebase,
    PullAutostash,
    /// `origin/feature/x` → local `feature/x` tracking it.
    TrackBranch,
    DeleteBranch,
    ForceDeleteBranch,
    DeleteRemoteBranch,
    /// `old:new` (':' is not allowed in branch names).
    RenameBranch,
}

/// Runs a prepared Git command. Waits for the process itself, not for end-of-file on its pipes: a hook that
/// leaves a background process keeps them open, and waiting for EOF reported a timeout for work that finished.
/// Output is drained for a short grace period after the exit.
async fn run(
    mut command: Command,
    input: Option<Vec<u8>>,
    seconds: u64,
) -> Result<std::process::Output> {
    use std::process::Stdio;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|e| error("git_unavailable", e.to_string()))?;
    let writer = input.map(|payload| {
        let mut stdin = child.stdin.take().expect("piped stdin");
        tokio::spawn(async move {
            let _ = stdin.write_all(&payload).await;
        })
    });
    fn drain<R: tokio::io::AsyncRead + Unpin + Send + 'static>(
        mut pipe: R,
    ) -> (Arc<std::sync::Mutex<Vec<u8>>>, tokio::task::JoinHandle<()>) {
        let buffer = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = buffer.clone();
        let task = tokio::spawn(async move {
            let mut chunk = [0u8; 16_384];
            while let Ok(read) = pipe.read(&mut chunk).await {
                if read == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&chunk[..read]);
            }
        });
        (buffer, task)
    }
    let (stdout, stdout_task) = drain(child.stdout.take().expect("piped stdout"));
    let (stderr, stderr_task) = drain(child.stderr.take().expect("piped stderr"));
    let status = match tokio::time::timeout(Duration::from_secs(seconds), child.wait()).await {
        Ok(status) => status.map_err(|e| error("git_unavailable", e.to_string()))?,
        Err(_) => {
            let _ = child.start_kill();
            return Err(error(
                "timeout",
                format!("Git excedió {seconds} segundos. Verifica el acceso a la carpeta y actualiza antes de reintentar."),
            ));
        }
    };
    if let Some(writer) = writer {
        writer.abort();
    }
    for task in [stdout_task, stderr_task] {
        let abort = task.abort_handle();
        if tokio::time::timeout(Duration::from_millis(1_500), task)
            .await
            .is_err()
        {
            abort.abort();
        }
    }
    let stdout = std::mem::take(&mut *stdout.lock().unwrap());
    let stderr = std::mem::take(&mut *stderr.lock().unwrap());
    Ok(std::process::Output {
        status,
        stdout,
        stderr,
    })
}

/// Seconds a Git command may run: quick lookups, network transfers and commands that run hooks or check out
/// large trees (LFS) each get their own limit.
fn time_limit(args: &[&str]) -> u64 {
    match args.first().copied() {
        Some(
            "rev-parse" | "symbolic-ref" | "--version" | "--exec-path" | "--list-cmds=builtins",
        ) => 12,
        // Large repositories over slow links: network transfers get half an hour.
        Some("clone" | "push" | "pull" | "fetch") => 1_800,
        // Hooks (pre-commit, post-checkout…) and big checkouts can legitimately take minutes.
        Some(
            "commit" | "merge" | "rebase" | "cherry-pick" | "revert" | "switch" | "checkout"
            | "stash" | "reset" | "am",
        ) => 900,
        _ => 120,
    }
}

fn base_command(root: &Path, literal_pathspecs: bool) -> Command {
    let mut command = Command::new("git");
    command.current_dir(root).arg("--no-pager");
    if literal_pathspecs {
        command.arg("--literal-pathspecs");
    }
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        // Reads never take optional locks or rewrite the index: a GUI watching .git must not trigger itself.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C");
    command
}

fn failure_detail(output: &std::process::Output) -> String {
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if detail.is_empty() {
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    } else {
        detail
    }
}

async fn git_bytes(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let mut command = base_command(root, true);
    command
        .args(args)
        .env("GIT_EDITOR", "true")
        .env("GIT_PAGER", "cat");
    let output = run(command, None, time_limit(args)).await?;
    if !output.status.success() {
        return Err(error(
            "git_failed",
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }
    Ok(output.stdout)
}

pub async fn git(root: &Path, args: &[&str]) -> Result<String> {
    // Git paths with invalid UTF-8 are rejected instead of targeting another file by lossy conversion.
    String::from_utf8(git_bytes(root, args).await?).map_err(|_| {
        error(
            "unsupported_encoding",
            "Este repositorio contiene nombres que no son UTF-8.",
        )
    })
}

/// Like `git`, for file content shown to the user: bytes that are not UTF-8 (Latin-1 sources…) are replaced
/// instead of failing. Never use the result to address paths.
pub async fn git_lossy(root: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&git_bytes(root, args).await?).into_owned())
}

/// Runs a console command exactly as previewed: pathspecs keep their globs and magic, and the text Git
/// writes to stderr on success (push, fetch, switch…) is returned after stdout.
pub async fn git_console(root: &Path, args: &[&str]) -> Result<String> {
    let mut command = base_command(root, false);
    command
        .args(args)
        .env("GIT_EDITOR", "true")
        .env("GIT_PAGER", "cat");
    let output = run(command, None, time_limit(args)).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    let extra = String::from_utf8_lossy(&output.stderr);
    if !extra.trim().is_empty() {
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(&extra);
    }
    Ok(text)
}

/// Runs Git with extra environment variables (e.g. a non-interactive sequence editor).
pub async fn git_env(root: &Path, args: &[&str], env: &[(&str, &str)]) -> Result<String> {
    let mut command = base_command(root, true);
    command.args(args);
    for (key, value) in env {
        command.env(key, value);
    }
    let output = run(command, None, time_limit(args).max(300)).await?;
    if !output.status.success() {
        return Err(error("git_failed", failure_detail(&output)));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Runs Git feeding `input` on stdin (used for NUL-separated pathspecs, avoiding argv limits).
pub async fn git_input(root: &Path, args: &[&str], input: &[u8]) -> Result<String> {
    let mut command = base_command(root, true);
    command.args(args).env("GIT_EDITOR", "true");
    let output = run(command, Some(input.to_vec()), 120).await?;
    if !output.status.success() {
        return Err(error(
            "git_failed",
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Added/removed lines for unstaged and staged changes, from two concurrent numstat calls.
pub async fn line_stats(root: &Path) -> Vec<FileStat> {
    // Staged side detects renames (-M) so a moved file keeps its counts under the new path.
    let worktree_args = [
        "diff",
        "--numstat",
        "-z",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
    ];
    let index_args = [
        "diff",
        "--numstat",
        "-z",
        "-M",
        "--no-ext-diff",
        "--no-textconv",
        "--cached",
    ];
    let untracked_args = ["ls-files", "--others", "--exclude-standard", "-z"];
    let (worktree, index, untracked) = tokio::join!(
        git(root, &worktree_args),
        git(root, &index_args),
        git(root, &untracked_args)
    );
    let mut stats = parse_numstat_z(&worktree.unwrap_or_default(), false);
    stats.extend(parse_numstat_z(&index.unwrap_or_default(), true));
    // Untracked files have no diff: count their lines directly (bounded size; binary stays unknown).
    for path in untracked
        .unwrap_or_default()
        .split('\0')
        .filter(|p| !p.is_empty())
    {
        let lines = std::fs::metadata(root.join(path))
            .ok()
            .filter(|m| m.is_file() && m.len() <= 2_000_000)
            .and_then(|_| std::fs::read(root.join(path)).ok())
            .filter(|bytes| !bytes.contains(&0))
            .map(|bytes| {
                let newlines = bytes.iter().filter(|b| **b == b'\n').count() as u64;
                newlines + u64::from(!bytes.is_empty() && bytes.last() != Some(&b'\n'))
            });
        stats.push(FileStat {
            path: path.to_string(),
            staged: false,
            additions: lines,
            deletions: lines.map(|_| 0),
        });
    }
    stats
}

/// Parses `git diff --numstat -z`; with renames an entry is `added\tdeleted\t\0old\0new\0`.
pub fn parse_numstat_z(raw: &str, staged: bool) -> Vec<FileStat> {
    let mut stats = Vec::new();
    let mut tokens = raw.split('\0');
    while let Some(entry) = tokens.next() {
        if entry.is_empty() {
            continue;
        }
        let mut fields = entry.splitn(3, '\t');
        let (Some(added), Some(deleted), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let path = if path.is_empty() {
            let _old = tokens.next();
            tokens.next().unwrap_or_default().to_string()
        } else {
            path.trim_matches('\n').to_string()
        };
        stats.push(FileStat {
            path,
            staged,
            additions: added.parse().ok(),
            deletions: deleted.parse().ok(),
        });
    }
    stats
}

/// Stages or unstages many paths with a single Git process; every path must be a current change.
pub async fn stage_paths(root: &Path, paths: &[String], unstage: bool) -> Result<usize> {
    if paths.is_empty() {
        return Ok(0);
    }
    for path in paths {
        validate_path(path)?;
    }
    let status = parse_status(
        &git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        )
        .await?,
    );
    let changes: std::collections::HashMap<&str, &ChangedFile> =
        status.iter().map(|f| (f.path.as_str(), f)).collect();
    let mut spec = Vec::new();
    for path in paths {
        let file = changes.get(path.as_str()).ok_or_else(|| {
            error(
                "stale_file",
                format!("{path} ya no figura entre los cambios."),
            )
        })?;
        for item in std::iter::once(&file.path).chain(file.original_path.iter()) {
            spec.extend_from_slice(item.as_bytes());
            spec.push(0);
        }
    }
    let has_head = git(root, &["rev-parse", "--verify", "HEAD"]).await.is_ok();
    let args: &[&str] = match (unstage, has_head) {
        (false, _) => &["add", "--pathspec-from-file=-", "--pathspec-file-nul", "--"],
        (true, true) => &[
            "restore",
            "--staged",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
        ],
        // No commits yet: `-f` lets a file edited after `git add` leave the index (the working tree is untouched).
        (true, false) => &[
            "rm",
            "--cached",
            "-f",
            "--quiet",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
        ],
    };
    git_input(root, args, &spec).await?;
    Ok(paths.len())
}

/// Only network transports a user would paste: https, ssh and scp-like `git@host:path`.
/// Rejects `ext::`, `file://`, option-like values and anything with spaces or control characters.
pub fn validate_clone_url(url: &str) -> Result<()> {
    let ok_chars = !url.is_empty()
        && url.len() < 2_048
        && !url.starts_with('-')
        && !url.chars().any(|c| c.is_whitespace() || c.is_control());
    let scheme_ok = url.starts_with("https://")
        || url.starts_with("ssh://")
        || (url.starts_with("git@") && url.contains(':') && !url.contains("::"));
    if ok_chars && scheme_ok && !url.contains("::") {
        Ok(())
    } else {
        Err(error(
            "invalid_url",
            "Usa una dirección https://, ssh:// o git@servidor:ruta del repositorio.",
        ))
    }
}

/// Folder name proposed for a clone URL ("…/one.git" → "one").
pub fn clone_folder_name(url: &str) -> String {
    let tail = url
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("repositorio");
    tail.trim_end_matches(".git").to_string()
}

/// Clones into `parent/name`; the folder must not exist yet. Returns the new repository path.
pub async fn clone(parent: &Path, url: &str, name: &str) -> Result<String> {
    validate_clone_url(url)?;
    if name.is_empty()
        || name.starts_with('-')
        || name.starts_with('.')
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(|c| c.is_control())
    {
        return Err(error("invalid_path", "Nombre de carpeta inválido."));
    }
    let target = parent.join(name);
    if target.exists() {
        return Err(error(
            "path_exists",
            format!("Ya existe una carpeta llamada {name} en ese lugar."),
        ));
    }
    let destination = target.to_string_lossy().to_string();
    git(parent, &["clone", "--", url, &destination]).await.map_err(|failure| {
        // The folder did not exist before: remove whatever a failed or interrupted clone left behind,
        // so retrying does not stop at "already exists".
        let _ = std::fs::remove_dir_all(&target);
        let detail = failure.detail.to_lowercase();
        if detail.contains("authentication") || detail.contains("permission denied") || detail.contains("could not read username") {
            error(
                "clone_auth",
                "El servidor pidió credenciales. Configura tu llave SSH o el gestor de credenciales de Git y vuelve a intentar.",
            )
        } else if detail.contains("not found") || detail.contains("does not exist") {
            error("clone_not_found", "No se encontró el repositorio o no tienes acceso.")
        } else {
            failure
        }
    })?;
    Ok(destination)
}

fn validate_folder_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 200
        || name.starts_with('-')
        || name.starts_with('.')
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(|c| c.is_control())
    {
        return Err(error("invalid_path", "Nombre de carpeta inválido."));
    }
    Ok(())
}

/// Default ignores for a new repository on macOS (no project files are committed automatically).
const NEW_REPOSITORY_GITIGNORE: &str = "# macOS\n.DS_Store\n\n# Entornos y secretos\n.env\n.env.*\n!.env.example\n\n# Dependencias y compilación\nnode_modules/\nvendor/\ndist/\nbuild/\ntarget/\n";

/// Creates `parent/name` (or uses it when it exists without a repository) with `main`, a `.gitignore`
/// as the only file of the first commit, and optionally `develop` checked out. Returns the path.
pub async fn init_repository(parent: &Path, name: &str, with_develop: bool) -> Result<String> {
    validate_folder_name(name)?;
    let target = parent.join(name);
    if target.join(".git").exists() {
        return Err(error(
            "path_exists",
            format!("{name} ya es un repositorio Git: ábrelo."),
        ));
    }
    if target.exists() && !target.is_dir() {
        return Err(error(
            "path_exists",
            format!("Ya existe un archivo llamado {name}."),
        ));
    }
    std::fs::create_dir_all(&target).map_err(|e| error("invalid_path", e.to_string()))?;
    git(&target, &["init", "-b", "main"]).await?;
    let ignore = target.join(".gitignore");
    if !ignore.exists() {
        std::fs::write(&ignore, NEW_REPOSITORY_GITIGNORE)
            .map_err(|e| error("invalid_path", e.to_string()))?;
    }
    git(&target, &["add", "--", ".gitignore"]).await?;
    git(&target, &["commit", "-m", "chore: inicia el repositorio"]).await.map_err(|failure| {
        if failure.detail.contains("user.email") || failure.detail.contains("Please tell me who you are") {
            error(
                "git_identity",
                "Git no sabe tu nombre ni correo. Configúralos con git config --global user.name y user.email, y vuelve a intentar.",
            )
        } else {
            failure
        }
    })?;
    if with_develop {
        git(&target, &["switch", "-q", "-c", "develop"]).await?;
    }
    Ok(target.to_string_lossy().to_string())
}

/// Adds `origin` (or reuses it when it already points to `url`) and pushes each existing local branch
/// to the same name with upstream tracking. Never forces.
/// `replace_origin`: the app checked that the existing origin is the same repository (e.g. SSH → HTTPS).
pub async fn publish(
    root: &Path,
    url: &str,
    branches: &[String],
    replace_origin: bool,
) -> Result<Vec<String>> {
    validate_clone_url(url)?;
    let current = git(root, &["remote", "get-url", "origin"])
        .await
        .unwrap_or_default();
    if current.trim().is_empty() {
        git(root, &["remote", "add", "origin", url]).await?;
    } else if current.trim() != url && replace_origin {
        git(root, &["remote", "set-url", "origin", url]).await?;
    } else if current.trim() != url {
        return Err(error(
            "remote_exists",
            "Este repositorio ya tiene un remoto origin con otra dirección. Revísalo en Remotos.",
        ));
    }
    let mut pushed: Vec<String> = Vec::new();
    let primary = primary_branch(root).await;
    let protected = main_protected(root).await;
    for branch in branches {
        validate_branch(root, branch).await?;
        if protected && *branch == primary {
            return Err(error(
                "protected_branch",
                format!("{primary} está protegida en este repo: súbela mediante un PR o desactiva la protección en la barra de estado."),
            ));
        }
        if git(
            root,
            &[
                "show-ref",
                "--verify",
                "--quiet",
                &format!("refs/heads/{branch}"),
            ],
        )
        .await
        .is_err()
        {
            continue;
        }
        let spec = format!("refs/heads/{branch}:refs/heads/{branch}");
        git(root, &["push", "-u", "origin", &spec])
            .await
            .map_err(access_failure)
            .map_err(|mut failure| {
                if !pushed.is_empty() {
                    failure.detail = format!(
                        "{}\n\nRamas que sí se subieron: {}.",
                        failure.detail,
                        pushed.join(", ")
                    );
                }
                failure
            })?;
        pushed.push(branch.clone());
    }
    Ok(pushed)
}

/// Access problems from push/fetch explained in Spanish (SSH key not registered, missing HTTPS credentials).
pub fn access_failure(failure: GitError) -> GitError {
    let detail = failure.detail.to_lowercase();
    if detail.contains("permission denied (publickey)") {
        error(
            "ssh_denied",
            "El servidor no reconoce ninguna llave SSH de este Mac. Elige HTTPS (usa tus credenciales de Git o de gh) o agrega tu llave pública en la configuración SSH de tu cuenta.",
        )
    } else if detail.contains("could not read username")
        || detail.contains("authentication failed")
        || detail.contains("terminal prompts disabled")
    {
        error(
            "https_denied",
            "Git no tiene credenciales HTTPS para este servidor. Inicia sesión con gh auth login (GitHub) o guarda tu usuario y token en el gestor de credenciales, o usa SSH.",
        )
    } else {
        failure
    }
}

/// Same rule as `primary_branch`, from branches that were already listed (no extra Git process).
pub fn primary_from(local: &[Branch], remote: &[RemoteBranch]) -> String {
    for name in ["main", "master"] {
        if local.iter().any(|b| b.name == name)
            || remote
                .iter()
                .any(|b| b.remote == "origin" && b.short == name)
        {
            return name.into();
        }
    }
    "main".into()
}

/// Butake settings and remote names of a repository, read with a single `git config` call.
#[derive(Default, Debug, PartialEq)]
pub struct RepositoryConfig {
    /// `butake.protectMain` as stored (empty when unset).
    pub protect_main: String,
    /// `butake.remoteProtectMain` as stored (empty when unset).
    pub remote_protect_main: String,
    pub remotes: Vec<String>,
}

impl RepositoryConfig {
    /// Explicit choice first, then the provider's rule; unknown means not blocked.
    pub fn main_protected(&self) -> bool {
        for value in [&self.protect_main, &self.remote_protect_main] {
            match value.trim().to_ascii_lowercase().as_str() {
                "true" | "1" | "yes" | "on" => return true,
                "false" | "0" | "no" | "off" => return false,
                _ => {}
            }
        }
        false
    }
}

/// Parses `git config --get-regexp` lines (`key value`; Git prints section and variable names in
/// lowercase and keeps the subsection, i.e. the remote name, as written). The last value of a key wins.
pub fn parse_repository_config(raw: &str) -> RepositoryConfig {
    let mut config = RepositoryConfig::default();
    for line in raw.lines() {
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        match key {
            "butake.protectmain" => config.protect_main = value.trim().into(),
            "butake.remoteprotectmain" => config.remote_protect_main = value.trim().into(),
            _ => {
                if let Some(name) = key
                    .strip_prefix("remote.")
                    .and_then(|rest| rest.strip_suffix(".url"))
                {
                    if !name.is_empty() && !config.remotes.iter().any(|r| r == name) {
                        config.remotes.push(name.into());
                    }
                }
            }
        }
    }
    config.remotes.sort();
    config
}

pub async fn repository_config(root: &Path) -> RepositoryConfig {
    // Exit code 1 (no matching key) reads as an empty configuration.
    let raw = git(
        root,
        &[
            "config",
            "--get-regexp",
            r"^(butake\.(remote)?protectmain|remote\..+\.url)$",
        ],
    )
    .await
    .unwrap_or_default();
    parse_repository_config(&raw)
}

/// The repository's primary branch: `main`, or `master` in repositories that still use it.
pub async fn primary_branch(root: &Path) -> String {
    for name in ["main", "master"] {
        for reference in [
            format!("refs/heads/{name}"),
            format!("refs/remotes/origin/{name}"),
        ] {
            if git(root, &["rev-parse", "--verify", "--quiet", &reference])
                .await
                .is_ok()
            {
                return name.into();
            }
        }
    }
    "main".into()
}

/// Whether `main` is protected in this repository.
/// 1. Explicit `git config butake.protectMain true|false` (chosen by the user) wins.
/// 2. Otherwise the hosting provider's real rule, cached by the app in `butake.remoteProtectMain`.
/// 3. Unknown: not blocked (the app still asks for an explicit confirmation before pushing to main).
pub async fn main_protected(root: &Path) -> bool {
    repository_config(root).await.main_protected()
}

/// Caches the provider's protection rule for `main` ("true", "false" or "unknown" to clear it).
pub async fn set_remote_protection(root: &Path, value: &str) -> Result<String> {
    match value {
        "true" | "false" => {
            git(
                root,
                &["config", "--local", "butake.remoteProtectMain", value],
            )
            .await
        }
        "unknown" => git(
            root,
            &["config", "--local", "--unset", "butake.remoteProtectMain"],
        )
        .await
        .or(Ok(String::new())),
        _ => Err(error("invalid_arguments", "Valor de protección inválido.")),
    }
}

pub async fn set_main_protection(root: &Path, value: &str) -> Result<String> {
    match value {
        "true" | "false" => git(root, &["config", "--local", "butake.protectMain", value]).await,
        "auto" => git(
            root,
            &["config", "--local", "--unset", "butake.protectMain"],
        )
        .await
        .or(Ok(String::new())),
        _ => Err(error("invalid_arguments", "Valor de protección inválido.")),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchSync {
    pub left: String,
    pub right: String,
    pub only_left: Vec<Commit>,
    pub only_right: Vec<Commit>,
    pub equivalent_left: Vec<Commit>,
    pub equivalent_right: Vec<Commit>,
    pub merge_base: Option<String>,
}

/// Compares two branches by patch content (`--cherry-mark`): a commit copied with cherry-pick
/// counts as present on both sides even though its hash differs.
pub async fn branch_sync(root: &Path, left: &str, right: &str) -> Result<BranchSync> {
    for name in [left, right] {
        if name.is_empty() || name.starts_with('-') {
            return Err(error("invalid_ref", "Referencia inválida."));
        }
        git(
            root,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{name}^{{commit}}"),
            ],
        )
        .await
        .map_err(|_| error("invalid_ref", format!("No existe la rama {name}.")))?;
    }
    let range = format!("{left}...{right}");
    let log_args = [
        "log",
        "--left-right",
        "--cherry-mark",
        "--no-merges",
        "--topo-order",
        "-2000",
        "--format=%m%x1f%H%x1f%P%x1f%an%x1f%at%x1f%s",
        range.as_str(),
        "--",
    ];
    let base_args = ["merge-base", left, right];
    // Commits only reachable from the left side, in one process (instead of one `merge-base` per commit).
    let left_only = format!("{right}..{left}");
    let side_args = ["rev-list", "--no-merges", left_only.as_str(), "--"];
    let (log, base, side) = tokio::join!(
        git(root, &log_args),
        git(root, &base_args),
        git(root, &side_args)
    );
    let side = side.unwrap_or_default();
    let on_left_side: HashSet<&str> = side.lines().map(str::trim).collect();
    let mut sync = BranchSync {
        left: left.into(),
        right: right.into(),
        only_left: vec![],
        only_right: vec![],
        equivalent_left: vec![],
        equivalent_right: vec![],
        merge_base: base.ok().map(|b| b.trim().to_string()),
    };
    for line in log?.lines() {
        let f: Vec<_> = line.splitn(6, '\x1f').collect();
        if f.len() != 6 {
            continue;
        }
        let commit = Commit {
            hash: f[1].into(),
            parents: f[2].split_whitespace().map(String::from).collect(),
            author: f[3].into(),
            timestamp: f[4].into(),
            subject: f[5].into(),
            refs: String::new(),
        };
        // `=` marks equivalent commits; the side comes from comparing against the left tip's ancestry.
        match f[0] {
            "<" => sync.only_left.push(commit),
            ">" => sync.only_right.push(commit),
            _ => {
                if on_left_side.contains(commit.hash.as_str()) {
                    sync.equivalent_left.push(commit)
                } else {
                    sync.equivalent_right.push(commit)
                }
            }
        }
    }
    Ok(sync)
}

/// Copies commits onto `target` with `cherry-pick -x` (oldest first) and returns to the original branch.
/// On conflict the cherry-pick stays in progress on `target` so the conflict assistant can finish it.
pub async fn copy_commits(root: &Path, target: &str, hashes: &[String]) -> Result<usize> {
    if hashes.is_empty() {
        return Ok(0);
    }
    validate_branch(root, target).await?;
    git(
        root,
        &["show-ref", "--verify", &format!("refs/heads/{target}")],
    )
    .await
    .map_err(|_| error("invalid_ref", format!("No existe la rama local {target}.")))?;
    if target == primary_branch(root).await && main_protected(root).await {
        return Err(error(
            "protected_branch",
            "main está protegida en este repo. Desactívala en la barra de estado o lleva los cambios por PR.",
        ));
    }
    let state = snapshot(root).await?;
    if !state.operation.is_empty() {
        return Err(error(
            "operation_in_progress",
            "Termina o cancela la operación en curso antes de copiar commits.",
        ));
    }
    if !state.files.is_empty() {
        return Err(error(
            "dirty_worktree",
            "Tienes cambios sin commit. Haz commit o guárdalos en stash antes de copiar commits entre ramas.",
        ));
    }
    let mut ordered = Vec::new();
    for hash in hashes.iter().rev() {
        ordered.push(validate_commit(root, hash).await?);
    }
    let original = state.branch.clone();
    // Detached HEAD has no branch to return to: remember the commit instead.
    let detached = if original == "HEAD" {
        Some(
            git(root, &["rev-parse", "--verify", "HEAD"])
                .await?
                .trim()
                .to_string(),
        )
    } else {
        None
    };
    if original != target {
        git(root, &["switch", target]).await?;
    }
    let back = || async {
        match &detached {
            Some(hash) => git(root, &["switch", "--detach", hash]).await,
            None if original != target => git(root, &["switch", &original]).await,
            None => Ok(String::new()),
        }
    };
    let mut args = vec!["cherry-pick", "-x"];
    args.extend(ordered.iter().map(String::as_str));
    let mut outcome = git(root, &args).await;
    let mut skipped = 0;
    loop {
        let failure = match outcome {
            Ok(_) => break,
            Err(failure) => failure,
        };
        let conflicted = parse_status(&git(root, &["status", "--porcelain=v1", "-z"]).await?)
            .iter()
            .any(ChangedFile::conflicted);
        if conflicted {
            return Err(error(
                "copy_conflicts",
                format!("Hay conflictos al copiar a {target}. Quedaste en {target}: resuélvelos, pulsa «Continuar» y luego vuelve a {original}."),
            ));
        }
        if failure.detail.contains("empty") && skipped < ordered.len() {
            // Already applied on the target: skip it and let the rest of the sequence continue.
            skipped += 1;
            outcome = git(root, &["cherry-pick", "--skip"]).await;
            continue;
        }
        let _ = git(root, &["cherry-pick", "--abort"]).await;
        let _ = back().await;
        return Err(failure);
    }
    back().await?;
    let copied = ordered.len() - skipped;
    if copied == 0 {
        return Err(error(
            "copy_empty",
            "Los commits ya estaban aplicados en la rama destino; no se copió nada nuevo.",
        ));
    }
    Ok(copied)
}

pub async fn open_root(path: &str) -> Result<PathBuf> {
    let candidate =
        std::fs::canonicalize(path).map_err(|e| error("invalid_path", e.to_string()))?;
    let root = git(&candidate, &["rev-parse", "--show-toplevel"]).await?;
    std::fs::canonicalize(root.trim()).map_err(|e| error("invalid_path", e.to_string()))
}

pub async fn authorized(state: &GitState, path: &str) -> Result<PathBuf> {
    let root = std::fs::canonicalize(path).map_err(|e| error("invalid_path", e.to_string()))?;
    if !state.opened.lock().await.contains(&root) {
        return Err(error("not_open", "Abre primero el repositorio."));
    }
    Ok(root)
}

pub fn parse_status(raw: &str) -> Vec<ChangedFile> {
    let mut entries = raw.split('\0').filter(|s| !s.is_empty());
    let mut files = Vec::new();
    while let Some(entry) = entries.next() {
        if entry.len() < 4 || !entry.is_char_boundary(3) {
            continue;
        }
        let index = &entry[0..1];
        let worktree = &entry[1..2];
        let original_path = if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
            entries.next().map(String::from)
        } else {
            None
        };
        files.push(ChangedFile {
            path: entry[3..].to_string(),
            original_path,
            index: index.into(),
            worktree: worktree.into(),
        });
    }
    files
}

/// Changed files only: the cheap refresh for working-tree edits, which cannot move refs or history.
pub async fn status(root: &Path) -> Result<Vec<ChangedFile>> {
    Ok(parse_status(
        &git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        )
        .await?,
    ))
}

pub const DEFAULT_HISTORY_LIMIT: usize = 180;
pub const MAX_HISTORY_LIMIT: usize = 5_000;

pub async fn snapshot(root: &Path) -> Result<Snapshot> {
    snapshot_limited(root, DEFAULT_HISTORY_LIMIT).await
}

pub async fn snapshot_limited(root: &Path, limit: usize) -> Result<Snapshot> {
    snapshot_with(root, limit, false).await
}

const OPERATION_MARKERS: [(&str, &str); 5] = [
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("MERGE_HEAD", "merge"),
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
];

/// Independent Git reads run concurrently: with large working trees the
/// snapshot cost is bounded by the slowest command instead of their sum.
pub async fn snapshot_with(root: &Path, limit: usize, with_stats: bool) -> Result<Snapshot> {
    let limit = format!("-{}", limit.clamp(1, MAX_HISTORY_LIMIT));
    let markers: Vec<String> = OPERATION_MARKERS
        .iter()
        .flat_map(|(marker, _)| ["--git-path".to_string(), marker.to_string()])
        .collect();
    let mut marker_args = vec!["rev-parse"];
    marker_args.extend(markers.iter().map(String::as_str));
    // Branches, remotes, tags and HEAD only: `--all` would also show stashes and Butake backup refs.
    let log_args = [
        "log",
        limit.as_str(),
        "--branches",
        "--remotes",
        "--tags",
        "HEAD",
        "--topo-order",
        "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D",
    ];
    let (
        status,
        branch,
        log,
        raw_branches,
        divergence,
        paths,
        remote,
        stats,
        config,
    ) = tokio::join!(
        git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"]
        ),
        git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"]),
        git(root, &log_args),
        git(
            root,
            &[
                "for-each-ref",
                "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(committerdate:unix)",
                "refs/heads/",
                "refs/remotes/",
            ],
        ),
        git(
            root,
            &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
        ),
        git(root, &marker_args),
        git(root, &["remote", "get-url", "origin"]),
        async {
            if with_stats {
                Some(line_stats(root).await)
            } else {
                None
            }
        },
        repository_config(root),
    );
    let files = parse_status(&status?);
    let branch = branch.unwrap_or_else(|_| "HEAD".into()).trim().to_string();
    // An unborn branch has no HEAD: `git log` fails and the history is empty.
    let commits = log
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let f: Vec<_> = line.splitn(6, '\x1f').collect();
            (f.len() == 6).then(|| Commit {
                hash: f[0].into(),
                parents: f[1].split_whitespace().map(String::from).collect(),
                author: f[2].into(),
                timestamp: f[3].into(),
                subject: f[4].into(),
                refs: f[5].into(),
            })
        })
        .collect();
    let (branches, remote_branches) = parse_branches(&raw_branches?);
    let primary = primary_from(&branches, &remote_branches);
    let divergence = divergence.unwrap_or_default();
    let mut counts = divergence
        .split_whitespace()
        .map(|n| n.parse::<u64>().unwrap_or(0));
    let ahead = counts.next().unwrap_or(0);
    let behind = counts.next().unwrap_or(0);
    let paths = paths?;
    let operation = paths
        .lines()
        .zip(OPERATION_MARKERS.iter())
        .find(|(location, _)| root.join(location.trim()).exists())
        .map(|(_, (_, label))| label.to_string())
        .unwrap_or_default();
    Ok(Snapshot {
        root: root.display().to_string(),
        branch,
        files,
        commits,
        branches,
        operation,
        ahead,
        behind,
        remote: remote.unwrap_or_default().trim().to_string(),
        stats,
        main_protected: config.main_protected(),
        main_protection: config.protect_main,
        main_protection_remote: config.remote_protect_main,
        primary_branch: primary,
        remote_branches,
        remotes: config.remotes,
    })
}

fn validate_path(value: &str) -> Result<()> {
    if value.is_empty()
        || Path::new(value).is_absolute()
        || Path::new(value)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(error("invalid_path", "Ruta relativa inválida."));
    }
    Ok(())
}
/// Splits `for-each-ref` output into local branches (with tracking state) and remote branches.
pub fn parse_branches(text: &str) -> (Vec<Branch>, Vec<RemoteBranch>) {
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for line in text.lines() {
        let f: Vec<_> = line.splitn(5, '\t').collect();
        if f.len() < 5 {
            continue;
        }
        let updated = f[4].trim().parse().unwrap_or(0);
        if let Some(name) = f[0].strip_prefix("refs/heads/") {
            let track = f[3];
            let number = |key: &str| {
                track
                    .split(", ")
                    .find_map(|part| part.strip_prefix(key))
                    .and_then(|n| n.trim().parse().ok())
                    .unwrap_or(0)
            };
            local.push(Branch {
                name: name.into(),
                current: f[1] == "*",
                upstream: f[2].into(),
                ahead: number("ahead "),
                behind: number("behind "),
                gone: track == "gone",
                updated,
            });
        } else if let Some(name) = f[0].strip_prefix("refs/remotes/") {
            let Some((remote_name, short)) = name.split_once('/') else {
                continue;
            };
            if short == "HEAD" {
                continue;
            }
            remote.push(RemoteBranch {
                name: name.into(),
                remote: remote_name.into(),
                short: short.into(),
                updated,
            });
        }
    }
    (local, remote)
}

async fn validate_branch(root: &Path, value: &str) -> Result<()> {
    // `@{-1}` and friends pass `check-ref-format --branch` (it expands them) and would name another branch.
    if value.starts_with('-') || value.is_empty() || value == "@" || value.contains("@{") {
        return Err(error("invalid_ref", "Referencia inválida."));
    }
    git(root, &["check-ref-format", "--branch", value])
        .await
        .map_err(|_| {
            error(
                "invalid_ref",
                format!("«{value}» no es un nombre de rama válido."),
            )
        })?;
    Ok(())
}
async fn validate_commit(root: &Path, value: &str) -> Result<String> {
    if value.is_empty() || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(error("invalid_ref", "Selecciona un commit por su hash."));
    }
    Ok(git(
        root,
        &["rev-parse", "--verify", &format!("{value}^{{commit}}")],
    )
    .await?
    .trim()
    .into())
}

pub async fn execute(root: &Path, action: Action, value: &str, confirmed: bool) -> Result<String> {
    use Action::*;
    let branch = git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default();
    if branch.trim() == primary_branch(root).await
        && main_protected(root).await
        && !matches!(
            action,
            // Fast-forward pulls only move main to the remote state; they never create local commits.
            Fetch
                | Pull
                | PullAutostash
                | TrackBranch
                | DeleteBranch
                | ForceDeleteBranch
                | DeleteRemoteBranch
                | RenameBranch
                | SwitchBranch
                | CreateBranch
                | Stage
                | Unstage
                | Stash
                | Discard
        )
    {
        return Err(error(
            "protected_branch",
            "main está protegida: trabaja en develop o una rama de cambio y promueve mediante PR.",
        ));
    }
    if matches!(
        action,
        ForceDeleteBranch | DeleteRemoteBranch | DeleteBranch
    ) && !confirmed
    {
        return Err(error(
            "confirmation_required",
            "Confirma la eliminación de la rama.",
        ));
    }
    if matches!(
        action,
        Push | Pull
            | Merge
            | Rebase
            | RebaseAbort
            | StashPop
            | Revert
            | CherryPick
            | Discard
            | PullMerge
            | PullRebase
            | PullAutostash
    ) && !confirmed
    {
        return Err(error(
            "confirmation_required",
            "Confirma la operación y su alcance.",
        ));
    }
    match action {
        Stage | Unstage => {
            validate_path(value)?;
            let status = parse_status(
                &git(
                    root,
                    &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                )
                .await?,
            );
            let file = status
                .iter()
                .find(|f| f.path == value)
                .ok_or_else(|| error("stale_file", "El archivo ya no figura entre los cambios."))?;
            let mut paths = vec![value];
            if let Some(original) = &file.original_path {
                paths.push(original);
            }
            let mut args = match action {
                Stage => vec!["add", "--"],
                _ if git(root, &["rev-parse", "--verify", "HEAD"]).await.is_ok() => {
                    vec!["restore", "--staged", "--"]
                }
                _ => vec!["rm", "--cached", "-f", "--"],
            };
            args.extend(paths);
            git(root, &args).await
        }
        Discard => {
            validate_path(value)?;
            let status = parse_status(
                &git(
                    root,
                    &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                )
                .await?,
            );
            let file = status
                .iter()
                .find(|f| f.path == value)
                .ok_or_else(|| error("stale_file", "El archivo ya no figura entre los cambios."))?;
            if file.conflicted() {
                return Err(error(
                    "conflict",
                    "Resuelve el conflicto antes de descartar cambios.",
                ));
            }
            if file.index == "?" {
                // Only the selected untracked file; never directories or ignored files.
                git(root, &["clean", "--force", "--", value]).await
            } else if file.worktree != " " {
                // Restores from the index, so staged content is preserved.
                git(root, &["restore", "--worktree", "--", value]).await
            } else {
                Err(error(
                    "nothing_to_discard",
                    "El archivo no tiene cambios sin preparar.",
                ))
            }
        }
        Commit => {
            if value.trim().is_empty() {
                return Err(error("empty_message", "Escribe el mensaje del commit."));
            }
            git(root, &["commit", "-m", value]).await
        }
        Fetch | Pull | PullMerge | PullRebase | PullAutostash | Push | DeleteRemoteBranch
            if git(root, &["remote"]).await.unwrap_or_default().trim().is_empty() =>
        {
            Err(error(
                "no_remote",
                "Este repositorio sólo existe en tu Mac: no tiene remoto. Agrega uno en Remotos (por ejemplo origin) para buscar, bajar o subir cambios.",
            ))
        }
        Fetch => git(root, &["fetch", "--prune"]).await.map_err(access_failure),
        Pull => pull(root, &["pull", "--ff-only"]).await,
        PullMerge => pull(root, &["pull", "--no-rebase", "--no-edit"]).await,
        PullRebase => pull(root, &["pull", "--rebase"]).await,
        PullAutostash => pull(root, &["pull", "--ff-only", "--autostash"]).await,
        TrackBranch => {
            let (remote, short) = value
                .split_once('/')
                .ok_or_else(|| error("invalid_ref", "Elige una rama remota."))?;
            validate_branch(root, short).await?;
            if remote.starts_with('-') {
                return Err(error("invalid_ref", "Remoto inválido."));
            }
            git(
                root,
                &["show-ref", "--verify", &format!("refs/remotes/{value}")],
            )
            .await
            .map_err(|_| {
                error(
                    "invalid_ref",
                    format!("No existe {value}. Busca cambios primero."),
                )
            })?;
            if git(
                root,
                &[
                    "show-ref",
                    "--verify",
                    "--quiet",
                    &format!("refs/heads/{short}"),
                ],
            )
            .await
            .is_ok()
            {
                return git(root, &["switch", short]).await;
            }
            git(root, &["switch", "--track", value]).await
        }
        DeleteBranch | ForceDeleteBranch => {
            validate_branch(root, value).await?;
            if value == primary_branch(root).await || value == branch.trim() {
                return Err(error(
                    "protected_branch",
                    "No se puede eliminar la rama principal ni la rama actual.",
                ));
            }
            let flag = if matches!(action, ForceDeleteBranch) {
                "-D"
            } else {
                "-d"
            };
            git(root, &["branch", flag, value]).await.map_err(|failure| {
                if failure.detail.contains("not fully merged") {
                    error(
                        "branch_not_merged",
                        format!("{value} tiene commits que no están en ninguna otra rama. Elimínala de todos modos sólo si ya no los necesitas."),
                    )
                } else {
                    failure
                }
            })
        }
        DeleteRemoteBranch => {
            let (remote, short) = value
                .split_once('/')
                .ok_or_else(|| error("invalid_ref", "Elige una rama remota."))?;
            validate_branch(root, short).await?;
            if remote.starts_with('-') || short == primary_branch(root).await || short == "develop"
            {
                return Err(error(
                    "protected_branch",
                    "La rama principal y develop no se eliminan desde aquí.",
                ));
            }
            git(root, &["push", remote, "--delete", short]).await
        }
        RenameBranch => {
            let (old, new) = value
                .split_once(':')
                .ok_or_else(|| error("invalid_ref", "Nombre inválido."))?;
            validate_branch(root, old).await?;
            validate_branch(root, new).await?;
            if old == primary_branch(root).await {
                return Err(error(
                    "protected_branch",
                    "La rama principal no se renombra.",
                ));
            }
            git(root, &["branch", "-m", old, new]).await
        }
        Push => {
            let name = branch.trim();
            validate_branch(root, name).await?;
            // Explicit destination prevents push.default / remote.push from promoting another branch.
            git(
                root,
                &[
                    "push",
                    "--set-upstream",
                    "origin",
                    &format!("refs/heads/{name}:refs/heads/{name}"),
                ],
            )
            .await
            .map_err(access_failure)
        }
        CreateBranch => {
            validate_branch(root, value).await?;
            git(root, &["switch", "-c", value]).await
        }
        SwitchBranch | Merge | Rebase => {
            validate_branch(root, value).await?;
            git(
                root,
                &["show-ref", "--verify", &format!("refs/heads/{value}")],
            )
            .await?;
            let verb = match action {
                SwitchBranch => "switch",
                Merge => "merge",
                _ => "rebase",
            };
            git(root, &[verb, value]).await
        }
        RebaseContinue => git(root, &["rebase", "--continue"]).await,
        RebaseAbort => git(root, &["rebase", "--abort"]).await,
        Stash => {
            git(
                root,
                &["stash", "push", "--include-untracked", "-m", "Butake Git"],
            )
            .await
        }
        StashPop => git(root, &["stash", "pop"]).await,
        Revert | CherryPick => {
            let hash = validate_commit(root, value).await?;
            let verb = if matches!(action, Revert) {
                "revert"
            } else {
                "cherry-pick"
            };
            git(root, &[verb, &hash]).await
        }
    }
}

/// Runs a pull and turns Git's failure into a stable code the UI can guide the user from.
async fn pull(root: &Path, args: &[&str]) -> Result<String> {
    match git(root, args).await {
        Ok(output) => Ok(output),
        Err(failure) => {
            let conflicted = parse_status(&git(root, &["status", "--porcelain=v1", "-z"]).await?)
                .iter()
                .any(ChangedFile::conflicted);
            Err(classify_pull_failure(&failure.detail, conflicted))
        }
    }
}

pub fn classify_pull_failure(detail: &str, conflicted: bool) -> GitError {
    let text = detail.to_lowercase();
    let (code, message) = if conflicted || text.contains("conflict") {
        ("pull_conflicts", "Los cambios del remoto chocan con los tuyos en algunos archivos. Resuélvelos uno por uno y luego continúa.")
    } else if text.contains("not possible to fast-forward")
        || text.contains("diverg")
        || text.contains("need to specify how to reconcile")
    {
        (
            "pull_diverged",
            "Tu rama y la del remoto tienen commits distintos. Elige cómo combinarlas.",
        )
    } else if text.contains("would be overwritten")
        || text.contains("commit your changes or stash")
        || text.contains("unstaged changes")
        || text.contains("uncommitted changes")
    {
        ("pull_local_changes", "Tienes cambios sin guardar en commit que se pisarían al bajar. Puedes guardarlos temporalmente y recuperarlos después.")
    } else if text.contains("no tracking information") || text.contains("no such ref was fetched") {
        ("pull_no_upstream", "Esta rama todavía no está conectada con una rama del remoto. Súbela primero o configura su upstream.")
    } else if text.contains("could not read from remote")
        || text.contains("authentication")
        || text.contains("permission denied")
        || text.contains("could not resolve host")
    {
        (
            "pull_remote_unreachable",
            "No se pudo conectar con el remoto. Revisa tu conexión, VPN o credenciales SSH.",
        )
    } else {
        return error("git_failed", detail.to_string());
    };
    error(
        code,
        format!("{message}\n\nDetalle de Git: {}", detail.trim()),
    )
}

/// Arguments of the patch for one changed file, or `None` when the file is untracked (no patch exists).
async fn diff_arguments(root: &Path, path: &str, staged: bool) -> Result<Option<Vec<String>>> {
    validate_path(path)?;
    let files = parse_status(
        &git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        )
        .await?,
    );
    let file = files
        .iter()
        .find(|f| f.path == path)
        .ok_or_else(|| error("stale_file", "Actualiza la selección."))?;
    if file.index == "?" {
        return Ok(None);
    }
    // Explicit prefixes: `diff.noprefix` / `diff.mnemonicPrefix` would make `git apply` strip a path component.
    let mut args: Vec<String> = [
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--no-color",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ]
    .map(String::from)
    .to_vec();
    if staged {
        args.push("--cached".into());
    }
    // A moved file is diffed against its old path so Git reports a rename (and only real edits).
    let original = file.original_path.clone().filter(|_| staged);
    if original.is_some() {
        args.push("-M".into());
    }
    args.extend(["--".to_string(), path.to_string()]);
    args.extend(original);
    Ok(Some(args))
}

/// The patch exactly as Git wrote it (any encoding), for `git apply`. Untracked files have none.
pub async fn diff_bytes(root: &Path, path: &str, staged: bool) -> Result<Vec<u8>> {
    let Some(args) = diff_arguments(root, path, staged).await? else {
        return Err(error(
            "invalid_hunk",
            "Un archivo nuevo se prepara completo, no por bloques.",
        ));
    };
    git_bytes(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await
}

/// The working-tree file against the last commit. For a file that was staged when created (an IDE adding a copy)
/// and edited afterwards, the unstaged patch alone shows the edits made to the staged copy, as if an existing file
/// had been modified; this one shows what the commit would really bring in: the whole new file.
pub async fn diff_whole(root: &Path, path: &str) -> Result<String> {
    validate_path(path)?;
    let head = git(root, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .await
        .unwrap_or_default();
    // Without commits yet, compare against the empty tree.
    let base = if head.trim().is_empty() {
        git(root, &["hash-object", "-t", "tree", "/dev/null"])
            .await?
            .trim()
            .to_string()
    } else {
        head.trim().to_string()
    };
    git_lossy(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--no-renames",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            &base,
            "--",
            path,
        ],
    )
    .await
}

pub async fn diff(root: &Path, path: &str, staged: bool) -> Result<String> {
    let Some(args) = diff_arguments(root, path, staged).await? else {
        let full = std::fs::canonicalize(root.join(path))
            .map_err(|e| error("invalid_path", e.to_string()))?;
        if !full.starts_with(root) || !full.is_file() {
            return Err(error("invalid_path", "Archivo fuera del repositorio."));
        }
        let metadata =
            std::fs::metadata(&full).map_err(|e| error("invalid_path", e.to_string()))?;
        if metadata.len() > 1_000_000 {
            return Ok("[Archivo mayor a 1 MB: vista previa omitida]".into());
        }
        let bytes = std::fs::read(full).map_err(|e| error("invalid_path", e.to_string()))?;
        return Ok(String::from_utf8(bytes).unwrap_or_else(|_| "[Archivo binario]".into()));
    };
    // Content in another encoding (Latin-1…) is shown with replacement characters instead of failing.
    git_lossy(root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await
}

pub fn pull_request_url(remote: &str) -> Result<String> {
    let path = remote
        .strip_prefix("git@bitbucket.org:")
        .or_else(|| remote.strip_prefix("https://bitbucket.org/"))
        .ok_or_else(|| {
            error(
                "unsupported_remote",
                "Esta versión abre PR solo para Bitbucket Cloud.",
            )
        })?;
    let path = path.trim_end_matches(".git");
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() != 2
        || parts.iter().any(|p| {
            p.is_empty()
                || !p
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        })
    {
        return Err(error("unsupported_remote", "Remoto Bitbucket inválido."));
    }
    Ok(format!("https://bitbucket.org/{path}/pull-requests/new"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_special_paths_and_renames() {
        let files =
            parse_status(" M archivo con espacio\0R  nuevo\nanother\0anterior\0?? -opcion\0");
        assert_eq!(files.len(), 3);
        assert_eq!(files[1].original_path.as_deref(), Some("anterior"));
        assert_eq!(files[2].path, "-opcion");
    }
    #[tokio::test]
    async fn new_file_staged_then_edited_is_shown_whole() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        git(root, &["init", "-b", "develop"]).await.unwrap();
        git(root, &["config", "user.name", "Test"]).await.unwrap();
        git(root, &["config", "user.email", "test@example.invalid"])
            .await
            .unwrap();
        // No commits yet: compared against the empty tree.
        std::fs::write(root.join("first.txt"), "one\n").unwrap();
        git(root, &["add", "first.txt"]).await.unwrap();
        assert!(diff_whole(root, "first.txt")
            .await
            .unwrap()
            .contains("+one"));
        git(root, &["commit", "-m", "base"]).await.unwrap();
        // Staged as a copy, edited afterwards (status AM).
        std::fs::write(root.join("copy.txt"), "old a\nold b\nsame\n").unwrap();
        git(root, &["add", "copy.txt"]).await.unwrap();
        std::fs::write(root.join("copy.txt"), "new a\nnew b\nsame\n").unwrap();
        let parts = diff(root, "copy.txt", false).await.unwrap();
        assert!(parts.contains("-old a") && parts.contains("+new a"));
        let whole = diff_whole(root, "copy.txt").await.unwrap();
        assert!(whole.contains("new file mode"));
        assert!(whole.contains("+new a") && whole.contains("+same"));
        assert!(!whole.contains("old a"));
        assert!(diff_whole(root, "../outside").await.is_err());
    }
    #[test]
    fn external_url_is_restricted() {
        assert!(pull_request_url("git@bitbucket.org:equipo/proyecto.git")
            .unwrap()
            .starts_with("https://bitbucket.org/equipo/"));
        assert!(pull_request_url("https://evil.org/x/y").is_err());
        assert!(pull_request_url("https://bitbucket.org/x/y?bad").is_err());
    }
    #[tokio::test]
    async fn actual_git_lifecycle_and_protection() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        git(root, &["init", "-b", "develop"]).await.unwrap();
        git(root, &["config", "user.name", "Test"]).await.unwrap();
        git(root, &["config", "user.email", "test@example.invalid"])
            .await
            .unwrap();
        std::fs::write(root.join("file.txt"), "hello\n").unwrap();
        execute(root, Action::Stage, "file.txt", false)
            .await
            .unwrap();
        assert_eq!(snapshot(root).await.unwrap().files[0].index, "A");
        execute(root, Action::Unstage, "file.txt", false)
            .await
            .unwrap();
        execute(root, Action::Stage, "file.txt", false)
            .await
            .unwrap();
        execute(root, Action::Commit, "feat(test): primer commit", false)
            .await
            .unwrap();
        assert_eq!(snapshot(root).await.unwrap().commits.len(), 1);
        execute(root, Action::CreateBranch, "main", false)
            .await
            .unwrap();
        // The hosting provider reports main as protected.
        set_remote_protection(root, "true").await.unwrap();
        assert_eq!(
            execute(root, Action::Push, "", true)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
        assert!(execute(root, Action::Commit, "blocked", false)
            .await
            .is_err());
        execute(root, Action::SwitchBranch, "develop", false)
            .await
            .unwrap();
        assert_eq!(
            execute(root, Action::Push, "", false)
                .await
                .unwrap_err()
                .code,
            "confirmation_required"
        );
        assert!(execute(root, Action::CreateBranch, "--evil", false)
            .await
            .is_err());
        assert!(diff(root, "../outside", false).await.is_err());
    }
    #[tokio::test]
    async fn branch_sync_detects_copies_and_copy_commits_returns_to_branch() {
        let temp = repository().await;
        let root = temp.path();
        git(root, &["branch", "main"]).await.unwrap();
        git(root, &["config", "butake.protectMain", "false"])
            .await
            .unwrap();
        for (file, message) in [
            ("a.txt", "feat: a"),
            ("b.txt", "feat: b"),
            ("c.txt", "feat: c"),
        ] {
            std::fs::write(root.join(file), format!("{file}\n")).unwrap();
            git(root, &["add", file]).await.unwrap();
            git(root, &["commit", "-qm", message]).await.unwrap();
        }
        let b = git(root, &["rev-parse", "HEAD~1"])
            .await
            .unwrap()
            .trim()
            .to_string();
        git(root, &["switch", "-q", "main"]).await.unwrap();
        git(root, &["cherry-pick", &b]).await.unwrap();
        git(root, &["switch", "-q", "develop"]).await.unwrap();
        let sync = branch_sync(root, "develop", "main").await.unwrap();
        assert_eq!(
            sync.only_left
                .iter()
                .map(|c| c.subject.as_str())
                .collect::<Vec<_>>(),
            ["feat: c", "feat: a"]
        );
        assert!(sync.only_right.is_empty());
        assert_eq!(sync.equivalent_left.len(), 1);
        assert_eq!(sync.equivalent_right.len(), 1);
        let hashes: Vec<String> = sync.only_left.iter().map(|c| c.hash.clone()).collect();
        assert_eq!(copy_commits(root, "main", &hashes).await.unwrap(), 2);
        assert_eq!(snapshot(root).await.unwrap().branch, "develop");
        let after = branch_sync(root, "develop", "main").await.unwrap();
        assert!(after.only_left.is_empty() && after.only_right.is_empty());
        let log = git(root, &["log", "-1", "--format=%B", "main"])
            .await
            .unwrap();
        assert!(log.contains("cherry picked from commit"));
        std::fs::write(root.join("dirty.txt"), "x\n").unwrap();
        assert_eq!(
            copy_commits(root, "main", &hashes).await.unwrap_err().code,
            "dirty_worktree"
        );
        assert!(branch_sync(root, "develop", "--evil").await.is_err());
    }
    #[tokio::test]
    async fn staged_rename_diff_reports_rename() {
        let temp = repository().await;
        let root = temp.path();
        git(root, &["mv", "base.txt", "moved.txt"]).await.unwrap();
        let text = diff(root, "moved.txt", true).await.unwrap();
        assert!(
            text.contains("rename from base.txt") && text.contains("rename to moved.txt"),
            "{text}"
        );
        assert!(!text.contains("new file mode"));
    }
    #[test]
    fn numstat_handles_renames_and_binary() {
        let parsed = parse_numstat_z(
            "3\t1\tsrc/a.rs\0-\t-\timg.png\00\t0\t\0old/x.rs\0new/x.rs\0",
            true,
        );
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[2].path, "new/x.rs");
        assert_eq!(parsed[1].additions, None);
        assert_eq!(parsed[0].additions, Some(3));
    }
    #[tokio::test]
    async fn untracked_files_get_line_counts() {
        let temp = repository().await;
        let root = temp.path();
        std::fs::write(root.join("nuevo.txt"), "a\nb\nc").unwrap();
        std::fs::write(root.join("bin.dat"), [0u8, 1, 2]).unwrap();
        let stats = line_stats(root).await;
        let new = stats.iter().find(|s| s.path == "nuevo.txt").unwrap();
        assert_eq!((new.additions, new.deletions), (Some(3), Some(0)));
        assert_eq!(
            stats
                .iter()
                .find(|s| s.path == "bin.dat")
                .unwrap()
                .additions,
            None
        );
    }
    #[tokio::test]
    async fn main_protection_follows_convention_and_explicit_config() {
        let temp = repository().await;
        let root = temp.path();
        git(root, &["switch", "-q", "-c", "main"]).await.unwrap();
        git(root, &["branch", "-D", "develop"]).await.unwrap();
        std::fs::write(root.join("a.txt"), "a\n").unwrap();
        execute(root, Action::Stage, "a.txt", false).await.unwrap();
        // Unknown rule: main is not blocked, even with a develop branch.
        assert!(!main_protected(root).await);
        execute(root, Action::Commit, "feat: trabajo en main", false)
            .await
            .unwrap();
        git(root, &["branch", "develop"]).await.unwrap();
        assert!(!main_protected(root).await);
        // The provider says main is protected.
        set_remote_protection(root, "true").await.unwrap();
        assert!(main_protected(root).await);
        std::fs::write(root.join("b.txt"), "b\n").unwrap();
        execute(root, Action::Stage, "b.txt", false).await.unwrap();
        assert_eq!(
            execute(root, Action::Commit, "bloqueado", false)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
        // Fast-forward pulls stay available on protected main (here they fail only for lack of upstream).
        assert_ne!(
            execute(root, Action::Pull, "", true)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
        assert_eq!(
            execute(root, Action::PullMerge, "", true)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
        set_main_protection(root, "false").await.unwrap();
        assert!(!snapshot(root).await.unwrap().main_protected);
        execute(root, Action::Commit, "feat: permitido por config", false)
            .await
            .unwrap();
        set_main_protection(root, "auto").await.unwrap();
        assert!(snapshot(root).await.unwrap().main_protected);
        set_remote_protection(root, "false").await.unwrap();
        assert!(!main_protected(root).await);
        set_main_protection(root, "true").await.unwrap();
        assert!(
            main_protected(root).await,
            "explicit choice wins over the provider"
        );
        set_remote_protection(root, "unknown").await.unwrap();
        assert!(set_remote_protection(root, "maybe").await.is_err());
        assert!(set_main_protection(root, "maybe").await.is_err());
    }
    #[tokio::test]
    async fn pull_failures_are_classified_and_conflicts_detected() {
        let upstream = repository().await;
        let up = upstream.path();
        std::fs::write(up.join("shared.txt"), "base\n").unwrap();
        git(up, &["add", "."]).await.unwrap();
        git(up, &["commit", "-m", "base"]).await.unwrap();
        let clone = tempfile::tempdir().unwrap();
        let local = clone.path().join("local");
        git(
            clone.path(),
            &["clone", "-q", up.to_str().unwrap(), "local"],
        )
        .await
        .unwrap();
        git(&local, &["config", "user.name", "Test"]).await.unwrap();
        git(&local, &["config", "user.email", "test@example.invalid"])
            .await
            .unwrap();
        std::fs::write(up.join("shared.txt"), "remote\n").unwrap();
        git(up, &["commit", "-qam", "remote"]).await.unwrap();
        std::fs::write(local.join("shared.txt"), "local\n").unwrap();
        git(&local, &["commit", "-qam", "local"]).await.unwrap();
        assert_eq!(
            execute(&local, Action::Pull, "", false)
                .await
                .unwrap_err()
                .code,
            "confirmation_required"
        );
        assert_eq!(
            execute(&local, Action::Pull, "", true)
                .await
                .unwrap_err()
                .code,
            "pull_diverged"
        );
        assert_eq!(
            execute(&local, Action::PullMerge, "", true)
                .await
                .unwrap_err()
                .code,
            "pull_conflicts"
        );
        assert_eq!(snapshot(&local).await.unwrap().operation, "merge");
        assert_eq!(
            classify_pull_failure(
                "error: Your local changes to the following files would be overwritten by merge",
                false
            )
            .code,
            "pull_local_changes"
        );
        assert_eq!(
            classify_pull_failure("fatal: Could not read from remote repository.", false).code,
            "pull_remote_unreachable"
        );
    }
    #[tokio::test]
    async fn discard_preserves_index_and_requires_confirmation() {
        let temp = repository().await;
        let root = temp.path();
        std::fs::write(root.join("tracked.txt"), "one\n").unwrap();
        git(root, &["add", "tracked.txt"]).await.unwrap();
        git(root, &["commit", "-m", "base"]).await.unwrap();
        std::fs::write(root.join("tracked.txt"), "two\n").unwrap();
        git(root, &["add", "tracked.txt"]).await.unwrap();
        std::fs::write(root.join("tracked.txt"), "three\n").unwrap();
        std::fs::write(root.join("new.txt"), "new\n").unwrap();
        assert_eq!(
            execute(root, Action::Discard, "tracked.txt", false)
                .await
                .unwrap_err()
                .code,
            "confirmation_required"
        );
        execute(root, Action::Discard, "tracked.txt", true)
            .await
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("tracked.txt")).unwrap(),
            "two\n"
        );
        assert_eq!(
            execute(root, Action::Discard, "tracked.txt", true)
                .await
                .unwrap_err()
                .code,
            "nothing_to_discard"
        );
        execute(root, Action::Discard, "new.txt", true)
            .await
            .unwrap();
        assert!(!root.join("new.txt").exists());
        assert!(execute(root, Action::Discard, "../outside", true)
            .await
            .is_err());
        let limited = snapshot_limited(root, 1).await.unwrap();
        assert_eq!(limited.commits.len(), 1);
        for i in 0..50 {
            std::fs::write(root.join(format!("bulk {i}.txt")), "x\n").unwrap();
        }
        let bulk: Vec<String> = (0..50).map(|i| format!("bulk {i}.txt")).collect();
        assert_eq!(stage_paths(root, &bulk, false).await.unwrap(), 50);
        let staged = snapshot_with(root, 10, true).await.unwrap();
        assert_eq!(staged.files.iter().filter(|f| f.index == "A").count(), 50);
        assert!(staged
            .stats
            .unwrap()
            .iter()
            .any(|s| s.staged && s.path == "bulk 7.txt" && s.additions == Some(1)));
        stage_paths(root, &bulk, true).await.unwrap();
        assert_eq!(
            snapshot(root)
                .await
                .unwrap()
                .files
                .iter()
                .filter(|f| f.index == "?")
                .count(),
            50
        );
        assert!(stage_paths(root, &["missing.txt".into()], false)
            .await
            .is_err());
        assert!(stage_paths(root, &["../x".into()], false).await.is_err());
    }
    async fn repository() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        git(temp.path(), &["init", "-b", "develop"]).await.unwrap();
        git(temp.path(), &["config", "user.name", "Test"])
            .await
            .unwrap();
        git(
            temp.path(),
            &["config", "user.email", "test@example.invalid"],
        )
        .await
        .unwrap();
        std::fs::write(temp.path().join("base.txt"), "base\n").unwrap();
        execute(temp.path(), Action::Stage, "base.txt", false)
            .await
            .unwrap();
        execute(temp.path(), Action::Commit, "chore(test): base", false)
            .await
            .unwrap();
        temp
    }
    #[tokio::test]
    async fn rebase_conflict_is_visible_and_abort_recovers() {
        let temp = repository().await;
        let root = temp.path();
        execute(root, Action::CreateBranch, "feature/test", false)
            .await
            .unwrap();
        std::fs::write(root.join("base.txt"), "feature\n").unwrap();
        execute(root, Action::Stage, "base.txt", false)
            .await
            .unwrap();
        execute(root, Action::Commit, "feat(test): cambio feature", false)
            .await
            .unwrap();
        let before = git(root, &["rev-parse", "HEAD"]).await.unwrap();
        execute(root, Action::SwitchBranch, "develop", false)
            .await
            .unwrap();
        std::fs::write(root.join("base.txt"), "develop\n").unwrap();
        execute(root, Action::Stage, "base.txt", false)
            .await
            .unwrap();
        execute(root, Action::Commit, "feat(test): cambio develop", false)
            .await
            .unwrap();
        execute(root, Action::SwitchBranch, "feature/test", false)
            .await
            .unwrap();
        assert!(execute(root, Action::Rebase, "develop", true)
            .await
            .is_err());
        assert_eq!(snapshot(root).await.unwrap().operation, "rebase");
        execute(root, Action::RebaseAbort, "", true).await.unwrap();
        assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), before);
        assert!(snapshot(root).await.unwrap().operation.is_empty());
    }
    #[tokio::test]
    async fn push_updates_only_current_branch() {
        let temp = repository().await;
        let root = temp.path();
        let remote = tempfile::tempdir().unwrap();
        git(remote.path(), &["init", "--bare"]).await.unwrap();
        git(
            root,
            &["remote", "add", "origin", remote.path().to_str().unwrap()],
        )
        .await
        .unwrap();
        // A hazardous push configuration must not turn a develop push into a main deploy.
        git(
            root,
            &["config", "remote.origin.push", "HEAD:refs/heads/main"],
        )
        .await
        .unwrap();
        execute(root, Action::Push, "", true).await.unwrap();
        assert!(git(
            remote.path(),
            &["show-ref", "--verify", "refs/heads/develop"]
        )
        .await
        .is_ok());
        assert!(
            git(remote.path(), &["show-ref", "--verify", "refs/heads/main"])
                .await
                .is_err()
        );
    }
    #[test]
    fn repository_config_is_parsed_from_one_listing() {
        let config = parse_repository_config(
            "remote.origin.url git@github.com:a/b.git\nbutake.protectmain false\nremote.Mi.Fork.url https://x/y.git\nbutake.protectmain true\nbutake.remoteprotectmain false\n",
        );
        assert_eq!(config.protect_main, "true");
        assert_eq!(config.remote_protect_main, "false");
        assert_eq!(config.remotes, ["Mi.Fork", "origin"]);
        assert!(config.main_protected(), "explicit choice wins");
        assert!(!parse_repository_config("").main_protected());
    }
    #[tokio::test]
    async fn snapshot_reads_config_remotes_and_primary_without_extra_calls() {
        let temp = repository().await;
        let root = temp.path();
        git(root, &["branch", "master"]).await.unwrap();
        git(
            root,
            &["remote", "add", "origin", "https://example.invalid/a/b.git"],
        )
        .await
        .unwrap();
        git(
            root,
            &[
                "remote",
                "add",
                "respaldo",
                "https://example.invalid/c/d.git",
            ],
        )
        .await
        .unwrap();
        set_remote_protection(root, "true").await.unwrap();
        let state = snapshot(root).await.unwrap();
        assert_eq!(state.primary_branch, "master");
        assert_eq!(state.primary_branch, primary_branch(root).await);
        assert_eq!(state.remotes, ["origin", "respaldo"]);
        assert_eq!(state.remote, "https://example.invalid/a/b.git");
        assert!(state.main_protected);
        assert_eq!(state.main_protection, "");
        assert_eq!(state.main_protection_remote, "true");
        set_main_protection(root, "false").await.unwrap();
        let state = snapshot(root).await.unwrap();
        assert!(!state.main_protected);
        assert_eq!(state.main_protection, "false");
        std::fs::write(root.join("nuevo.txt"), "x\n").unwrap();
        let files = status(root).await.unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            (files[0].path.as_str(), files[0].index.as_str()),
            ("nuevo.txt", "?")
        );
    }
    #[test]
    fn branches_are_split_into_local_and_remote() {
        let text = "refs/heads/develop\t*\torigin/develop\tahead 2, behind 1\t1700000000\nrefs/heads/old\t \torigin/old\tgone\t1600000000\nrefs/remotes/origin/HEAD\t \t\t\t1700000000\nrefs/remotes/origin/hotfix/fit_webfleet\t \t\t\t1700000500\n";
        let (local, remote) = parse_branches(text);
        assert_eq!(local.len(), 2);
        assert!(local[0].current);
        assert_eq!((local[0].ahead, local[0].behind), (2, 1));
        assert!(local[1].gone);
        assert_eq!(remote.len(), 1);
        assert_eq!(remote[0].short, "hotfix/fit_webfleet");
        assert_eq!(remote[0].remote, "origin");
    }
    #[tokio::test]
    async fn branch_lifecycle_track_rename_delete() {
        let temp = repository().await;
        let root = temp.path();
        std::fs::write(root.join("a.txt"), "a\n").unwrap();
        execute(root, Action::Stage, "a.txt", false).await.unwrap();
        execute(root, Action::Commit, "feat: base", false)
            .await
            .unwrap();
        git(root, &["branch", "master"]).await.unwrap();
        assert_eq!(primary_branch(root).await, "master");
        git(root, &["branch", "feature/x"]).await.unwrap();
        execute(root, Action::RenameBranch, "feature/x:feature/y", false)
            .await
            .unwrap();
        assert!(execute(root, Action::RenameBranch, "master:otra", false)
            .await
            .is_err());
        assert_eq!(
            execute(root, Action::DeleteBranch, "feature/y", false)
                .await
                .unwrap_err()
                .code,
            "confirmation_required"
        );
        execute(root, Action::DeleteBranch, "feature/y", true)
            .await
            .unwrap();
        assert_eq!(
            execute(root, Action::DeleteBranch, "master", true)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
        // A branch with unique commits needs the explicit force variant.
        git(root, &["switch", "-q", "-c", "solo"]).await.unwrap();
        std::fs::write(root.join("b.txt"), "b\n").unwrap();
        execute(root, Action::Stage, "b.txt", false).await.unwrap();
        execute(root, Action::Commit, "feat: solo", false)
            .await
            .unwrap();
        git(root, &["switch", "-q", "develop"]).await.unwrap();
        assert_eq!(
            execute(root, Action::DeleteBranch, "solo", true)
                .await
                .unwrap_err()
                .code,
            "branch_not_merged"
        );
        execute(root, Action::ForceDeleteBranch, "solo", true)
            .await
            .unwrap();
        let (local, _) = parse_branches(&git(root, &["for-each-ref", "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(committerdate:unix)", "refs/heads/"]).await.unwrap());
        assert!(!local
            .iter()
            .any(|b| b.name == "solo" || b.name == "feature/y"));
    }
    #[test]
    fn clone_urls_are_restricted_to_network_transports() {
        for ok in [
            "https://github.com/a/b.git",
            "ssh://git@bitbucket.org/a/b.git",
            "git@bitbucket.org:equipo/app.git",
        ] {
            assert!(validate_clone_url(ok).is_ok(), "{ok}");
        }
        for bad in [
            "",
            "-u evil",
            "ext::sh -c touch% /tmp/x",
            "file:///etc",
            "/tmp/repo",
            "https://x/a b",
            "git@host::x",
        ] {
            assert!(validate_clone_url(bad).is_err(), "{bad}");
        }
        assert_eq!(clone_folder_name("git@bitbucket.org:equipo/app.git"), "app");
        assert_eq!(clone_folder_name("https://github.com/a/b/"), "b");
    }
    #[tokio::test]
    async fn clone_refuses_existing_folders_and_bad_names() {
        let temp = repository().await;
        let parent = temp.path();
        std::fs::create_dir(parent.join("ya")).unwrap();
        assert_eq!(
            clone(parent, "https://example.invalid/x.git", "ya")
                .await
                .unwrap_err()
                .code,
            "path_exists"
        );
        assert_eq!(
            clone(parent, "https://example.invalid/x.git", "../fuera")
                .await
                .unwrap_err()
                .code,
            "invalid_path"
        );
        assert_eq!(
            clone(parent, "ext::sh", "x").await.unwrap_err().code,
            "invalid_url"
        );
    }
    #[tokio::test]
    async fn remote_actions_explain_a_missing_remote() {
        let temp = repository().await;
        let root = temp.path();
        assert!(snapshot(root).await.unwrap().remotes.is_empty());
        for action in [Action::Fetch, Action::Pull, Action::Push] {
            assert_eq!(
                execute(root, action, "", true).await.unwrap_err().code,
                "no_remote"
            );
        }
    }
    #[tokio::test]
    async fn init_and_publish_to_a_bare_remote() {
        let temp = repository().await;
        let parent = temp.path();
        git(parent, &["config", "user.name", "QA"]).await.unwrap();
        let path = init_repository(parent, "nuevo", true).await.unwrap();
        let root = Path::new(&path);
        assert_eq!(
            git(root, &["branch", "--show-current"])
                .await
                .unwrap()
                .trim(),
            "develop"
        );
        assert_eq!(git(root, &["ls-files"]).await.unwrap().trim(), ".gitignore");
        assert!(init_repository(parent, "nuevo", true).await.is_err());
        assert!(init_repository(parent, "../fuera", true).await.is_err());
        // Publishing only accepts network transports.
        assert_eq!(
            publish(root, "/tmp/x.git", &["main".into()], false)
                .await
                .unwrap_err()
                .code,
            "invalid_url"
        );
        let denied = access_failure(error(
            "git_failed",
            "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
        ));
        assert_eq!(denied.code, "ssh_denied");
    }

    async fn sandbox() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        for args in [
            vec!["init", "-q", "-b", "develop"],
            vec!["config", "user.name", "Test"],
            vec!["config", "user.email", "t@example.invalid"],
        ] {
            git(root, &args).await.unwrap();
        }
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        git(root, &["add", "base.txt"]).await.unwrap();
        git(root, &["commit", "-qm", "chore: base"]).await.unwrap();
        temp
    }
    async fn commit_file(root: &Path, file: &str, content: &str, message: &str) -> String {
        std::fs::write(root.join(file), content).unwrap();
        git(root, &["add", file]).await.unwrap();
        git(root, &["commit", "-qm", message]).await.unwrap();
        git(root, &["rev-parse", "HEAD"])
            .await
            .unwrap()
            .trim()
            .to_string()
    }
    #[tokio::test]
    async fn background_process_left_by_a_hook_does_not_stall_the_commit() {
        use std::os::unix::fs::PermissionsExt;
        let temp = sandbox().await;
        let root = temp.path();
        let hook = root.join(".git/hooks/post-commit");
        std::fs::write(&hook, "#!/bin/sh\nsleep 30 &\n").unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(root.join("base.txt"), "changed\n").unwrap();
        git(root, &["add", "base.txt"]).await.unwrap();
        let started = std::time::Instant::now();
        execute(root, Action::Commit, "feat: with hook", false)
            .await
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(15));
        assert!(git(root, &["log", "-1", "--format=%s"])
            .await
            .unwrap()
            .contains("feat: with hook"));
    }
    #[tokio::test]
    async fn copy_commits_skips_applied_ones_and_returns_from_detached_head() {
        let temp = sandbox().await;
        let root = temp.path();
        git(root, &["branch", "other"]).await.unwrap();
        let applied = commit_file(root, "a.txt", "a\n", "feat: a").await;
        let fresh = commit_file(root, "b.txt", "b\n", "feat: b").await;
        // `other` already has the content of "feat: a".
        git(root, &["switch", "-q", "other"]).await.unwrap();
        commit_file(root, "a.txt", "a\n", "feat: a (copy)").await;
        git(root, &["switch", "-q", "--detach", "develop"])
            .await
            .unwrap();
        let head = git(root, &["rev-parse", "HEAD"]).await.unwrap();
        // Newest first, as the UI sends them.
        let copied = copy_commits(root, "other", &[fresh.clone(), applied.clone()])
            .await
            .unwrap();
        assert_eq!(copied, 1);
        assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), head);
        assert!(git(root, &["symbolic-ref", "-q", "HEAD"]).await.is_err());
        assert!(git(root, &["log", "-1", "--format=%s", "other"])
            .await
            .unwrap()
            .contains("feat: b"));
        // Nothing new at all: reported as such, and still back where it started.
        assert_eq!(
            copy_commits(root, "other", &[applied])
                .await
                .unwrap_err()
                .code,
            "copy_empty"
        );
        assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), head);
    }
    #[tokio::test]
    async fn add_add_conflicts_are_reported_as_conflicts() {
        let temp = sandbox().await;
        let root = temp.path();
        git(root, &["branch", "other"]).await.unwrap();
        let theirs = commit_file(root, "new.txt", "from develop\n", "feat: new").await;
        git(root, &["switch", "-q", "other"]).await.unwrap();
        commit_file(root, "new.txt", "from other\n", "feat: new elsewhere").await;
        git(root, &["switch", "-q", "develop"]).await.unwrap();
        assert_eq!(
            copy_commits(root, "other", &[theirs])
                .await
                .unwrap_err()
                .code,
            "copy_conflicts"
        );
        assert!(status(root).await.unwrap().iter().any(|f| f.conflicted()));
    }
    #[tokio::test]
    async fn unstage_works_before_the_first_commit_for_files_edited_after_add() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        git(root, &["init", "-q", "-b", "develop"]).await.unwrap();
        for file in ["one.txt", "dir/two.txt"] {
            std::fs::create_dir_all(root.join("dir")).unwrap();
            std::fs::write(root.join(file), "first\n").unwrap();
            git(root, &["add", file]).await.unwrap();
            std::fs::write(root.join(file), "edited after add\n").unwrap();
        }
        stage_paths(root, &["one.txt".into()], true).await.unwrap();
        execute(root, Action::Unstage, "dir/two.txt", false)
            .await
            .unwrap();
        let files = status(root).await.unwrap();
        assert!(files.iter().all(|f| f.index == "?"), "{files:?}");
        assert_eq!(
            std::fs::read_to_string(root.join("one.txt")).unwrap(),
            "edited after add\n"
        );
        // A file inside a new folder is found by the single-file action too.
        execute(root, Action::Stage, "dir/two.txt", false)
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn branch_names_cannot_be_reflog_shortcuts() {
        let temp = sandbox().await;
        let root = temp.path();
        git(root, &["branch", "main"]).await.unwrap();
        git(root, &["switch", "-q", "main"]).await.unwrap();
        git(root, &["switch", "-q", "develop"]).await.unwrap();
        assert_eq!(
            execute(root, Action::ForceDeleteBranch, "@{-1}", true)
                .await
                .unwrap_err()
                .code,
            "invalid_ref"
        );
        assert!(git(root, &["rev-parse", "--verify", "refs/heads/main"])
            .await
            .is_ok());
    }
    #[tokio::test]
    async fn diff_keeps_prefixes_and_shows_other_encodings() {
        let temp = sandbox().await;
        let root = temp.path();
        git(root, &["config", "diff.noprefix", "true"])
            .await
            .unwrap();
        std::fs::write(root.join("latin.txt"), b"a\xf1o\n").unwrap();
        git(root, &["add", "latin.txt"]).await.unwrap();
        git(root, &["commit", "-qm", "latin"]).await.unwrap();
        std::fs::write(root.join("latin.txt"), b"a\xf1o nuevo\n").unwrap();
        let text = diff(root, "latin.txt", false).await.unwrap();
        assert!(text.contains("--- a/latin.txt") && text.contains("+++ b/latin.txt"));
        assert!(text.contains("nuevo"));
    }
    #[tokio::test]
    async fn console_runner_keeps_globs_and_returns_stderr() {
        let temp = sandbox().await;
        let root = temp.path();
        std::fs::write(root.join("one.rs"), "fn main() {}\n").unwrap();
        git_console(root, &["add", "*.rs"]).await.unwrap();
        assert_eq!(status(root).await.unwrap()[0].index, "A");
        let output = git_console(root, &["switch", "-c", "feature/console"])
            .await
            .unwrap();
        assert!(output.contains("feature/console"), "{output}");
    }
}
