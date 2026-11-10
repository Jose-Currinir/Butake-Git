use crate::git::{self, error, Result};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    io::{Read, Write},
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tokio::sync::OwnedMutexGuard;

static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);
pub type SessionState = Arc<Mutex<Option<TerminalSession>>>;

pub struct TerminalSession {
    id: u64,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
}
impl Drop for TerminalSession {
    fn drop(&mut self) {
        let _ = self.killer.kill();
    }
}

#[derive(Clone, Serialize, Debug)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TerminalEvent {
    Output { data: Vec<u8> },
    Exit { code: u32 },
    Error { message: String },
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandCapability {
    pub name: String,
    pub available: bool,
    pub library: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub version: String,
    pub commands: Vec<CommandCapability>,
}
#[derive(Deserialize)]
pub struct Catalog {
    pub commands: Vec<CatalogCommand>,
}
#[derive(Deserialize)]
pub struct CatalogCommand {
    pub name: String,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct RebaseStep {
    pub hash: String,
    pub action: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RebasePlan {
    pub head: String,
    pub base: String,
    pub steps: Vec<RebaseStep>,
}
#[derive(Serialize)]
pub struct RebaseCandidates {
    pub head: String,
    pub base: String,
    pub commits: Vec<RebaseCommit>,
}
#[derive(Serialize)]
pub struct RebaseCommit {
    pub hash: String,
    pub subject: String,
}
#[derive(Clone, Serialize)]
pub struct PreparedCommand {
    pub command: String,
    pub args: Vec<String>,
    pub preview: String,
}

pub fn command_names() -> Vec<String> {
    let catalog: Catalog = serde_json::from_str(include_str!(
        "../../native/Sources/ButakeGit/Resources/commands.json"
    ))
    .expect("valid Git catalog");
    catalog.commands.into_iter().map(|c| c.name).collect()
}
fn known(name: &str) -> Result<()> {
    if command_names().iter().any(|n| n == name) {
        Ok(())
    } else {
        Err(error(
            "unknown_command",
            "Selecciona un comando del diccionario.",
        ))
    }
}
fn library(name: &str) -> bool {
    matches!(name, "sh-i18n" | "sh-setup" | "gitweb")
}
fn executable_exists(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}
fn program_on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| executable_exists(&d.join(name))))
        .unwrap_or(false)
}
pub async fn capabilities() -> Result<Capabilities> {
    let cwd = std::env::temp_dir();
    let builtins = git::git(&cwd, &["--list-cmds=builtins"]).await?;
    let builtin: HashSet<_> = builtins.lines().collect();
    let exec = git::git(&cwd, &["--exec-path"]).await?;
    let commands = command_names()
        .into_iter()
        .map(|name| {
            let lib = library(&name);
            let available = !lib
                && (builtin.contains(name.as_str())
                    || executable_exists(&Path::new(exec.trim()).join(format!("git-{name}")))
                    || (name == "gitk" && program_on_path("gitk"))
                    || program_on_path(&format!("git-{name}")));
            CommandCapability {
                name,
                available,
                library: lib,
            }
        })
        .collect();
    Ok(Capabilities {
        version: git::git(&cwd, &["--version"]).await?.trim().into(),
        commands,
    })
}

pub async fn command_help(name: &str) -> Result<String> {
    known(name)?;
    let mut command = tokio::process::Command::new("git");
    command
        .args(["--no-pager", "help", "--man", name])
        .env("MANPAGER", "cat")
        .env("PAGER", "cat")
        .env("MAN_KEEP_FORMATTING", "0")
        .kill_on_drop(true);
    let output = tokio::time::timeout(std::time::Duration::from_secs(15), command.output())
        .await
        .map_err(|_| error("timeout", "La ayuda tardó demasiado."))?
        .map_err(|e| error("git_unavailable", e.to_string()))?;
    if !output.status.success() {
        return Err(error(
            "help_unavailable",
            "Manual local no instalado; consulta el enlace oficial del diccionario.",
        ));
    }
    // Remove overstrikes produced by man while preserving the manual's contents.
    let mut text = String::new();
    for c in String::from_utf8_lossy(&output.stdout).chars() {
        if c == '\u{8}' {
            text.pop();
        } else {
            text.push(c);
        }
    }
    Ok(text)
}

