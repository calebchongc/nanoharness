//! Bridge between `Engine` / `EngineRpc` and the Zig `harness update-daemon`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use anyhow::Context;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Notify, mpsc, oneshot, watch};

use crate::zig_helper;

const QUIESCENT_POLL_INTERVAL: Duration = Duration::from_secs(5);
const DAEMON_REPLY_TIMEOUT: Duration = Duration::from_secs(120);

/// Predicate indicating whether restarting now would interrupt active work.
pub type QuiescentCheck = Arc<dyn Fn() -> bool + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HostUpdateMode {
    Managed,
    Desktop,
    Manual,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HostUpdatePhase {
    #[default]
    Idle,
    Checking,
    Downloading,
    WaitingForIdle,
    Restarting,
    Failed,
}

/// Host update capability/phase reported to clients on the `UpdateStatus` stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostUpdateStatus {
    pub mode: HostUpdateMode,
    pub automatic: bool,
    pub phase: HostUpdatePhase,
}

/// Release status item published over the `UpdateStatus` RPC stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub current_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_version: Option<String>,
    #[serde(default)]
    pub update_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<HostUpdateStatus>,
}

impl UpdateStatus {
    fn initial(install: &InstallKind, automatic: bool) -> Self {
        let mode = if matches!(install, InstallKind::Managed { .. }) {
            HostUpdateMode::Managed
        } else if install.supports_desktop_update() {
            HostUpdateMode::Desktop
        } else {
            HostUpdateMode::Manual
        };
        Self {
            current_version: env!("CARGO_PKG_VERSION").to_string(),
            latest_version: None,
            update_available: false,
            checked_at: None,
            error: None,
            host: Some(HostUpdateStatus {
                mode,
                automatic,
                phase: HostUpdatePhase::Idle,
            }),
        }
    }
}

/// Classification of the installation layout running this engine binary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallKind {
    Managed { app_root: PathBuf },
    MacApp { bundle: PathBuf },
    WindowsPortable { directory: PathBuf },
    Unmanaged,
}

impl InstallKind {
    pub fn supports_desktop_update(&self) -> bool {
        match self {
            Self::MacApp { .. } => true,
            #[cfg(windows)]
            Self::WindowsPortable { .. } => true,
            _ => false,
        }
    }

    pub fn checks_releases(&self) -> bool {
        match self {
            Self::MacApp { .. } | Self::Managed { .. } => true,
            #[cfg(windows)]
            Self::WindowsPortable { .. } => true,
            _ => false,
        }
    }
}

/// Inspect `current_exe()` to determine whether auto-update checks apply.
pub fn detect_install() -> InstallKind {
    let Ok(exe) = std::env::current_exe() else {
        return InstallKind::Unmanaged;
    };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    detect_install_from(&exe, home.as_deref())
}

fn detect_install_from(exe: &Path, home: Option<&Path>) -> InstallKind {
    #[cfg(windows)]
    if let Some(dir) = exe.parent()
        && dir.join("harness-update.json").is_file()
    {
        return InstallKind::WindowsPortable {
            directory: dir.to_path_buf(),
        };
    }
    #[cfg(not(windows))]
    if let Some(home) = home {
        let app_root = home.join(".harness").join("app");
        if exe.starts_with(&app_root) {
            return InstallKind::Managed { app_root };
        }
    }
    #[cfg(target_os = "macos")]
    for ancestor in exe.ancestors() {
        if ancestor.extension().is_some_and(|ext| ext == "app")
            && exe.starts_with(ancestor.join("Contents").join("MacOS"))
        {
            if is_dev_bundle(ancestor) {
                return InstallKind::Unmanaged;
            }
            return InstallKind::MacApp {
                bundle: ancestor.to_path_buf(),
            };
        }
    }
    let _ = home;
    InstallKind::Unmanaged
}

#[cfg(target_os = "macos")]
fn is_dev_bundle(bundle: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(bundle.join("Contents").join("Info.plist")) else {
        return false;
    };
    let Some(key_pos) = text.find("CFBundleIdentifier") else {
        return false;
    };
    let tail = &text[key_pos..];
    let Some(start) = tail.find("<string>") else {
        return false;
    };
    let value_start = start + "<string>".len();
    let Some(end) = tail[value_start..].find("</string>") else {
        return false;
    };
    tail[value_start..value_start + end].trim().ends_with(".dev")
}

