//! Actual retained harness-sync ChatClient + harness-doc SessionDoc consumer.
//! Local-only, synthetic acceptance helper. No model/provider credentials.
use futures::future::BoxFuture;
use harness_doc::{SessionCommandEntry, SessionDoc};
use harness_sync::{
    DocsStore, SyncError,
    chat_client::{ChatClient, ChatDocSink, CheckpointFetcher, RowImportOutcome},
};
use loro::{ExportMode, LoroDoc, VersionVector};
use serde_json::{Value, json};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering::Relaxed},
};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

struct Sink {
    doc: Mutex<SessionDoc>,
    store: Arc<DocsStore>,
    chat: String,
    cursor: AtomicU64,
    rows: AtomicU64,
    checkpoint: AtomicBool,
}
impl Sink {
    fn persist(&self, cursor: u64) -> Result<(), String> {
        let bytes = self
            .doc
            .lock()
            .unwrap()
            .export_snapshot()
            .map_err(|e| e.to_string())?;
        self.store
            .save_verified_snapshot_with_cursor(&self.chat, &bytes, cursor, 2)
            .map_err(|e| e.to_string())?;
        self.cursor.store(cursor, Relaxed);
        Ok(())
    }
}
impl ChatDocSink for Sink {
    fn cursor_is_verified(&self) -> bool {
        true
    }
    fn reset_cursor(&self, cursor: u64) {
        self.persist(cursor).unwrap();
    }
    fn pending_updates(&self) -> Result<Vec<(String, Vec<u8>)>, String> {
        self.store
            .pending_chat_updates(&self.chat)
            .map_err(|e| e.to_string())
    }
    fn persist_update(&self, batch: &str, bytes: &[u8]) -> Result<(), String> {
        self.store
            .enqueue_chat_update(&self.chat, batch, bytes)
            .map_err(|e| e.to_string())
    }
    fn acknowledge_update(&self, batch: &str) -> Result<(), String> {
        self.store
            .acknowledge_chat_update(&self.chat, batch)
            .map_err(|e| e.to_string())
    }
    fn apply_row(&self, bytes: &[u8], cursor: u64) -> RowImportOutcome {
        {
            let doc = self.doc.lock().unwrap();
            if doc
                .doc()
                .import(bytes)
                .expect("real Loro row")
                .pending
                .is_some()
            {
                return RowImportOutcome::PendingDependencies;
            }
        }
        self.persist(cursor).unwrap();
        self.rows.fetch_add(1, Relaxed);
        RowImportOutcome::Applied
    }
    fn apply_checkpoint(&self, bytes: &[u8], cursor: u64) -> Result<(), String> {
        {
            let doc = self.doc.lock().unwrap();
            if doc
                .doc()
                .import(bytes)
                .map_err(|e| e.to_string())?
                .pending
                .is_some()
            {
                return Err("checkpoint missing dependencies".into());
            }
        }
        self.persist(cursor)?;
        self.checkpoint.store(true, Relaxed);
        Ok(())
    }
    fn contains_frontier(&self, bytes: &[u8]) -> bool {
        VersionVector::decode(bytes).is_ok_and(|vv| {
            !vv.is_empty() && self.doc.lock().unwrap().doc().oplog_vv().includes_vv(&vv)
        })
    }
    fn advance_cursor(&self, cursor: u64) {
        self.persist(cursor).unwrap();
    }
}
struct Fetcher {
    url: String,
    token: String,
}
impl CheckpointFetcher for Fetcher {
    fn fetch(&self) -> BoxFuture<'static, Result<Vec<u8>, SyncError>> {
        let url = self.url.clone();
        let token = self.token.clone();
        Box::pin(async move {
            let r = reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap()
                .get(url)
                .bearer_auth(token)
                .send()
                .await
                .map_err(|e| SyncError::Protocol(e.to_string()))?;
            if !r.status().is_success() {
                return Err(SyncError::Protocol(format!("checkpoint {}", r.status())));
            }
            Ok(r.bytes()
                .await
                .map_err(|e| SyncError::Protocol(e.to_string()))?
                .to_vec())
        })
    }
}
fn open(dir: &Path, chat: &str) -> Sink {
    let store = Arc::new(DocsStore::open(dir).unwrap());
    let raw = LoroDoc::new();
    if let Some(bytes) = store.load_snapshot(chat).unwrap() {
        assert!(raw.import(&bytes).unwrap().pending.is_none());
    }
    let cursor = store.snapshot_cursor(chat).unwrap();
    Sink {
        doc: Mutex::new(SessionDoc::from_doc(raw)),
        store,
        chat: chat.into(),
        cursor: AtomicU64::new(cursor),
        rows: AtomicU64::new(0),
        checkpoint: AtomicBool::new(false),
    }
}
fn typed(doc: &SessionDoc) -> Value {
    json!({"messages":doc.read_entries().unwrap(),"queue":doc.read_queue().unwrap(),"commands":doc.read_commands().unwrap()})
}
fn output(sink: &Sink, dir: &Path) -> Value {
    let doc = sink.doc.lock().unwrap();
    let entries = doc.read_entries().unwrap();
    std::fs::write(dir.join("rust.snapshot"), doc.export_snapshot().unwrap()).unwrap();
    std::fs::write(dir.join("rust.vv"), doc.doc().oplog_vv().encode()).unwrap();
    std::fs::write(
        dir.join("typed.json"),
        serde_json::to_vec_pretty(&typed(&doc)).unwrap(),
    )
    .unwrap();
    json!({"messages":entries.len(),"first":entries.first().map(|m|&m.id),"middle":entries.get(65).map(|m|&m.id),"last":entries.last().map(|m|&m.id),"cursor":sink.cursor.load(Relaxed),"rowsApplied":sink.rows.load(Relaxed),"checkpointApplied":sink.checkpoint.load(Relaxed),"pendingPushes":sink.store.pending_chat_updates(&sink.chat).unwrap().len(),"remoteRunCount":entries.iter().filter(|m|m.id=="remote-message").count(),"nativeUnicodeRoundtrip":entries.iter().any(|m|m.parts.iter().any(|p|matches!(p,harness_doc::MessagePart::Text{text,..} if text.contains("Zig writes real Loro updates 🦀 é"))))})
}
async fn wait_for(mut pred: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    while !pred() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "retained Rust client convergence deadline"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    let mode = &args[1];
    let base = &args[2];
    let chat = &args[3];
    let dir = PathBuf::from(&args[4]);
    let url = reqwest::Url::parse(base)?;
    assert!(
        url.scheme() == "http" && url.host_str() == Some("127.0.0.1"),
        "local-only peer"
    );
    let token = std::env::var("HARNESS_EDGE_TOKEN")?;
    std::fs::create_dir_all(&dir)?;
    if mode == "seed-pending" {
        let bytes = include_bytes!("../../../apps/nano/src/fixtures/loro-incremental.bin").to_vec();
        let r = reqwest::Client::new()
            .post(format!(
                "{base}/chat2/{chat}/rows?device=retained-rust&batchId=retained-dependent-first"
            ))
            .bearer_auth(token)
            .body(bytes)
            .send()
            .await?;
        assert!(r.status().is_success());
        println!(
            "RESULT:{}",
            json!({"dependentFirst":true,"ack":r.json::<Value>().await?})
        );
        return Ok(());
    }
    if mode == "seed" || mode == "seed-baseline" {
        let doc = SessionDoc::from_doc(LoroDoc::new());
        assert!(
            doc.doc()
                .import(include_bytes!(
                    "../../../apps/nano/src/fixtures/loro-baseline.bin"
                ))
                .unwrap()
                .pending
                .is_none()
        );
        if mode != "seed-baseline" {
            assert!(
                doc.doc()
                    .import(include_bytes!(
                        "../../../apps/nano/src/fixtures/loro-incremental.bin"
                    ))
                    .unwrap()
                    .pending
                    .is_none()
            );
        }
        assert_eq!(doc.chat_id().as_deref(), Some(chat.as_str()));
        // Keep this synthetic row available for concurrent editing rather
        // than letting the native host correctly drain it after a turn.
        doc.set_queued_delivery_gate(
            "q-rust",
            Some(&harness_doc::QueueDeliveryGate::ReviewRequired {
                previous_lease_id: "synthetic-lease".into(),
                owner_device_id: "retained-rust".into(),
                since_ms: 1400,
                base_text_hash: "synthetic-base".into(),
            }),
        )?;
        let bytes = doc.export_snapshot()?;
        let r = reqwest::Client::new()
            .post(format!(
                "{base}/chat2/{chat}/rows?device=retained-rust&batchId=retained-seed"
            ))
            .bearer_auth(token)
            .body(bytes)
            .send()
            .await?;
        assert!(r.status().is_success());
        println!(
            "RESULT:{}",
            json!({"seeded":131,"ack":r.json::<Value>().await?})
        );
        return Ok(());
    }
    if mode == "compare" || mode == "compare-swift" {
        let db = rusqlite::Connection::open_with_flags(
            &args[5],
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        let (state, cursor): (Vec<u8>, u64) = db.query_row(
            "SELECT bytes,cursor FROM snapshots WHERE doc_id=?1",
            [chat],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let mut zig = harness_nano_loro::Handle::new(chat)?;
        zig.restore(&state)?;
        let sink = open(&dir, chat);
        let rust = sink.doc.lock().unwrap();
        assert_eq!(
            typed(zig.retained_doc()),
            typed(&rust),
            "typed projection must converge, not snapshot bytes"
        );
        let zv = zig.retained_doc().doc().oplog_vv();
        let rv = rust.doc().oplog_vv();
        assert!(
            zv.includes_vv(&rv) && rv.includes_vv(&zv),
            "mutual binary VV containment"
        );
        if mode == "compare-swift" {
            use loro::ToJson;
            let meta = zig
                .retained_doc()
                .doc()
                .get_map("meta")
                .get_deep_value()
                .to_json_value();
            assert_eq!(meta["swiftCompatibility"], "Swift 1.13.3 🦀");
            let meta = rust.doc().get_map("meta").get_deep_value().to_json_value();
            assert_eq!(meta["swiftCompatibility"], "Swift 1.13.3 🦀");
        }
        println!(
            "RESULT:{}",
            json!({"typedConverged":true,"mutualVV":true,"swiftUpdateApplied":mode=="compare-swift","zigCursor":cursor,"messages":rust.read_entries()?.len()})
        );
        return Ok(());
    }
    let sink = Arc::new(open(&dir, chat));
    if mode == "offline-edit" {
        let update = {
            let doc = sink.doc.lock().unwrap();
            let vv = doc.doc().oplog_vv();
            assert!(doc.set_queued_text("q-rust", "Rust offline edit 🦀", now())?);
            doc.push_queued(&serde_json::from_value(json!({"id":"q-offline","text":"new Rust offline queue row","issuedBy":"retained-rust","issuedAt":now(),"holdForTurnEnd":true}))?)?;
            doc.doc().export(ExportMode::updates(&vv))?
        };
        // Persist local state and stable pending ID before any network call.
        sink.persist(sink.cursor.load(Relaxed))?;
        sink.store
            .enqueue_chat_update(chat, "rust-offline-stable", &update)?;
        std::fs::write(dir.join("offline.update"), &update)?;
        println!(
            "RESULT:{}",
            json!({"offlineBytes":update.len(),"pendingPushes":sink.store.pending_chat_updates(chat)?.len()})
        );
        return Ok(());
    }
    let ws = format!(
        "{}/chat2/{}/ws?device=retained-rust&token={}",
        base.replacen("http://", "ws://", 1),
        chat,
        token
    );
    let fetcher = Arc::new(Fetcher {
        url: format!("{base}/chat2/{chat}/checkpoint"),
        token,
    });
    let client = ChatClient::connect(
        &ws,
        sink.clone(),
        fetcher,
        "retained-rust",
        sink.cursor.load(Relaxed),
    )
    .await?;
    wait_for(|| sink.doc.lock().unwrap().read_entries().unwrap().len() >= 131).await;
    if mode == "send" {
        let update = {
            let doc = sink.doc.lock().unwrap();
            let vv = doc.doc().oplog_vv();
            let command: SessionCommandEntry = serde_json::from_value(
                json!({"id":"remote-command","payload":{"kind":"run","messageId":"remote-message","request":{"prompt":"Remote Loro command executes once","harness":"mock","modelOptions":{},"cwd":args[5],"sandbox":"workspace-write","autoApprove":false}},"issuedBy":"retained-rust","issuedAt":now(),"expiresAt":now()+60000,"basedOn":{"turnId":"synthetic-prior-turn","frontier":"synthetic-based-on"},"status":"pending"}),
            )?;
            doc.queue_command(&command)?;
            doc.doc().export(ExportMode::updates(&vv))?
        };
        sink.persist(sink.cursor.load(Relaxed))?;
        client.enqueue_batch("retained-run-stable".into(), update);
        wait_for(|| {
            let doc = sink.doc.lock().unwrap();
            let entries = doc.read_entries().unwrap();
            entries.iter().any(|m| m.id == "remote-message")
                && entries.last().is_some_and(|m| {
                    m.role == harness_doc::MessageRole::Assistant
                        && m.status == Some(harness_doc::MessageStatus::Complete)
                })
                && doc.read_commands().unwrap().iter().any(|c| {
                    c.id == "remote-command"
                        && c.status == harness_doc::SessionCommandStatus::Applied
                })
        })
        .await;
    }
    wait_for(|| sink.store.pending_chat_updates(chat).unwrap().is_empty()).await;
    // Let any coalesced live outcome/tail-of-stream rows arrive before the
    // caller compares the independently materialized typed projection.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let result = output(&sink, &dir);
    client.shutdown().await;
    println!("RESULT:{result}");
    Ok(())
}
