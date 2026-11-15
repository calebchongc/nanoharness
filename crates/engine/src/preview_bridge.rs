//! Bridge between `EngineCore` / `EngineRpc` and the Zig `harness preview-daemon`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use harness_proto::{PREVIEW_PROXY_PORT, PreviewService as ProtoPreviewService, PreviewSnapshot};
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::watch;

use crate::zig_helper;

const PROJECT_POLL_INTERVAL: Duration = Duration::from_secs(3);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DaemonSnapshotLine {
    #[serde(default)]
    services: Vec<ProtoPreviewService>,
    #[serde(default = "default_proxy_port")]
    proxy_port: u16,
    #[serde(default)]
    error: Option<String>,
}

fn default_proxy_port() -> u16 {
    PREVIEW_PROXY_PORT
}

#[derive(Default)]
struct CatalogState {
    local: Vec<ProtoPreviewService>,
    remote: BTreeMap<String, Vec<ProtoPreviewService>>,
    proxy_port: u16,
    error: Option<String>,
}

/// Shared catalog of locally discovered and remote-advertised preview services.
#[derive(Clone)]
pub struct Catalog {
    device_id: String,
    state: Arc<Mutex<CatalogState>>,
    tx: watch::Sender<PreviewSnapshot>,
}

impl Catalog {
    fn new(device_id: String) -> Self {
        let initial = PreviewSnapshot::default();
        let (tx, _) = watch::channel(initial);
        Self {
            device_id,
            state: Arc::new(Mutex::new(CatalogState {
                proxy_port: PREVIEW_PROXY_PORT,
                ..Default::default()
            })),
            tx,
        }
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn subscribe(&self) -> watch::Receiver<PreviewSnapshot> {
        self.tx.subscribe()
    }

    pub fn set_local(
        &self,
        services: Vec<ProtoPreviewService>,
        proxy_port: u16,
        error: Option<String>,
    ) {
        let mut guard = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        guard.local = services;
        guard.proxy_port = proxy_port;
        guard.error = error;
        let snapshot = build_snapshot(&guard);
        drop(guard);
        self.tx.send_replace(snapshot);
    }

    pub fn set_remote(
        &self,
        device_id: impl Into<String>,
        services: Vec<ProtoPreviewService>,
    ) -> Result<(), String> {
        let mut guard = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        guard.remote.insert(device_id.into(), services);
        let snapshot = build_snapshot(&guard);
        drop(guard);
        self.tx.send_replace(snapshot);
        Ok(())
    }

    pub fn remove_remote(&self, device_id: &str) {
        let mut guard = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if guard.remote.remove(device_id).is_some() {
            let snapshot = build_snapshot(&guard);
            drop(guard);
            self.tx.send_replace(snapshot);
        }
    }
}

fn build_snapshot(state: &CatalogState) -> PreviewSnapshot {
    let mut services = state.local.clone();
    for remote_list in state.remote.values() {
        services.extend(remote_list.iter().cloned());
    }
    PreviewSnapshot {
        services,
        proxy_port: if state.proxy_port == 0 {
            PREVIEW_PROXY_PORT
        } else {
            state.proxy_port
        },
        error: state.error.clone(),
        project_name: None,
        remote: false,
    }
}

/// Manages the background `harness preview-daemon` process and exposes its [`Catalog`].
#[derive(Clone)]
pub struct PreviewService {
    catalog: Catalog,
    catalog_path: PathBuf,
    device_name: String,
    inner: Arc<Mutex<ServiceHandle>>,
}

struct ServiceHandle {
    stop_tx: watch::Sender<bool>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl PreviewService {
    pub fn new(
        catalog_path: PathBuf,
        device_id: String,
        device_name: String,
    ) -> Result<Self, String> {
        let (stop_tx, _) = watch::channel(false);
        Ok(Self {
            catalog: Catalog::new(device_id),
            catalog_path,
            device_name,
            inner: Arc::new(Mutex::new(ServiceHandle {
                stop_tx,
                task: None,
            })),
        })
    }

    pub fn catalog(&self) -> &Catalog {
        &self.catalog
    }

    pub async fn start(&self, projects: Arc<dyn Fn() -> Vec<PathBuf> + Send + Sync>) {
        self.shutdown().await;
        let Some(cli) = zig_helper::find_zig_cli() else {
            tracing::debug!("Zig harness binary not found; preview daemon not started");
            return;
        };

        let mut cmd = tokio::process::Command::new(&cli);
        cmd.args([
            "preview-daemon",
            "--port",
            &PREVIEW_PROXY_PORT.to_string(),
            "--device-id",
            self.catalog.device_id(),
            "--device-name",
            &self.device_name,
            "--catalog",
        ])
        .arg(&self.catalog_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(error) => {
                tracing::warn!(%error, "failed to start harness preview-daemon");
                return;
            }
        };

        let Some(mut stdin) = child.stdin.take() else {
            return;
        };
        let Some(stdout) = child.stdout.take() else {
            return;
        };

        let catalog = self.catalog.clone();
        let (stop_tx, mut stop_rx) = watch::channel(false);
        let handle = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut interval = tokio::time::interval(PROJECT_POLL_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_cwds: Option<Vec<String>> = None;

            loop {
                tokio::select! {
                    changed = stop_rx.changed() => {
                        if changed.is_err() || *stop_rx.borrow() {
                            break;
                        }
                    }
                    _ = interval.tick() => {
                        let mut cwds: Vec<String> = projects()
                            .into_iter()
                            .map(|p| p.to_string_lossy().into_owned())
                            .collect();
                        cwds.sort();
                        cwds.dedup();
                        if last_cwds.as_ref() != Some(&cwds) {
                            let line = format!("{}\n", json!({ "op": "projects", "cwds": cwds }));
                            if stdin.write_all(line.as_bytes()).await.is_err() {
                                break;
                            }
                            last_cwds = Some(cwds);
                        }
                    }
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(raw)) => {
                                let trimmed = raw.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }
                                if let Ok(parsed) = serde_json::from_str::<DaemonSnapshotLine>(trimmed) {
                                    catalog.set_local(parsed.services, parsed.proxy_port, parsed.error);
                                }
                            }
                            Ok(None) | Err(_) => break,
                        }
                    }
                }
            }
            drop(stdin);
            let _ = child.start_kill();
            let _ = child.wait().await;
        });

        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        guard.stop_tx = stop_tx;
        guard.task = Some(handle);
    }

    pub fn stop(&self) {
        let guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        guard.stop_tx.send_replace(true);
    }

    pub async fn shutdown(&self) {
        let task = {
            let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            guard.stop_tx.send_replace(true);
            guard.task.take()
        };
        if let Some(task) = task {
            let _ = task.await;
        }
    }
}
