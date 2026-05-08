//! `eavd` — the Emacs Agenda Viewer daemon binary.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use chrono::NaiveDate;
use eav_agenda::{evaluate_day, evaluate_range, AgendaConfig};
use eav_bridge::{BridgeClient, Event as BridgeEvent};
use eav_core::{OrgTask, TodoKeywords};
use eav_index::{FileChange, FileWatcher, Index, Snapshot};
use eav_parse::GlobalKeywords;
use eav_server::{build_router, AppState, ServerEvent};
use std::collections::HashSet;
use std::sync::Arc;

#[tokio::main]
async fn main() -> ExitCode {
    init_tracing();

    let mut args = env::args().skip(1);
    let mut mode = Mode::Server;
    let mut files: Vec<PathBuf> = Vec::new();
    let mut globals: Option<GlobalKeywords> = None;
    let mut http_port: Option<u16> = None;
    let mut static_dir: Option<PathBuf> = None;
    let mut http_host: Option<String> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dump-tasks" => mode = Mode::DumpTasks { active_only: false },
            "--dump-active-tasks" => mode = Mode::DumpTasks { active_only: true },
            "--dump-agenda-day" => {
                let date = match args.next() {
                    Some(d) => d,
                    None => {
                        eprintln!("--dump-agenda-day requires YYYY-MM-DD");
                        return ExitCode::FAILURE;
                    }
                };
                mode = Mode::DumpAgendaDay { date };
            }
            "--dump-agenda-range" => {
                let start = match args.next() {
                    Some(d) => d,
                    None => {
                        eprintln!("--dump-agenda-range requires START END");
                        return ExitCode::FAILURE;
                    }
                };
                let end = match args.next() {
                    Some(d) => d,
                    None => {
                        eprintln!("--dump-agenda-range requires START END");
                        return ExitCode::FAILURE;
                    }
                };
                mode = Mode::DumpAgendaRange { start, end };
            }
            "--keywords-from" => {
                let path = match args.next() {
                    Some(p) => p,
                    None => {
                        eprintln!("--keywords-from requires a path");
                        return ExitCode::FAILURE;
                    }
                };
                match parse_keywords_file(&path) {
                    Ok(g) => globals = Some(g),
                    Err(e) => {
                        eprintln!("--keywords-from {path}: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }
            "--files-from" => {
                let path = match args.next() {
                    Some(p) => p,
                    None => {
                        eprintln!("--files-from requires a path");
                        return ExitCode::FAILURE;
                    }
                };
                match parse_files_list(&path) {
                    Ok(more) => files.extend(more),
                    Err(e) => {
                        eprintln!("--files-from {path}: {e}");
                        return ExitCode::FAILURE;
                    }
                }
            }
            "--http-port" => {
                let val = match args.next() {
                    Some(v) => v,
                    None => {
                        eprintln!("--http-port requires a number");
                        return ExitCode::FAILURE;
                    }
                };
                match val.parse::<u16>() {
                    Ok(p) => http_port = Some(p),
                    Err(_) => {
                        eprintln!("--http-port: invalid port {val}");
                        return ExitCode::FAILURE;
                    }
                }
            }
            "--http-host" => {
                let val = match args.next() {
                    Some(v) => v,
                    None => {
                        eprintln!("--http-host requires an IP/hostname");
                        return ExitCode::FAILURE;
                    }
                };
                http_host = Some(val);
            }
            "--static-dir" => {
                let val = match args.next() {
                    Some(v) => v,
                    None => {
                        eprintln!("--static-dir requires a path");
                        return ExitCode::FAILURE;
                    }
                };
                static_dir = Some(PathBuf::from(val));
            }
            "--help" | "-h" => {
                print_help();
                return ExitCode::SUCCESS;
            }
            other if other.ends_with(".org") => files.push(PathBuf::from(other)),
            other => {
                eprintln!("unknown argument: {other}");
                return ExitCode::FAILURE;
            }
        }
    }

    match mode {
        Mode::Server => match run_server(http_port, http_host, static_dir).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("eavd: {e:#}");
                ExitCode::FAILURE
            }
        },
        Mode::DumpTasks { active_only } => dump_tasks(&files, active_only, globals),
        Mode::DumpAgendaDay { date } => dump_agenda_day(&files, &date, globals),
        Mode::DumpAgendaRange { start, end } => {
            dump_agenda_range(&files, &start, &end, globals)
        }
    }
}