fn explicitly_protected_ref(value: &str, primary: &str) -> bool {
    value == primary
        || value == format!("refs/heads/{primary}")
        || value.starts_with(&format!("{primary}:"))
        || value.ends_with(&format!(":{primary}"))
        || value.ends_with(&format!(":refs/heads/{primary}"))
}
fn read_command(command: &str) -> bool {
    matches!(
        command,
        "status"
            | "log"
            | "show"
            | "diff"
            | "blame"
            | "annotate"
            | "grep"
            | "shortlog"
            | "describe"
            | "range-diff"
            | "show-branch"
            | "version"
            | "help"
            | "ls-files"
            | "ls-tree"
            | "ls-remote"
            | "show-ref"
            | "rev-parse"
            | "rev-list"
            | "merge-base"
            | "cat-file"
            | "cherry"
            | "count-objects"
            | "check-attr"
            | "check-ignore"
            | "check-mailmap"
            | "check-ref-format"
            | "for-each-ref"
            | "name-rev"
            | "verify-commit"
            | "verify-tag"
            | "verify-pack"
            | "diff-files"
            | "diff-index"
            | "diff-tree"
            | "diff-pairs"
            | "repo"
            | "last-modified"
            | "whatchanged"
    )
}

pub fn prepare(
    command: &str,
    arguments: &str,
    current_branch: &str,
    primary: &str,
    main_protected: bool,
) -> Result<PreparedCommand> {
    known(command)?;
    if library(command) {
        return Err(error("library_command", "Esta entrada documenta una biblioteca o componente servidor; no es una acción CLI autónoma."));
    }
    let args = shell_words::split(arguments).map_err(|_| {
        error(
            "invalid_arguments",
            "Hay comillas sin cerrar en los argumentos.",
        )
    })?;
    if args.len() > 256 || arguments.len() > 32_768 || args.iter().any(|a| a.contains('\0')) {
        return Err(error(
            "invalid_arguments",
            "Argumentos fuera del límite permitido.",
        ));
    }
    let reads = read_command(command)
        || match command {
            "branch" => {
                args.is_empty()
                    || args.iter().all(|a| {
                        matches!(
                            a.as_str(),
                            "--list"
                                | "-l"
                                | "-a"
                                | "--all"
                                | "-r"
                                | "--remotes"
                                | "-v"
                                | "-vv"
                                | "--show-current"
                        ) || a.starts_with("--format=")
                    })
            }
            "tag" => args.first().is_some_and(|a| a == "--list" || a == "-l"),
            "stash" => args.first().is_some_and(|a| a == "list" || a == "show"),
            "worktree" => args.first().is_some_and(|a| a == "list"),
            "remote" => {
                args.is_empty()
                    || args.first().is_some_and(|a| {
                        matches!(a.as_str(), "-v" | "--verbose" | "show" | "get-url")
                    })
            }
            "reflog" => {
                args.is_empty()
                    || args
                        .first()
                        .is_some_and(|a| a == "show" || a == "list" || a.starts_with("--format="))
            }
            "config" => args.first().is_some_and(|a| {
                matches!(
                    a.as_str(),
                    "get" | "list" | "--get" | "--get-all" | "--get-regexp" | "--list"
                )
            }),
            _ => false,
        };
    if !reads && main_protected && current_branch == primary {
        return Err(error(
            "protected_branch",
            "main está protegida. Cambia a develop o una rama de trabajo.",
        ));
    }
    if !reads
        && ((matches!(
            command,
            "branch"
                | "update-ref"
                | "symbolic-ref"
                | "refs"
                | "history"
                | "replay"
                | "filter-branch"
                | "push"
                | "send-pack"
                | "fetch"
        ) && main_protected
            && args.iter().any(|a| explicitly_protected_ref(a, primary)))
            || (matches!(
                command,
                "branch" | "filter-branch" | "history" | "push" | "send-pack"
            ) && args.iter().any(|a| a == "--mirror" || a == "--all")))
    {
        return Err(error(
            "protected_branch",
            "No se permite modificar main ni múltiples referencias implícitas desde la consola.",
        ));
    }
    // These modes can write refs received later through stdin, beyond the visible preview.
    if matches!(
        command,
        "update-ref" | "symbolic-ref" | "fast-import" | "receive-pack"
    ) && (args.iter().any(|a| a == "--stdin") || command == "fast-import")
    {
        return Err(error("protected_branch", "Este modo admite referencias por stdin y requiere una herramienta externa con revisión explícita de main."));
    }
    if matches!(command, "push" | "send-pack") {
        if args.iter().any(|a| {
            a == "--force"
                || a == "-f"
                || a.starts_with("--force-with-lease")
                || a.starts_with('+')
                || a.contains('*')
                || a == "--delete"
                || a == "-d"
                || a == "--tags"
                || a == "--follow-tags"
                || a.starts_with("--repo")
                || a.starts_with("--recurse-submodules")
        }) {
            return Err(error(
                "protected_branch",
                "Force-push y publicación masiva no están habilitados en esta versión.",
            ));
        }
        // Require an explicit, reviewed destination; ignore remote.push and push.default.
        let operands: Vec<_> = args.iter().filter(|a| !a.starts_with('-')).collect();
        if operands.len() != 2
            || args.iter().any(|a| {
                a.starts_with('-')
                    && !matches!(
                        a.as_str(),
                        "-u" | "--set-upstream" | "--dry-run" | "--porcelain" | "--verbose"
                    )
            })
        {
            return Err(error(
                "explicit_push_required",
                "Usa destino y refspec explícitos: origin refs/heads/develop:refs/heads/develop.",
            ));
        }
        let refs: Vec<_> = operands[1].split(':').collect();
        if refs.len() != 2
            || refs
                .iter()
                .any(|r| r.is_empty() || !r.starts_with("refs/heads/") || r.ends_with("/main"))
        {
            return Err(error(
                "explicit_push_required",
                "Push requiere origen y destino explícitos en refs/heads/, sin main.",
            ));
        }
    }
    if command == "remote" && args.first().is_some_and(|a| a == "update") {
        return Err(error(
            "explicit_remote_required",
            "Usa fetch con remoto explícito para revisar el destino.",
        ));
    }
    let mut argv = vec![command.to_string()];
    argv.extend(args.clone());
    Ok(PreparedCommand {
        command: command.into(),
        args,
        preview: format!("git {}", shell_words::join(argv)),
    })
}

