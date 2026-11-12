//! Small project-owned C ABI over the retained harness-doc schema and locked
//! loro 1.13.x core. Not the upstream loro-ffi/UniFFI bindings. Handles are
//! single-owner, externally serialized; buffers must be freed by buffer_free.
use harness_doc::{
    QueuedMessage, SegmentWriter, SessionCommandEntry, SessionDoc, SessionMessageEntry,
};
use loro::{ExportMode, LoroDoc, VersionVector};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::panic::{AssertUnwindSafe, catch_unwind};

type Result<T> = std::result::Result<T, String>;
const MAX_INPUT: usize = 128 * 1024 * 1024;

pub struct Handle {
    doc: SessionDoc,
    chat: String,
    baseline: Value,
    // Unresolved incoming bytes are NOT outgoing-unacked updates. Loro 1.13.9
    // omits them from ordinary exports, so private persistence retains both.
    pending: Vec<Vec<u8>>,
    outbound_from: Option<VersionVector>,
}

#[derive(Serialize, Deserialize)]
struct Persistent {
    snapshot: Vec<u8>,
    pending: Vec<Vec<u8>>,
    outbound_from: Option<Vec<u8>>,
}

impl Handle {
    pub fn new(chat: &str) -> Result<Self> {
        let doc = SessionDoc::from_doc(LoroDoc::new());
        Ok(Self {
            doc,
            chat: chat.into(),
            baseline: json!({"transcript":{"reset":[]},"queue":{"items":[]},"commands":[]}),
            pending: vec![],
            outbound_from: None,
        })
    }

    pub fn retained_doc(&self) -> &SessionDoc {
        &self.doc
    }

    pub fn projection(&self) -> Result<Value> {
        Ok(
            json!({"chatId":self.chat,"transcript":{"reset":self.doc.read_entries().map_err(err)?},
            "queue":{"items":self.doc.read_queue().map_err(err)?},"commands":self.doc.read_commands().map_err(err)?}),
        )
    }