fn auto_update_enabled() -> bool {
    match std::env::var("HARNESS_AUTO_UPDATE") {
        Ok(val) => !matches!(val.trim(), "0" | "false" | "FALSE" | "no" | "NO" | "off"),
        Err(_) => true,
    }
}

static REEXEC_TARGET: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
static REEXEC_NOTIFY: OnceLock<Notify> = OnceLock::new();

fn reexec_target() -> &'static Mutex<Option<PathBuf>> {
    REEXEC_TARGET.get_or_init(|| Mutex::new(None))
}

fn reexec_notify() -> &'static Notify {
    REEXEC_NOTIFY.get_or_init(Notify::new)
}

fn set_reexec_target(path: PathBuf) {
    *reexec_target().lock().unwrap_or_else(PoisonError::into_inner) = Some(path);
    reexec_notify().notify_waiters();
}

/// Resolves once `update-daemon` asks the headless engine to re-exec into a newly installed binary.
pub async fn reexec_requested() {
    loop {
        let notified = reexec_notify().notified();
        if reexec_target()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_some()
        {
            return;
        }
        notified.await;
    }
}

/// Replace this process with the newly installed release binary if a re-exec was requested.
pub fn reexec() -> Option<std::io::Error> {
    let exe = reexec_target()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()?;
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        tracing::info!(exe = %exe.display(), "restarting into the updated release");
        Some(
            std::process::Command::new(&exe)
                .args(std::env::args_os().skip(1))
                .exec(),
        )
    }
    #[cfg(not(unix))]
    {
        let _ = exe;
        Some(std::io::Error::other(
            "in-place reexec is not supported on this platform",
        ))
    }
}

enum DaemonCmd {
    Check,
    Queue {
        id: u64,
        reply: oneshot::Sender<Result<Option<String>, String>>,
    },
    Apply {
        id: u64,
        reply: oneshot::Sender<Result<Option<String>, String>>,
    },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum DaemonEvent {
    Status {
        status: UpdateStatus,
    },
    Reply {
        reply: u64,
        #[serde(default)]
        ok: bool,
        #[serde(default)]
        version: Option<String>,
        #[serde(default)]
        err: Option<String>,
    },
    Reexec {
        reexec: String,
    },
}

/// Handle to the background Zig `harness update-daemon` process.
#[derive(Clone)]
pub struct Updater {
    inner: Arc<UpdaterInner>,
}

struct UpdaterInner {
    install: InstallKind,
    status_tx: watch::Sender<UpdateStatus>,
    cmd_tx: Mutex<Option<mpsc::UnboundedSender<DaemonCmd>>>,
    next_id: AtomicU64,
    shutdown_tx: watch::Sender<bool>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Updater {
    /// Start watching releases via `harness update-daemon` (or stay idle if no Zig CLI is present).
    pub fn spawn(edge_url: String, quiescent: Option<QuiescentCheck>) -> Self {
        let install = detect_install();
        let initial = UpdateStatus::initial(&install, auto_update_enabled());
        let (status_tx, _) = watch::channel(initial);
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);

        let Some(cli) = zig_helper::find_zig_cli() else {
            return Self {
                inner: Arc::new(UpdaterInner {
                    install,
                    status_tx,
                    cmd_tx: Mutex::new(None),
                    next_id: AtomicU64::new(1),
                    shutdown_tx,
                    task: Mutex::new(None),
                }),
            };
        };

        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<DaemonCmd>();
        let inner = Arc::new(UpdaterInner {
            install,
            status_tx,
            cmd_tx: Mutex::new(Some(cmd_tx)),
            next_id: AtomicU64::new(1),
            shutdown_tx,
            task: Mutex::new(None),
        });

        let task_inner = inner.clone();
        let handle = tokio::spawn(async move {
            let mut pending: HashMap<u64, oneshot::Sender<Result<Option<String>, String>>> =
                HashMap::new();

            let mut cmd = tokio::process::Command::new(&cli);
            cmd.arg("update-daemon");
            if !edge_url.trim().is_empty() {
                cmd.args(["--edge-url", &edge_url]);
            }
            cmd.stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true);

            let mut child = match cmd.spawn() {
                Ok(child) => child,
                Err(error) => {
                    tracing::warn!(%error, "failed to launch harness update-daemon");
                    return;
                }
            };
            let Some(mut stdin) = child.stdin.take() else {
                return;
            };
            let Some(stdout) = child.stdout.take() else {
                return;
            };

            let mut lines = BufReader::new(stdout).lines();
            let mut interval = tokio::time::interval(QUIESCENT_POLL_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_quiescent: Option<bool> = None;

            loop {
                tokio::select! {
                    changed = shutdown_rx.changed() => {
                        if changed.is_err() || *shutdown_rx.borrow() {
                            break;
                        }
                    }
                    _ = interval.tick() => {
                        let q = quiescent.as_ref().is_none_or(|f| f());
                        if last_quiescent != Some(q) {
                            let msg = format!("{}\n", json!({ "op": "quiescent", "value": q }));
                            if stdin.write_all(msg.as_bytes()).await.is_err() {
                                break;
                            }
                            last_quiescent = Some(q);
                        }
                    }
                    Some(cmd) = cmd_rx.recv() => {
                        let line = match cmd {
                            DaemonCmd::Check => format!("{}\n", json!({ "op": "check" })),
                            DaemonCmd::Queue { id, reply } => {
                                pending.insert(id, reply);
                                format!("{}\n", json!({ "op": "queue", "id": id }))
                            }
                            DaemonCmd::Apply { id, reply } => {
                                pending.insert(id, reply);
                                format!("{}\n", json!({ "op": "apply", "id": id }))
                            }
                        };
                        if stdin.write_all(line.as_bytes()).await.is_err() {
                            break;
                        }
                    }
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(raw)) => {
                                let trimmed = raw.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }
                                if let Ok(ev) = serde_json::from_str::<DaemonEvent>(trimmed) {
                                    match ev {
                                        DaemonEvent::Status { status } => {
                                            task_inner.status_tx.send_replace(status);
                                        }
                                        DaemonEvent::Reply { reply, ok, version, err } => {
                                            if let Some(tx) = pending.remove(&reply) {
                                                if ok {
                                                    let _ = tx.send(Ok(version));
                                                } else {
                                                    let _ = tx.send(Err(err.unwrap_or_else(|| "update command failed".into())));
                                                }
                                            }
                                        }
                                        DaemonEvent::Reexec { reexec } => {
                                            set_reexec_target(PathBuf::from(reexec));
                                        }
                                    }
                                }
                            }
                            Ok(None) | Err(_) => break,
                        }
                    }
                }
            }