pub async fn rebase_candidates(root: &Path, base: &str) -> Result<RebaseCandidates> {
    if base.is_empty() || base.starts_with('-') {
        return Err(error("invalid_ref", "Elige una base válida."));
    }
    let base = git::git(
        root,
        &[
            "rev-parse",
            "--verify",
            "--end-of-options",
            &format!("{base}^{{commit}}"),
        ],
    )
    .await?
    .trim()
    .to_string();
    let head = git::git(root, &["rev-parse", "--verify", "HEAD"])
        .await?
        .trim()
        .to_string();
    let range = format!("{base}..{head}");
    let merges = git::git(root, &["rev-list", "--merges", &range]).await?;
    if !merges.trim().is_empty() {
        return Err(error("merge_plan", "Este plan incluye merges. Usa rebase --rebase-merges en la consola interactiva para preservarlos."));
    }
    let raw = git::git(
        root,
        &[
            "log",
            "--reverse",
            "--topo-order",
            "--format=%H%x1f%s",
            &range,
        ],
    )
    .await?;
    let commits = raw
        .lines()
        .filter_map(|line| {
            line.split_once('\x1f').map(|(hash, subject)| RebaseCommit {
                hash: hash.into(),
                subject: subject.into(),
            })
        })
        .collect();
    Ok(RebaseCandidates {
        head,
        base,
        commits,
    })
}
pub async fn validate_rebase(root: &Path, plan: &RebasePlan) -> Result<String> {
    let state = git::snapshot(root).await?;
    if (state.branch == state.primary_branch && state.main_protected) || state.branch == "HEAD" {
        return Err(error(
            "protected_branch",
            "Rebase visual requiere una rama de trabajo activa.",
        ));
    }
    if !state.files.is_empty() || !state.operation.is_empty() {
        return Err(error(
            "dirty_rebase",
            "Guarda o confirma cambios y termina la operación actual antes del rebase.",
        ));
    }
    let current = rebase_candidates(root, &plan.base).await?;
    if current.head != plan.head || current.base != plan.base {
        return Err(error(
            "stale_plan",
            "El historial cambió. Vuelve a cargar el plan.",
        ));
    }
    let expected: HashSet<_> = current.commits.iter().map(|c| c.hash.as_str()).collect();
    let supplied: HashSet<_> = plan.steps.iter().map(|s| s.hash.as_str()).collect();
    if plan.steps.is_empty() || plan.steps.len() != expected.len() || supplied != expected {
        return Err(error(
            "invalid_plan",
            "El plan debe contener cada commit original exactamente una vez.",
        ));
    }
    let mut previous = false;
    let mut lines = Vec::new();
    for step in &plan.steps {
        if !matches!(
            step.action.as_str(),
            "pick" | "reword" | "edit" | "squash" | "fixup" | "drop"
        ) {
            return Err(error("invalid_plan", "Acción de rebase no permitida."));
        }
        if matches!(step.action.as_str(), "squash" | "fixup") && !previous {
            return Err(error(
                "invalid_plan",
                "Squash/fixup necesitan un commit previo que se conserve.",
            ));
        }
        if step.action != "drop" {
            previous = true;
        }
        lines.push(format!("{} {}", step.action, step.hash));
    }
    Ok(lines.join("\n") + "\n")
}