enum Mode {
    Server,
    DumpTasks { active_only: bool },
    DumpAgendaDay { date: String },
    DumpAgendaRange { start: String, end: String },
}

// ----------------------------------------------------------------------------
// Server mode
// ----------------------------------------------------------------------------

async fn run_server(
    http_port: Option<u16>,
    http_host: Option<String>,
    static_dir: Option<PathBuf>,
) -> anyhow::Result<()> {
    let bridge_path = default_bridge_socket();
    // Make sure the bridge is actually listening. On a fresh install the
    // user's Emacs hasn't loaded `eav-bridge.el` yet — we use a one-time
    // `emacsclient --eval` to load it and start the listener. After that
    // the persistent socket replaces emacsclient on the hot path.
    if let Err(e) = ensure_bridge_loaded(&bridge_path).await {
        eprintln!(
            "eavd: couldn't reach Emacs bridge at {bridge_path:?}: {e:#}\n\
             Make sure your Emacs server is running (M-x server-start)."
        );
        // Keep going anyway — reads from the index still work, only bridge
        // calls (mutations, sexp-day fallback) will fail until the bridge
        // comes up. The BridgeClient itself reconnects on demand.
    }
    tracing::info!(?bridge_path, "connecting to eav-bridge");
    let bridge = BridgeClient::connect(&bridge_path).await?;

    // Try to load the snapshot for cold-fast first paint, then reindex live
    // in the background.
    let index = Index::new();
    let snapshot_path = Snapshot::default_path();
    if let Ok(snap) = Snapshot::open(&snapshot_path) {
        if let Err(e) = index.load_snapshot(&snap) {
            tracing::warn!(error = %e, "snapshot load failed; cold-starting");
        } else {
            tracing::info!(tasks = index.task_count(), "loaded snapshot");
        }
    }

    let state = AppState::new(index.clone(), bridge.clone()).with_static_dir(static_dir);

    // Pull config + keywords + files from the bridge, populate cached_config,
    // and seed `index.set_global_keywords` so non-`#+TODO:` files match the
    // user's actual keyword sequences.
    let config: serde_json::Value = bridge
        .call("read.config", serde_json::json!({}))
        .await?;
    let files: Vec<eav_core::AgendaFile> = serde_json::from_value(config["files"].clone())?;
    let keywords: TodoKeywords = serde_json::from_value(config["keywords"].clone())?;
    {
        let mut cached = state.cached_config.write();
        cached.files = files.clone();
        cached.keywords = Some(keywords.clone());
        cached.priorities = serde_json::from_value(config["priorities"].clone()).ok();
        cached.config = serde_json::from_value(config["config"].clone()).ok();
        cached.list_config = serde_json::from_value(config["listConfig"].clone()).ok();
    }
    let kw_seqs: Vec<(Vec<String>, Vec<String>)> = keywords
        .sequences
        .into_iter()
        .map(|s| (s.active, s.done))
        .collect();
    index.set_global_keywords(GlobalKeywords::from_keyword_sequences(&kw_seqs));

    // Build the canonical agenda-file allowlist. Both the watcher and the
    // bridge's `after-save` handler use this to ignore writes to files
    // outside the agenda set — most notably `*.org_archive` files that
    // Emacs's `org-archive-subtree` saves alongside the original. Without
    // the filter the daemon ended up with archived copies of every
    // historical heading, surfacing as visible duplicates in the agenda.
    let file_paths: Vec<PathBuf> = files.iter().map(|f| PathBuf::from(&f.path)).collect();
    let agenda_set: Arc<HashSet<PathBuf>> = Arc::new(
        file_paths
            .iter()
            .map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone()))
            .collect(),
    );

    // Drop any snapshot entries that aren't in the agenda set. Cheap, and
    // self-heals on every restart against config changes (file removed
    // from agenda, archive file accidentally indexed by an older build).
    {
        let stale: Vec<PathBuf> = index
            .known_files()
            .into_iter()
            .filter(|p| {
                let canon = std::fs::canonicalize(p).unwrap_or_else(|_| p.clone());
                !agenda_set.contains(&canon)
            })
            .collect();
        for p in &stale {
            index.drop_file(p);
        }
        if !stale.is_empty() {
            tracing::info!(
                count = stale.len(),
                "pruned stale (non-agenda) files from snapshot"
            );
        }
    }

    let index_for_reindex = index.clone();
    let file_paths_for_reindex = file_paths.clone();
    tokio::spawn(async move {
        let mut handles = Vec::with_capacity(file_paths_for_reindex.len());
        for p in &file_paths_for_reindex {
            let path = p.clone();
            let idx = index_for_reindex.clone();
            handles.push(tokio::spawn(async move {
                let read = tokio::time::timeout(
                    Duration::from_secs(10),
                    tokio::fs::read_to_string(&path),
                )
                .await;
                match read {
                    Ok(Ok(text)) => {
                        idx.rebuild_file(&path, &text);
                    }
                    Ok(Err(e)) => tracing::warn!(?path, error = %e, "agenda file unreadable"),
                    Err(_) => tracing::warn!(?path, "agenda file read timed out (10 s)"),
                }
            }));
        }
        for h in handles {
            let _ = h.await;
        }
        tracing::info!(tasks = index_for_reindex.task_count(), "background reindex complete");
    });

    // Start file watcher.
    let (watcher, mut watcher_rx) = FileWatcher::start(&file_paths)?;
    let watcher = Arc::new(watcher);
    let index_for_watcher = index.clone();
    let events_for_watcher = state.events.clone();
    let agenda_set_for_watcher = Arc::clone(&agenda_set);
    tokio::spawn(async move {
        while let Some(change) = watcher_rx.recv().await {
            match change {
                FileChange::Modified(p) | FileChange::Removed(p) => {
                    if !is_agenda_file(&agenda_set_for_watcher, &p) {
                        continue;
                    }
                    if let Ok(text) = fs::read_to_string(&p) {
                        index_for_watcher.rebuild_file(&p, &text);
                        events_for_watcher.publish(ServerEvent::FileChanged {
                            file: p.to_string_lossy().into_owned(),
                        });
                    }
                }
            }
        }
    });

    // Forward bridge-pushed events into our SSE EventBus.
    let mut bridge_events = bridge.subscribe();
    let events_for_bridge = state.events.clone();
    let index_for_bridge = index.clone();
    let watcher_for_bridge = Arc::clone(&watcher);
    let agenda_set_for_bridge = Arc::clone(&agenda_set);
    tokio::spawn(async move {
        while let Ok(ev) = bridge_events.recv().await {
            forward_bridge_event(
                ev,
                &events_for_bridge,
                &index_for_bridge,
                &watcher_for_bridge,
                &agenda_set_for_bridge,
            );
        }
    });

    // Periodic snapshot writer.
    let snap_index = index.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(300));
        loop {
            interval.tick().await;
            if let Ok(mut snap) = Snapshot::open(&Snapshot::default_path()) {
                if let Err(e) = snap_index.save_snapshot(&mut snap) {
                    tracing::warn!(error = %e, "snapshot save failed");
                }
            }
        }
    });

    // HTTP server.
    let router = build_router(state);
    let port = http_port.unwrap_or(3002);
    let host = http_host.as_deref().unwrap_or("127.0.0.1");
    // Bind on either localhost (Mac-app helper, default) or 0.0.0.0
    // (headless deploys serving the SPA + API to LAN clients).
    let bind: std::net::SocketAddr = format!("{host}:{port}").parse()?;
    tracing::info!(?bind, "eavd HTTP listening");
    let listener = tokio::net::TcpListener::bind(bind).await?;
    axum::serve(listener, router).await?;
    Ok(())
}