            for (_, tx) in pending.drain() {
                let _ = tx.send(Err("updater stopped".into()));
            }
            drop(stdin);
            let _ = child.start_kill();
            let _ = child.wait().await;
        });

        *inner.task.lock().unwrap_or_else(PoisonError::into_inner) = Some(handle);
        Self { inner }
    }

    pub fn watch(&self) -> watch::Receiver<UpdateStatus> {
        self.inner.status_tx.subscribe()
    }

    pub fn check_now(&self) {
        if let Some(tx) = self
            .inner
            .cmd_tx
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            let _ = tx.send(DaemonCmd::Check);
        }
    }

    /// Queue a managed-host update (`QueueUpdate`); rejects non-managed installs synchronously.
    pub fn queue_update(&self) -> anyhow::Result<()> {
        if !matches!(self.inner.install, InstallKind::Managed { .. }) {
            anyhow::bail!(
                "this device cannot queue a remote update; update its desktop app or package locally"
            );
        }
        let tx = self
            .inner
            .cmd_tx
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .context("the updater is unavailable")?;
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply_tx, _reply_rx) = oneshot::channel();
        tx.send(DaemonCmd::Queue {
            id,
            reply: reply_tx,
        })
        .map_err(|_| anyhow::anyhow!("the updater is shutting down"))?;
        Ok(())
    }

    /// Stage and apply an available update via the daemon, returning the installed version.
    pub async fn apply(&self) -> anyhow::Result<String> {
        let tx = self
            .inner
            .cmd_tx
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .context("updates are unavailable without the harness CLI helper")?;
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        tx.send(DaemonCmd::Apply {
            id,
            reply: reply_tx,
        })
        .map_err(|_| anyhow::anyhow!("the updater is shutting down"))?;
        let res = tokio::time::timeout(DAEMON_REPLY_TIMEOUT, reply_rx)
            .await
            .context("timed out waiting for update-daemon")?
            .context("update-daemon closed before replying")?;
        res.map(Option::unwrap_or_default)
            .map_err(|msg| anyhow::anyhow!(msg))
    }

    pub async fn shutdown(&self) {
        self.inner.shutdown_tx.send_replace(true);
        self.inner
            .cmd_tx
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        let handle = self
            .inner
            .task
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(handle) = handle {
            let _ = handle.await;
        }
    }
}