pub fn start_session(
    root: &Path,
    command: &PreparedCommand,
    plan: Option<&str>,
    state: SessionState,
    guard: OwnedMutexGuard<()>,
    sink: Arc<dyn Fn(TerminalEvent) + Send + Sync>,
) -> Result<u64> {
    let pty = native_pty_system()
        .openpty(PtySize {
            rows: 28,
            cols: 100,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| error("pty_failed", e.to_string()))?;
    let mut cmd = CommandBuilder::new(if command.command == "gitk" {
        "gitk"
    } else {
        "git"
    });
    if command.command != "gitk" {
        cmd.arg("--no-pager");
        cmd.arg(&command.command);
    }
    cmd.args(&command.args);
    cmd.cwd(root);
    cmd.env("TERM", "xterm-256color");
    cmd.env("GIT_PAGER", "cat");
    // Match GUI behavior for configured hooks and credential helpers. Interactive editors keep a TTY.
    cmd.env("GIT_TERMINAL_PROMPT", "1");
    let plan_directory = if let Some(content) = plan {
        let dir = tempfile::tempdir().map_err(|e| error("plan_file", e.to_string()))?;
        let path = dir.path().join("todo");
        std::fs::write(&path, content).map_err(|e| error("plan_file", e.to_string()))?;
        let executable = std::env::current_exe().map_err(|e| error("plan_file", e.to_string()))?;
        cmd.env(
            "GIT_SEQUENCE_EDITOR",
            format!(
                "{} --butake-write-plan {}",
                shell_words::quote(&executable.to_string_lossy()),
                shell_words::quote(&path.to_string_lossy())
            ),
        );
        Some(dir)
    } else {
        None
    };
    let mut child = pty
        .slave
        .spawn_command(cmd)
        .map_err(|e| error("pty_failed", e.to_string()))?;
    drop(pty.slave);
    let id = NEXT_SESSION.fetch_add(1, Ordering::Relaxed);
    let killer = child.clone_killer();
    let mut reader = pty
        .master
        .try_clone_reader()
        .map_err(|e| error("pty_failed", e.to_string()))?;
    let writer = pty
        .master
        .take_writer()
        .map_err(|e| error("pty_failed", e.to_string()))?;
    *state
        .lock()
        .map_err(|_| error("session_failed", "Estado de terminal no disponible."))? =
        Some(TerminalSession {
            id,
            writer,
            master: pty.master,
            killer,
        });
    let output = sink.clone();
    let reader_thread = std::thread::spawn(move || {
        let mut buffer = [0u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => output(TerminalEvent::Output {
                    data: buffer[..count].to_vec(),
                }),
                Err(_) => break,
            }
        }
    });
    std::thread::spawn(move || {
        let result = child.wait();
        let _ = reader_thread.join();
        if let Ok(mut active) = state.lock() {
            if active.as_ref().is_some_and(|s| s.id == id) {
                active.take();
            }
        }
        drop(plan_directory);
        drop(guard);
        match result {
            Ok(status) => sink(TerminalEvent::Exit {
                code: status.exit_code(),
            }),
            Err(e) => sink(TerminalEvent::Error {
                message: e.to_string(),
            }),
        }
    });
    Ok(id)
}
pub fn input(state: &SessionState, id: u64, input: &str) -> Result<()> {
    let mut active = state
        .lock()
        .map_err(|_| error("session_failed", "Terminal no disponible."))?;
    let session = active
        .as_mut()
        .filter(|s| s.id == id)
        .ok_or_else(|| error("session_ended", "La sesión ya terminó."))?;
    session
        .writer
        .write_all(input.as_bytes())
        .and_then(|_| session.writer.flush())
        .map_err(|e| error("session_failed", e.to_string()))
}
pub fn resize(state: &SessionState, id: u64, cols: u16, rows: u16) -> Result<()> {
    let active = state
        .lock()
        .map_err(|_| error("session_failed", "Terminal no disponible."))?;
    let session = active
        .as_ref()
        .filter(|s| s.id == id)
        .ok_or_else(|| error("session_ended", "La sesión ya terminó."))?;
    session
        .master
        .resize(PtySize {
            rows: rows.clamp(5, 300),
            cols: cols.clamp(20, 500),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| error("session_failed", e.to_string()))
}
pub fn cancel(state: &SessionState, id: u64) -> Result<()> {
    let mut active = state
        .lock()
        .map_err(|_| error("session_failed", "Terminal no disponible."))?;
    if let Some(session) = active.as_mut().filter(|s| s.id == id) {
        session
            .killer
            .kill()
            .map_err(|e| error("session_failed", e.to_string()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy_preserves_main_without_blocking_rebase_base() {
        assert!(prepare("commit", "-m test", "main", "main", true).is_err());
        assert!(prepare("log", "--all --oneline", "main", "main", true).is_ok());
        assert!(prepare("branch", "--list", "main", "main", true).is_ok());
        assert!(prepare("rebase", "main", "feature/test", "main", true).is_ok());
        assert!(prepare("branch", "-D main", "develop", "main", true).is_err());
        assert!(prepare("update-ref", "--stdin", "develop", "main", true).is_err());
        // Unprotected repositories may work on main; force and mass push stay blocked.
        assert!(prepare("commit", "-m test", "main", "main", false).is_ok());
        assert!(prepare("branch", "-D main", "develop", "main", false).is_ok());
        assert!(prepare("push", "--force origin main:main", "main", "main", false).is_err());
        // Repositories on master protect master, not a missing main.
        assert!(prepare("commit", "-m test", "master", "master", true).is_err());
        assert!(prepare("branch", "-D master", "develop", "master", true).is_err());
        assert!(prepare("commit", "-m test", "main", "master", true).is_ok());
    }
    #[test]
    fn push_requires_exact_destination_and_no_force() {
        assert!(prepare(
            "push",
            "origin refs/heads/develop:refs/heads/develop",
            "develop",
            "main",
            true
        )
        .is_ok());
        for args in [
            "",
            "origin",
            "origin develop",
            "origin refs/heads/develop:refs/heads/main",
            "--mirror origin",
            "--force origin refs/heads/develop:refs/heads/develop",
        ] {
            assert!(
                prepare("push", args, "develop", "main", true).is_err(),
                "{args}"
            );
        }
    }
    #[test]
    fn command_arguments_are_tokens_not_shell() {
        let command =
            prepare("grep", "'$(touch /tmp/never-run)'", "develop", "main", true).unwrap();
        assert_eq!(command.args, ["$(touch /tmp/never-run)"]);
        assert!(prepare("bash", "-c whoami", "develop", "main", true).is_err());
        assert!(prepare("status", "'broken", "develop", "main", true).is_err());
    }
}