    /// Apply only changes relative to the last materialized projection. The
    /// document, IDs, nested containers and LoroText lineage are never replaced.
    pub fn reconcile(&mut self, input: &[u8]) -> Result<()> {
        let next: Value = serde_json::from_slice(input).map_err(err)?;
        let before = self.doc.doc().oplog_vv();
        let messages = next
            .pointer("/transcript/reset")
            .and_then(Value::as_array)
            .ok_or("missing transcript")?;
        let old = self
            .baseline
            .pointer("/transcript/reset")
            .and_then(Value::as_array)
            .unwrap();
        for v in messages {
            let id = v["id"].as_str().ok_or("message id")?;
            if old.iter().find(|m| m["id"] == id) == Some(v) {
                continue;
            }
            let mut entry = v.clone();
            if entry.get("deviceId").is_none() {
                entry["deviceId"] = next["deviceId"].as_str().unwrap_or("nano").into();
            }
            let entry: SessionMessageEntry = serde_json::from_value(entry).map_err(err)?;
            let current = self.doc.read_entries().map_err(err)?;
            if let Some((i, existing)) = current.iter().enumerate().find(|(_, m)| m.id == id) {
                let mut writer = SegmentWriter::resume(&self.doc, i, existing.parts.clone());
                writer.sync(&entry.parts).map_err(err)?;
                if let Some(status) = entry.status {
                    self.doc.set_message_status(id, status).map_err(err)?;
                }
            } else {
                self.doc.push_message(&entry).map_err(err)?;
            }
        }
        let oldq = self
            .baseline
            .pointer("/queue/items")
            .and_then(Value::as_array)
            .unwrap();
        let queue = next
            .pointer("/queue/items")
            .and_then(Value::as_array)
            .ok_or("missing queue")?;
        for prev in oldq {
            let id = prev["id"].as_str().ok_or("queue id")?;
            if !queue.iter().any(|q| q["id"] == id) {
                self.doc.remove_queued(id).map_err(err)?;
            }
        }
        for (i, v) in queue.iter().enumerate() {
            let id = v["id"].as_str().ok_or("queue id")?;
            let prev = oldq.iter().find(|q| q["id"] == id);
            if prev != Some(v) {
                let mut v = v.clone();
                if let Some(g) = v.get_mut("deliveryGate").and_then(Value::as_object_mut) {
                    // Nano's projection predates this required field; preserve a
                    // deterministic base rather than dropping the edit barrier.
                    g.entry("baseTextHash")
                        .or_insert_with(|| Value::String(String::new()));
                }
                let item: QueuedMessage = serde_json::from_value(v).map_err(err)?;
                if self
                    .doc
                    .read_queue()
                    .map_err(err)?
                    .iter()
                    .any(|q| q.id == id)
                {
                    self.doc
                        .set_queued_text(id, &item.text, item.edited_at.unwrap_or(item.issued_at))
                        .map_err(err)?;
                    self.doc
                        .set_queued_delivery_gate(id, item.delivery_gate.as_ref())
                        .map_err(err)?;
                } else {
                    self.doc.push_queued(&item).map_err(err)?;
                }
            }
            if oldq.get(i).map(|q| &q["id"]) != Some(&v["id"]) {
                self.doc.move_queued(id, i).map_err(err)?;
            }
        }
        if let Some(commands) = next["commands"].as_array() {
            let oldc = self.baseline["commands"].as_array().unwrap();
            for v in commands {
                let id = v["id"].as_str().ok_or("command id")?;
                if oldc.iter().find(|c| c["id"] == id) == Some(v) {
                    continue;
                }
                let mut v = v.clone();
                v["status"] = match v["status"].as_str().unwrap_or("pending") {
                    "completed" => "applied",
                    "failed" => "rejected",
                    "running" => "pending",
                    s => s,
                }
                .into();
                if v["payload"].get("kind").is_none() {
                    let text = v["payload"].as_str().unwrap_or("");
                    v["payload"] = match v["kind"].as_str().unwrap_or("interrupt") {
                        "run" => {
                            json!({"kind":"run","messageId":id,"request":{"prompt":text,"cwd":".","sandbox":"workspace-write","autoApprove":false}})
                        }
                        "steer" => json!({"kind":"steer","messageId":id,"prompt":text}),
                        "respondInput" | "respond_input" => {
                            json!({"kind":"respondInput","requestId":text,"answers":[]})
                        }
                        "dismissInput" | "dismiss_input" => {
                            json!({"kind":"dismissInput","requestId":text})
                        }
                        _ => json!({"kind":"interrupt"}),
                    };
                }
                let cmd: SessionCommandEntry = serde_json::from_value(v).map_err(err)?;
                if self
                    .doc
                    .read_commands()
                    .map_err(err)?
                    .iter()
                    .any(|c| c.id == id)
                {
                    self.doc
                        .set_command_status(id, cmd.status, cmd.resolution.as_deref())
                        .map_err(err)?;
                } else {
                    self.doc.queue_command(&cmd).map_err(err)?;
                }
            }
        }
        if self.doc.doc().oplog_vv() != before {
            let meta = self.doc.doc().get_map("meta");
            if self.doc.chat_id().is_none() {
                meta.insert("chatId", self.chat.as_str()).map_err(err)?;
                meta.insert("schemaVersion", 1_i64).map_err(err)?;
            }
            self.doc.doc().commit();
            if self.outbound_from.is_none() {
                self.outbound_from = Some(before);
            }
        }
        // Keep the input shape: fields unknown to the Zig projection are not
        // rewritten merely because a retained client supplied richer metadata.
        self.baseline = next;
        Ok(())
    }

    pub fn import(&mut self, bytes: &[u8]) -> Result<bool> {
        let status = self.doc.doc().import(bytes).map_err(err)?;
        if status.pending.is_some() && !self.pending.iter().any(|b| b == bytes) {
            self.pending.push(bytes.to_vec());
        }
        // Re-import retained raw rows after every prerequisite. No undocumented
        // export_pending_updates API and no dependency-version bump required.
        let mut previous = usize::MAX;
        while previous != self.pending.len() {
            previous = self.pending.len();
            let mut remaining = Vec::new();
            for b in std::mem::take(&mut self.pending) {
                if self.doc.doc().import(&b).map_err(err)?.pending.is_some() {
                    remaining.push(b);
                }
            }
            self.pending = remaining;
        }
        self.baseline = self.projection()?;
        Ok(!self.pending.is_empty())
    }

    pub fn persistent(&self) -> Result<Vec<u8>> {
        let state = Persistent {
            snapshot: self.doc.export_snapshot().map_err(err)?,
            pending: self.pending.clone(),
            outbound_from: self.outbound_from.as_ref().map(VersionVector::encode),
        };
        let mut bytes = b"NLR1".to_vec();
        bytes.extend(serde_json::to_vec(&state).map_err(err)?);
        Ok(bytes)
    }

