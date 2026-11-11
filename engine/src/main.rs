mod editing;
#[allow(dead_code)]
mod git;
mod rewrite;
#[allow(dead_code)]
mod terminal;
mod workspace;
use serde_json::{json, Value};
use std::{io::Read, path::Path};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|a| a == "--butake-write-plan") {
        std::process::exit(
            if args.len() == 4 && std::fs::copy(&args[2], &args[3]).is_ok() {
                0
            } else {
                1
            },
        );
    }
    if args.get(1).is_some_and(|a| a == "--terminal") {
        let result = run_terminal(&args).await;
        if let Err(e) = result {
            eprintln!("{}", e.detail);
            std::process::exit(1);
        }
        return;
    }
    let mut input = String::new();
    let result = match std::io::stdin().take(16_000_000).read_to_string(&mut input) {
        Ok(_) => match serde_json::from_str::<Value>(&input) {
            Ok(request) => dispatch(request).await,
            Err(e) => Err(git::error("invalid_request", e.to_string())),
        },
        Err(e) => Err(git::error("invalid_request", e.to_string())),
    };
    let response = match result {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(e) => json!({ "ok": false, "error": e }),
    };
    println!("{}", response);
}
fn string<'a>(request: &'a Value, key: &str) -> &'a str {
    request[key].as_str().unwrap_or("")
}
fn limit(request: &Value) -> usize {
    request["limit"]
        .as_u64()
        .map(|value| value as usize)
        .unwrap_or(git::DEFAULT_HISTORY_LIMIT)
}
async fn dispatch(r: Value) -> git::Result<Value> {
    let method = string(&r, "method");
    match method {
        "capabilities" => return Ok(json!(terminal::capabilities().await?)),
        "help" => return Ok(json!(terminal::command_help(string(&r, "command")).await?)),
        _ => {}
    }
    let root = Path::new(string(&r, "path"))
        .canonicalize()
        .map_err(|e| git::error("invalid_path", e.to_string()))?;
    if !root.is_dir() {
        return Err(git::error("invalid_path", "Selecciona una carpeta."));
    }
    match method {
        // `path` is the parent folder chosen by the user.
        "clone" => Ok(json!(
            git::clone(&root, string(&r, "url"), string(&r, "name")).await?
        )),
        "cloneName" => Ok(json!(git::clone_folder_name(string(&r, "url")))),
        // `path` is the parent folder chosen by the user.
        "init" => Ok(json!(
            git::init_repository(
                &root,
                string(&r, "name"),
                r["develop"].as_bool().unwrap_or(true)
            )
            .await?
        )),
        "publish" => {
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma la publicación.",
                ));
            }
            let branches: Vec<String> =
                serde_json::from_value(r["branches"].clone()).unwrap_or_default();
            Ok(json!(
                git::publish(
                    &root,
                    string(&r, "url"),
                    &branches,
                    r["replaceOrigin"] == true
                )
                .await?
            ))
        }
        "open" => Ok(json!(
            git::snapshot_with(
                &git::open_root(&root.to_string_lossy()).await?,
                limit(&r),
                r["stats"].as_bool().unwrap_or(false)
            )
            .await?
        )),
        "snapshot" => Ok(json!(
            git::snapshot_with(&root, limit(&r), r["stats"].as_bool().unwrap_or(false)).await?
        )),
        "status" => Ok(json!(git::status(&root).await?)),
        "stats" => Ok(json!(git::line_stats(&root).await)),
        "rewriteCandidates" => Ok(json!(rewrite::candidates(&root).await?)),
        "rewriteApply" => {
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma la reorganización.",
                ));
            }
            let plan: rewrite::RewritePlan = serde_json::from_value(r["plan"].clone())
                .map_err(|_| git::error("invalid_plan", "Plan inválido."))?;
            Ok(json!(rewrite::apply(&root, &plan).await?))
        }
        "rewriteUndo" => {
            if r["confirmed"] != true {
                return Err(git::error("confirmation_required", "Confirma deshacer."));
            }
            Ok(json!(rewrite::undo(&root, string(&r, "backup")).await?))
        }
        "branchSync" => Ok(json!(
            git::branch_sync(&root, string(&r, "left"), string(&r, "right")).await?
        )),
        "copyCommits" => {
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma la copia de commits.",
                ));
            }
            let hashes: Vec<String> = serde_json::from_value(r["hashes"].clone())
                .map_err(|_| git::error("invalid_arguments", "Lista de commits inválida."))?;
            Ok(json!(
                git::copy_commits(&root, string(&r, "target"), &hashes).await?
            ))
        }
        "setRemoteProtection" => Ok(json!(
            git::set_remote_protection(&root, string(&r, "value")).await?
        )),
        "setMainProtection" => {
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma el cambio de protección.",
                ));
            }
            Ok(json!(
                git::set_main_protection(&root, string(&r, "value")).await?
            ))
        }
        "stagePaths" => {
            let paths: Vec<String> = serde_json::from_value(r["paths"].clone())
                .map_err(|_| git::error("invalid_arguments", "Lista de archivos inválida."))?;
            Ok(json!(
                git::stage_paths(&root, &paths, r["staged"].as_bool().unwrap_or(false)).await?
            ))
        }
        "branchDetails" => {
            workspace::branch_details(&root, string(&r, "branch"), string(&r, "base")).await
        }
        "branchDiff" => Ok(json!(
            workspace::branch_diff(
                &root,
                string(&r, "head"),
                string(&r, "base"),
                string(&r, "file")
            )
            .await?
        )),
        "files" => Ok(json!(git::git(
            &root,
            &[
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z"
            ]
        )
        .await?
        .split('\0')
        .filter(|p| !p.is_empty())
        .collect::<std::collections::BTreeSet<_>>())),
        "previewFile" => Ok(json!(
            workspace::preview_file(string(&r, "expected"), string(&r, "content")).await?
        )),
        "readFile" => workspace::read_file(&root, string(&r, "file")).await,
        "saveFile" => {
            if r["confirmed"] != true {
                return Err(git::error("confirmation_required", "Confirma el guardado."));
            }
            workspace::save_file(
                &root,
                string(&r, "file"),
                string(&r, "content"),
                string(&r, "expected"),
                string(&r, "head"),
                string(&r, "branch"),
            )
            .await?;
            Ok(json!("ok"))
        }
        "diff" => Ok(json!(
            git::diff(
                &root,
                string(&r, "file"),
                r["staged"].as_bool().unwrap_or(false)
            )
            .await?
        )),
        "action" => {
            let action: git::Action = serde_json::from_value(r["action"].clone())
                .map_err(|_| git::error("unknown_action", "Acción desconocida."))?;
            Ok(json!(
                git::execute(
                    &root,
                    action,
                    string(&r, "value"),
                    r["confirmed"].as_bool().unwrap_or(false)
                )
                .await?
            ))
        }
        "prepare" | "run" => {
            let branch = git::git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
                .await
                .unwrap_or_default();
            let prepared = terminal::prepare(
                string(&r, "command"),
                string(&r, "arguments"),
                branch.trim(),
                &git::primary_branch(&root).await,
                git::main_protected(&root).await,
            )?;
            if method == "prepare" {
                return Ok(json!(prepared));
            }
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma el comando exacto.",
                ));
            }
            let mut args = vec![prepared.command.as_str()];
            args.extend(prepared.args.iter().map(String::as_str));
            Ok(json!(git::git(&root, &args).await?))
        }
        "query" => {
            let args: Vec<String> = serde_json::from_value(r["args"].clone())
                .map_err(|_| git::error("invalid_arguments", "Consulta inválida."))?;
            let command = args.first().map(String::as_str).unwrap_or("");
            if !matches!(
                command,
                "worktree"
                    | "tag"
                    | "stash"
                    | "remote"
                    | "reflog"
                    | "show"
                    | "log"
                    | "diff"
                    | "ls-files"
                    | "config"
            ) {
                return Err(git::error("invalid_query", "Consulta desconocida."));
            }
            if !matches!(command, "show" | "log" | "diff" | "ls-files" | "reflog")
                && !matches!(
                    args.get(1).map(String::as_str),
                    Some("list" | "--list" | "-v" | "--get" | "get")
                )
            {
                return Err(git::error(
                    "invalid_query",
                    "Esta operación requiere confirmación.",
                ));
            }
            Ok(json!(
                git::git(&root, &args.iter().map(String::as_str).collect::<Vec<_>>()).await?
            ))
        }
        "rebaseCandidates" => Ok(json!(
            terminal::rebase_candidates(&root, string(&r, "base")).await?
        )),
        "validateRebase" => {
            let plan = serde_json::from_value(r["plan"].clone())
                .map_err(|_| git::error("invalid_plan", "Plan inválido."))?;
            Ok(json!(terminal::validate_rebase(&root, &plan).await?))
        }
        "stageHunk" => {
            editing::stage_hunk(
                &root,
                string(&r, "file"),
                r["staged"].as_bool().unwrap_or(false),
                r["index"].as_u64().unwrap_or(0) as usize,
            )
            .await?;
            Ok(json!("ok"))
        }
        "conflict" => Ok(json!(editing::conflict(&root, string(&r, "file")).await?)),
        "resolveConflict" => {
            if r["confirmed"] != true {
                return Err(git::error(
                    "confirmation_required",
                    "Confirma la resolución.",
                ));
            }
            editing::resolve(
                &root,
                string(&r, "file"),
                string(&r, "content"),
                string(&r, "expected"),
            )
            .await?;
            Ok(json!("ok"))
        }
        "pullRequestUrl" => {
            let remote = git::git(&root, &["remote", "get-url", "origin"]).await?;
            Ok(json!(git::pull_request_url(remote.trim())?))
        }
        _ => Err(git::error("unknown_method", "Operación desconocida.")),
    }
}
async fn run_terminal(args: &[String]) -> git::Result<()> {
    if args.len() < 5 {
        return Err(git::error(
            "invalid_arguments",
            "Faltan argumentos de terminal.",
        ));
    }
    let root = Path::new(&args[2])
        .canonicalize()
        .map_err(|e| git::error("invalid_path", e.to_string()))?;
    let branch = git::git(&root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default();
    let prepared = terminal::prepare(
        &args[3],
        &args[4],
        branch.trim(),
        &git::primary_branch(&root).await,
        git::main_protected(&root).await,
    )?;
    let mut process = std::process::Command::new(if prepared.command == "gitk" {
        "gitk"
    } else {
        "git"
    });
    if prepared.command != "gitk" {
        process.arg("--no-pager").arg(&prepared.command);
    }
    process
        .args(&prepared.args)
        .current_dir(&root)
        .env("GIT_PAGER", "cat")
        .env("TERM", "xterm-256color");
    let mut plan_file = None;
    if let Some(plan) = args.get(5) {
        if prepared.command != "rebase" {
            return Err(git::error("invalid_plan", "El plan solo aplica a rebase."));
        }
        let plan: terminal::RebasePlan =
            serde_json::from_str(plan).map_err(|_| git::error("invalid_plan", "Plan inválido."))?;
        let content = terminal::validate_rebase(&root, &plan).await?;
        if prepared.args
            != [
                "--interactive",
                "--reapply-cherry-picks",
                "--keep-empty",
                &plan.base,
            ]
            .map(String::from)
        {
            return Err(git::error(
                "invalid_plan",
                "La base del comando difiere del plan validado.",
            ));
        }
        let dir = tempfile::tempdir().map_err(|e| git::error("plan_file", e.to_string()))?;
        let path = dir.path().join("todo");
        std::fs::write(&path, content).map_err(|e| git::error("plan_file", e.to_string()))?;
        let executable =
            std::env::current_exe().map_err(|e| git::error("plan_file", e.to_string()))?;
        process.env(
            "GIT_SEQUENCE_EDITOR",
            format!(
                "{} --butake-write-plan {}",
                shell_words::quote(&executable.to_string_lossy()),
                shell_words::quote(&path.to_string_lossy())
            ),
        );
        plan_file = Some(dir);
    }
    let status = process
        .status()
        .map_err(|e| git::error("git_failed", e.to_string()))?;
    drop(plan_file);
    std::process::exit(status.code().unwrap_or(1));
}