fn forward_bridge_event(
    ev: BridgeEvent,
    events: &eav_server::EventBus,
    index: &Index,
    watcher: &FileWatcher,
    agenda_set: &HashSet<PathBuf>,
) {
    match ev.event.as_str() {
        "after-save" => {
            if let Some(file) = ev.params.get("file").and_then(|v| v.as_str()) {
                let p = PathBuf::from(file);
                // The bridge initiated this save (via a write.* call), so
                // suppress the matching fsnotify event to avoid a double
                // reindex.
                watcher.mark_self_write(p.clone());
                // Ignore saves to files outside the agenda set
                // (`*.org_archive`, throwaway notes, etc.) so they don't
                // pollute the index.
                if !is_agenda_file(agenda_set, &p) {
                    return;
                }
                if let Ok(text) = std::fs::read_to_string(&p) {
                    index.rebuild_file(&p, &text);
                }
                events.publish(ServerEvent::FileChanged { file: file.into() });
            }
        }
        "todo-state-changed" => {
            let file = ev.params.get("file").and_then(|v| v.as_str()).unwrap_or("");
            let pos = ev.params.get("pos").and_then(|v| v.as_u64()).unwrap_or(0);
            let id = OrgTask::synthetic_id(file, pos);
            events.publish(ServerEvent::TaskChanged {
                id,
                file: file.into(),
                pos,
            });
        }
        "clock-event" => {
            let file = ev.params.get("file").and_then(|v| v.as_str()).map(String::from);
            let pos = ev.params.get("pos").and_then(|v| v.as_u64());
            let kind = ev.params.get("kind").and_then(|v| v.as_str()).unwrap_or("");
            events.publish(ServerEvent::ClockChanged {
                file,
                pos,
                clocking: kind == "in",
            });
        }
        _ => {}
    }
}