    pub fn restore(&mut self, bytes: &[u8]) -> Result<()> {
        let state: Persistent = serde_json::from_slice(
            bytes
                .strip_prefix(b"NLR1")
                .ok_or("not local Loro persistence")?,
        )
        .map_err(err)?;
        let raw = LoroDoc::new();
        let status = raw.import(&state.snapshot).map_err(err)?;
        if status.pending.is_some() {
            return Err("persistent snapshot has missing dependencies".into());
        }
        let doc = SessionDoc::from_doc(raw);
        if doc.chat_id().is_some_and(|id| id != self.chat) {
            return Err("chat identity mismatch".into());
        }
        self.doc = doc;
        self.pending.clear();
        for b in state.pending {
            self.import(&b)?;
        }
        self.outbound_from = state
            .outbound_from
            .map(|b| VersionVector::decode(&b).map_err(err))
            .transpose()?;
        self.baseline = self.projection()?;
        Ok(())
    }

    fn call(&mut self, op: u32, bytes: &[u8]) -> Result<(i32, Vec<u8>)> {
        Ok(match op {
            1 => {
                self.reconcile(bytes)?;
                (0, vec![])
            }
            2 => (0, serde_json::to_vec(&self.projection()?).map_err(err)?),
            3 => (0, self.doc.export_snapshot().map_err(err)?),
            4 => {
                let pending = self.import(bytes)?;
                (i32::from(pending), vec![])
            }
            5 => (0, self.doc.doc().oplog_vv().encode()),
            6 => {
                let yes = VersionVector::decode(bytes)
                    .is_ok_and(|v| !v.is_empty() && self.doc.doc().oplog_vv().includes_vv(&v));
                (0, vec![u8::from(yes)])
            }
            7 => (0, self.persistent()?),
            8 => {
                self.restore(bytes)?;
                (0, vec![])
            }
            9 => (
                0,
                match &self.outbound_from {
                    Some(vv) => self
                        .doc
                        .doc()
                        .export(ExportMode::updates(vv))
                        .map_err(err)?,
                    None => vec![],
                },
            ),
            10 => {
                self.outbound_from = None;
                (0, vec![])
            }
            11 => (i32::from(!self.pending.is_empty()), vec![]),
            12 => {
                let vv = VersionVector::decode(bytes).map_err(err)?;
                (
                    0,
                    self.doc
                        .doc()
                        .export(ExportMode::updates(&vv))
                        .map_err(err)?,
                )
            }
            13 => {
                self.baseline = serde_json::from_slice(bytes).map_err(err)?;
                (0, vec![])
            }
            14 => {
                let now: i64 = serde_json::from_slice(bytes).map_err(err)?;
                let commands = self.doc.read_commands().map_err(err)?;
                let messages = self.doc.read_entries().map_err(err)?;
                let current = messages
                    .iter()
                    .rev()
                    .find(|m| m.role == harness_doc::MessageRole::Assistant)
                    .map(|m| m.id.as_str());
                let past = |id: &str| {
                    messages.iter().any(|m| {
                        m.id == id && m.status != Some(harness_doc::MessageStatus::Streaming)
                    })
                };
                let cx = harness_doc::EvaluationContext {
                    is_processed: &|_| false,
                    now_ms: now,
                    entries: &commands,
                    current_turn_id: current,
                    turn_is_past: &past,
                };
                let mut pending = Vec::new();
                for cmd in &commands {
                    if cmd.status != harness_doc::SessionCommandStatus::Pending {
                        continue;
                    }
                    let disposition = match harness_doc::evaluate_command(cmd, &cx) {
                        harness_doc::CommandDisposition::Execute => "execute",
                        harness_doc::CommandDisposition::Expired => "expired",
                        harness_doc::CommandDisposition::Superseded => "superseded",
                        harness_doc::CommandDisposition::Skip => "skip",
                    };
                    let mut v = serde_json::to_value(cmd).map_err(err)?;
                    v["disposition"] = disposition.into();
                    pending.push(v);
                }
                (0, serde_json::to_vec(&pending).map_err(err)?)
            }
            _ => return Err("unknown ABI operation".into()),
        })
    }
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[repr(C)]
pub struct Buffer {
    pub ptr: *mut u8,
    pub len: usize,
}
impl Buffer {
    fn from_vec(v: Vec<u8>) -> Self {
        let boxed = v.into_boxed_slice();
        let len = boxed.len();
        Self {
            ptr: Box::into_raw(boxed) as *mut u8,
            len,
        }
    }
}

/// # Safety
/// Non-null input spans and output pointers must be valid for the call; the
/// returned handle is exclusively owned until harness_loro_free. A handle
/// must not be called concurrently or used after free. No panic crosses C.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_loro_new(
    p: *const u8,
    n: usize,
    out: *mut *mut Handle,
    result: *mut Buffer,
) -> i32 {
    if out.is_null() || result.is_null() {
        return -1;
    }
    unsafe {
        *out = std::ptr::null_mut();
        *result = Buffer::from_vec(vec![]);
    }
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<Handle> {
        let b = unsafe { input(p, n)? };
        Handle::new(std::str::from_utf8(b).map_err(err)?)
    }));
    match r {
        Ok(Ok(h)) => {
            unsafe {
                *out = Box::into_raw(Box::new(h));
            }
            0
        }
        other => {
            let msg = match other {
                Ok(Err(e)) => e,
                _ => "Rust panic caught at Loro ABI".into(),
            };
            unsafe {
                *result = Buffer::from_vec(msg.into_bytes());
            }
            -1
        }
    }
}
unsafe fn input<'a>(p: *const u8, n: usize) -> Result<&'a [u8]> {
    if n > MAX_INPUT || (p.is_null() && n != 0) {
        return Err("invalid ABI input span".into());
    }
    if n == 0 {
        Ok(&[])
    } else {
        Ok(unsafe { std::slice::from_raw_parts(p, n) })
    }
}

/// # Safety
/// Same span/ownership rules as new; out receives a Rust-owned buffer on
/// success or error. Free it exactly once with harness_loro_buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_loro_call(
    h: *mut Handle,
    op: u32,
    p: *const u8,
    n: usize,
    out: *mut Buffer,
) -> i32 {
    if out.is_null() {
        return -1;
    }
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<(i32, Vec<u8>)> {
        let h = unsafe { h.as_mut() }.ok_or("null document handle")?;
        h.call(op, unsafe { input(p, n)? })
    }));
    let (code, bytes) = match r {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => (-1, e.into_bytes()),
        Err(_) => (-2, b"Rust panic caught at Loro ABI".to_vec()),
    };
    unsafe {
        *out = Buffer::from_vec(bytes);
    }
    code
}

/// # Safety
/// h must be a live handle returned by new, or null. Drop exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_loro_free(h: *mut Handle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !h.is_null() {
            drop(unsafe { Box::from_raw(h) });
        }
    }));
}

/// # Safety
/// b must be an unfreed buffer returned by this ABI, unmodified.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn harness_loro_buffer_free(b: Buffer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !b.ptr.is_null() {
            drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.ptr, b.len)) });
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pending_dependency_survives_local_persistence_and_replays() {
        let source = SessionDoc::init("synthetic-pending").unwrap();
        let a = source.export_snapshot().unwrap();
        let vv = source.doc().oplog_vv();
        source
            .doc()
            .get_map("meta")
            .insert("marker", "after foundation 🦀")
            .unwrap();
        source.doc().commit();
        let b = source.doc().export(ExportMode::updates(&vv)).unwrap();
        let mut receiver = Handle::new("synthetic-pending").unwrap();
        assert!(receiver.import(&b).unwrap());
        let state = receiver.persistent().unwrap();
        let mut restored = Handle::new("synthetic-pending").unwrap();
        restored.restore(&state).unwrap();
        assert_eq!(restored.pending, vec![b]);
        assert!(!restored.import(&a).unwrap());
        assert!(restored.pending.is_empty());
        assert_eq!(
            restored.doc.doc().get_map("meta").get_deep_value(),
            source.doc().get_map("meta").get_deep_value()
        );
        assert_eq!(
            restored.doc.read_entries().unwrap(),
            source.read_entries().unwrap()
        );
        assert_eq!(
            restored.doc.read_queue().unwrap(),
            source.read_queue().unwrap()
        );
        let vv = source.doc().oplog_vv().encode();
        assert_eq!(restored.call(6, &vv).unwrap().1, vec![1]);
    }
    #[test]
    fn abi_rejects_null_spans_and_returns_owned_errors() {
        let mut out = Buffer {
            ptr: std::ptr::null_mut(),
            len: 0,
        };
        assert!(
            unsafe { harness_loro_call(std::ptr::null_mut(), 3, std::ptr::null(), 0, &mut out) }
                < 0
        );
        assert!(out.len > 0);
        unsafe {
            harness_loro_buffer_free(out);
        }
    }
}