/// True if `path` (resolved through symlinks) is in the canonical agenda
/// set. Used to gate watcher and bridge events so writes to sibling
/// non-agenda files (`*.org_archive`, dot-files, etc.) don't get indexed.
fn is_agenda_file(agenda_set: &HashSet<PathBuf>, path: &Path) -> bool {
    let canon = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    agenda_set.contains(&canon)
}

fn default_bridge_socket() -> PathBuf {
    if let Ok(custom) = std::env::var("EAV_BRIDGE_SOCK") {
        return PathBuf::from(custom);
    }
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    dir.join(format!("eav-bridge-{}.sock", users_uid()))
}

/// If the bridge socket isn't currently accepting connections, locate the
/// bundled `eav.el` + `eav-bridge.el` next to the eavd binary and have
/// `emacsclient` load them and start the listener. We then poll briefly
/// until the socket appears.
///
/// This is a one-shot: once the bridge is up, every subsequent call goes
/// through the persistent UnixStream and `emacsclient` is never invoked.
async fn ensure_bridge_loaded(socket_path: &Path) -> anyhow::Result<()> {
    if can_connect(socket_path).await {
        return Ok(());
    }
    let (eav_el, eav_bridge_el) = locate_bundled_elisp().ok_or_else(|| {
        anyhow::anyhow!("bundled elisp (eav.el / eav-bridge.el) not found near {:?}",
                        std::env::current_exe().ok())
    })?;
    let socket_path_lit = lisp_string(&socket_path.to_string_lossy());
    let eav_el_lit = lisp_string(&eav_el.to_string_lossy());
    let bridge_el_lit = lisp_string(&eav_bridge_el.to_string_lossy());
    let expr = format!(
        "(progn (load-file {eav}) (load-file {br}) (require 'eav-bridge) \
         (setq eav-bridge-socket-path {sock}) (eav-bridge-start) t)",
        eav = eav_el_lit, br = bridge_el_lit, sock = socket_path_lit,
    );
    tracing::info!("loading eav-bridge.el into Emacs via emacsclient");
    let output = tokio::process::Command::new("emacsclient")
        .arg("--eval")
        .arg(&expr)
        .output()
        .await
        .map_err(|e| anyhow::anyhow!("emacsclient failed to spawn: {e} (Emacs server running?)"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("emacsclient --eval failed: {stderr}");
    }
    // Poll for the socket. Emacs's `make-network-process` is synchronous
    // so the socket should appear immediately, but allow a short window.
    for _ in 0..50 {
        if can_connect(socket_path).await {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    anyhow::bail!("bridge socket {socket_path:?} did not appear after emacsclient load")
}

async fn can_connect(socket_path: &Path) -> bool {
    if !socket_path.exists() {
        return false;
    }
    matches!(
        tokio::time::timeout(
            Duration::from_millis(200),
            tokio::net::UnixStream::connect(socket_path),
        )
        .await,
        Ok(Ok(_))
    )
}

/// Look for `eav.el` and `eav-bridge.el` in three places, in priority order:
/// 1. The directory containing the running `eavd` binary (the .app bundle's
///    `Contents/Resources/`).
/// 2. `EAV_ELISP_DIR` env var override, useful for non-bundled invocations.
/// 3. `<repo-root>/elisp/` derived from the binary path under
///    `daemon/target/{debug,release}/eavd` (developer convenience).
fn locate_bundled_elisp() -> Option<(PathBuf, PathBuf)> {
    if let Ok(dir) = std::env::var("EAV_ELISP_DIR") {
        let dir = PathBuf::from(dir);
        let pair = (dir.join("eav.el"), dir.join("eav-bridge.el"));
        if pair.0.exists() && pair.1.exists() {
            return Some(pair);
        }
    }
    let exe = std::env::current_exe().ok()?;
    if let Some(parent) = exe.parent() {
        let pair = (parent.join("eav.el"), parent.join("eav-bridge.el"));
        if pair.0.exists() && pair.1.exists() {
            return Some(pair);
        }
        // Walk up looking for daemon/target/{release,debug}/eavd → repo-root/elisp
        let mut cur = parent.to_path_buf();
        for _ in 0..6 {
            let candidate = cur.join("elisp");
            if candidate.exists() {
                let pair = (candidate.join("eav.el"), candidate.join("eav-bridge.el"));
                if pair.0.exists() && pair.1.exists() {
                    return Some(pair);
                }
            }
            if !cur.pop() {
                break;
            }
        }
    }
    None
}

/// Quote a path/string as an elisp string literal. Escapes \ and ".
fn lisp_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

fn users_uid() -> u32 {
    // SAFETY: getuid() is signal-safe.
    unsafe { libc::getuid() }
}

// ----------------------------------------------------------------------------
// CLI utility modes (unchanged from earlier phases)
// ----------------------------------------------------------------------------

fn build_index(files: &[PathBuf], globals: Option<GlobalKeywords>) -> Index {
    let index = Index::new();
    if let Some(g) = globals {
        index.set_global_keywords(g);
    }
    for path in files {
        if let Ok(text) = fs::read_to_string(path) {
            let _ = index.rebuild_file(path, &text);
        } else {
            eprintln!("skip {path:?}: read failed");
        }
    }
    index
}

fn dump_agenda_day(
    files: &[PathBuf],
    date: &str,
    globals: Option<GlobalKeywords>,
) -> ExitCode {
    let target = match NaiveDate::parse_from_str(date, "%Y-%m-%d") {
        Ok(d) => d,
        Err(e) => {
            eprintln!("invalid date {date:?}: {e}");
            return ExitCode::FAILURE;
        }
    };
    if files.is_empty() {
        eprintln!("no files to dump (pass paths or --files-from <list>)");
        return ExitCode::FAILURE;
    }
    let index = build_index(files, globals);
    let tasks = index.all_agenda_entries();
    let today = chrono::Local::now().date_naive();
    let evaluation = evaluate_day(&tasks, target, today, &AgendaConfig::default());
    println!("{}", serde_json::to_string(&evaluation.entries).unwrap());
    ExitCode::SUCCESS
}

fn dump_agenda_range(
    files: &[PathBuf],
    start: &str,
    end: &str,
    globals: Option<GlobalKeywords>,
) -> ExitCode {
    let s = match NaiveDate::parse_from_str(start, "%Y-%m-%d") {
        Ok(d) => d,
        Err(e) => {
            eprintln!("invalid start {start:?}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let e = match NaiveDate::parse_from_str(end, "%Y-%m-%d") {
        Ok(d) => d,
        Err(e) => {
            eprintln!("invalid end {end:?}: {e}");
            return ExitCode::FAILURE;
        }
    };
    if files.is_empty() {
        eprintln!("no files to dump (pass paths or --files-from <list>)");
        return ExitCode::FAILURE;
    }
    let index = build_index(files, globals);
    let tasks = index.all_agenda_entries();
    let today = chrono::Local::now().date_naive();
    let evaluation = evaluate_range(&tasks, s, e, today, &AgendaConfig::default());
    println!("{}", serde_json::to_string(&evaluation.entries).unwrap());
    ExitCode::SUCCESS
}

fn dump_tasks(
    files: &[PathBuf],
    active_only: bool,
    globals: Option<GlobalKeywords>,
) -> ExitCode {
    if files.is_empty() {
        eprintln!("no files to dump (pass paths or --files-from <list>)");
        return ExitCode::FAILURE;
    }
    let index = Index::new();
    if let Some(g) = globals {
        index.set_global_keywords(g);
    }
    for path in files {
        match fs::read_to_string(path) {
            Ok(text) => {
                let _ = index.rebuild_file(path, &text);
            }
            Err(e) => {
                eprintln!("skip {path:?}: {e}");
            }
        }
    }
    let tasks: Vec<OrgTask> = if active_only {
        index.active_tasks()
    } else {
        index.all_tasks()
    };
    let out = serde_json::to_string(&tasks).expect("serialize tasks");
    println!("{out}");
    ExitCode::SUCCESS
}

fn parse_keywords_file(path: &str) -> std::io::Result<GlobalKeywords> {
    let raw = fs::read_to_string(path)?;
    let kws: TodoKeywords = serde_json::from_str(&raw)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let seqs: Vec<(Vec<String>, Vec<String>)> = kws
        .sequences
        .into_iter()
        .map(|s| (s.active, s.done))
        .collect();
    Ok(GlobalKeywords::from_keyword_sequences(&seqs))
}

fn parse_files_list(path: &str) -> std::io::Result<Vec<PathBuf>> {
    let raw = fs::read_to_string(path)?;
    let trimmed = raw.trim_start();
    if trimmed.starts_with('[') {
        #[derive(serde::Deserialize)]
        struct FileEntry {
            path: String,
        }
        let entries: Vec<FileEntry> = serde_json::from_str(&raw)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        return Ok(entries.into_iter().map(|f| PathBuf::from(f.path)).collect());
    }
    Ok(raw
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(PathBuf::from)
        .collect())
}

fn print_help() {
    eprintln!(
        "eavd — Emacs Agenda Viewer daemon\n\n\
         USAGE:\n  \
         eavd                              run the HTTP/SSE server (default 127.0.0.1:3002)\n  \
         eavd --http-port N                bind to a different TCP port\n  \
         eavd --http-host HOST             bind to HOST (e.g. 0.0.0.0 for LAN access)\n  \
         eavd --static-dir <path>          serve SPA assets from <path> (`/` ⇒ index.html)\n  \
         eavd --dump-tasks [files...]      parse files and print tasks JSON\n  \
         eavd --dump-active-tasks ...      same, only active (non-done) tasks\n  \
         eavd --dump-agenda-day YYYY-MM-DD parse files and print agenda entries\n  \
         eavd --dump-agenda-range S E      print agenda entries [S..E]\n  \
         eavd --files-from <path>          read file paths from <path> (one per line\n                                      OR the JSON output of /api/files)\n  \
         eavd --keywords-from <path>       inject /api/keywords output as fallback\n                                      keyword set\n\n\
         ENV:\n  \
         EAV_BRIDGE_SOCK=<path>            override the bridge socket path\n"
    );
}

fn init_tracing() {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().compact())
        .init();
}
