//! Read-only local token aggregation for the Settings usage view.
//!
//! This module deliberately returns aggregates only: no source paths, session ids,
//! or transcript contents escape the collector.

use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

const MAX_LINE: usize = 2 * 1024 * 1024;
const MAX_FILES: usize = 20_000;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Row {
    pub runtime: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub period_start: String,
    pub as_of: String,
    pub rows: Vec<Row>,
    pub partial: bool,
}

#[derive(Default)]
struct Totals {
    input: u64,
    output: u64,
}

/// Aggregate usage over the local calendar month through `as_of`.
/// Roots are explicit and trusted by the caller; traversal below each root does
/// not follow symlinks. Missing sources are unavailable and therefore partial.
pub(crate) fn collect(
    projects: &[PathBuf],
    codex_home: &Path,
    claude_dir: &Path,
    journals_dir: &Path,
    antigravity_home: &Path,
    as_of: DateTime<Local>,
) -> Result<Snapshot, String> {
    let start = NaiveDate::from_ymd_opt(as_of.year(), as_of.month(), 1).unwrap();
    let start_dt = Local
        .from_local_datetime(&start.and_hms_opt(0, 0, 0).unwrap())
        .single();
    let start_ts = start_dt.map(|d| d.timestamp_millis()).unwrap_or(i64::MIN);
    let end_ts = as_of.timestamp_millis();
    let mut partial = false;
    let mut totals: BTreeMap<(String, String), Totals> = BTreeMap::new();

    let mut seen_runs = HashSet::new();
    for project in projects {
        let graff = project.join(".graff");
        let traces = graff.join("traces");
        let trajectories = graff.join("trajectories");
        if !graff.exists() {
            continue;
        }
        if !traces.exists() || !trajectories.exists() {
            partial = true;
            continue;
        }
        let files = match direct_jsonl_files(&traces) {
            Ok(v) => v,
            Err(()) => {
                partial = true;
                continue;
            }
        };
        for trace in files {
            let run_id = trace
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            if seen_runs.contains(&run_id) {
                continue;
            }
            let trajectory = trajectories.join(trace.file_name().unwrap_or_default());
            let timestamp = match first_line_unix_ms(&trajectory) {
                Ok(Some(t)) => t,
                _ => {
                    partial = true;
                    continue;
                }
            };
            if timestamp > end_ts {
                continue;
            }
            seen_runs.insert(run_id);
            if !parse_trace(&trace, timestamp, start_ts, end_ts, &mut totals) {
                partial = true;
            }
        }
    }

    for dir in [
        codex_home.join("sessions"),
        codex_home.join("archived_sessions"),
    ] {
        match recursive_jsonl_files(&dir) {
            Ok(files) => {
                for path in files {
                    if !parse_codex(&path, start_ts, end_ts, &mut totals) {
                        partial = true;
                    }
                }
            }
            Err(()) => partial = true,
        }
    }

    let journal_sessions = match read_journal_sessions(journals_dir) {
        Ok(v) => v,
        Err(()) => {
            partial = true;
            HashSet::new()
        }
    };
    let claude_projects = claude_dir.join("projects");
    match direct_child_dirs(&claude_projects) {
        Ok(dirs) => {
            for dir in dirs {
                match direct_jsonl_files(&dir) {
                    Ok(files) => {
                        for path in files {
                            if !parse_claude(
                                &path,
                                &journal_sessions,
                                start_ts,
                                end_ts,
                                &mut totals,
                            ) {
                                partial = true;
                            }
                        }
                    }
                    Err(()) => partial = true,
                }
            }
        }
        Err(()) => partial = true,
    }

    match direct_files(
        &antigravity_home
            .join("antigravity-cli")
            .join("conversations"),
    ) {
        Ok(files) => {
            for path in files
                .into_iter()
                .filter(|p| p.extension().is_some_and(|e| e == "db"))
            {
                if !parse_antigravity_db(&path, start_ts, end_ts, &mut totals) {
                    partial = true;
                }
            }
        }
        Err(()) => partial = true,
    }

    let mut rows: Vec<_> = totals
        .into_iter()
        .map(|((runtime, model), t)| Row {
            runtime,
            model,
            input_tokens: t.input,
            output_tokens: t.output,
        })
        .collect();
    rows.sort_by(|a, b| {
        b.input_tokens
            .saturating_add(b.output_tokens)
            .cmp(&a.input_tokens.saturating_add(a.output_tokens))
            .then_with(|| a.runtime.cmp(&b.runtime))
            .then_with(|| a.model.cmp(&b.model))
    });
    Ok(Snapshot {
        period_start: start.format("%Y-%m-%d").to_string(),
        as_of: as_of.to_rfc3339(),
        rows,
        partial,
    })
}

fn add(
    totals: &mut BTreeMap<(String, String), Totals>,
    runtime: &str,
    model: &str,
    input: u64,
    output: u64,
) {
    let t = totals
        .entry((runtime.to_owned(), nonempty_model(model)))
        .or_default();
    t.input = t.input.saturating_add(input);
    t.output = t.output.saturating_add(output);
}
fn nonempty_model(s: &str) -> String {
    if s.trim().is_empty() {
        "Unknown model".into()
    } else {
        s.to_owned()
    }
}

fn safe_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
}
fn direct_child_dirs(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if safe_dir(&p) {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn direct_files(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if fs::symlink_metadata(&p).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn direct_jsonl_files(path: &Path) -> Result<Vec<PathBuf>, ()> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    if !safe_dir(path) {
        return Err(());
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(path).map_err(|_| ())? {
        let e = entry.map_err(|_| ())?;
        let p = e.path();
        if fs::symlink_metadata(&p).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            && p.extension().is_some_and(|e| e == "jsonl")
        {
            out.push(p);
        }
        if out.len() > MAX_FILES {
            return Err(());
        }
    }
    out.sort();
    Ok(out)
}
fn recursive_jsonl_files(root: &Path) -> Result<Vec<PathBuf>, ()> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), ()> {
        if !safe_dir(dir) {
            return Err(());
        }
        for entry in fs::read_dir(dir).map_err(|_| ())? {
            let e = entry.map_err(|_| ())?;
            let p = e.path();
            let md = fs::symlink_metadata(&p).map_err(|_| ())?;
            if md.file_type().is_symlink() {
                continue;
            }
            if md.is_dir() {
                walk(&p, out)?;
            } else if md.is_file() && p.extension().is_some_and(|x| x == "jsonl") {
                out.push(p);
            }
            if out.len() > MAX_FILES {
                return Err(());
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(root, &mut out)?;
    out.sort();
    Ok(out)
}
fn lines(path: &Path, mut f: impl FnMut(&[u8]) -> Result<(), ()>) -> Result<(), ()> {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
        return Err(());
    }
    let file = File::open(path).map_err(|_| ())?;
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf).map_err(|_| ())?;
        if n == 0 {
            break;
        }
        if buf.len() > MAX_LINE {
            return Err(());
        }
        f(&buf)?;
    }
    Ok(())
}
fn first_line_unix_ms(path: &Path) -> Result<Option<i64>, ()> {
    let mut result = None;
    let mut first = true;
    lines(path, |line| {
        if first {
            first = false;
            let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
            result = v.get("unix_ms").and_then(Value::as_i64);
            if result.is_none() {
                return Err(());
            }
        }
        Ok(())
    })?;
    Ok(result)
}
fn parse_trace(
    path: &Path,
    session_start: i64,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        if v.get("ev").and_then(Value::as_str) == Some("usage") {
            let t = v.get("t").and_then(Value::as_i64).ok_or(())?;
            let model = v
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or("Unknown model");
            let input = v.get("input_tokens").and_then(Value::as_u64).ok_or(())?;
            let output = v.get("output_tokens").and_then(Value::as_u64).ok_or(())?;
            // `t` is a trace-relative timestamp; a run may straddle month start.
            let timestamp = session_start.saturating_add(t);
            if timestamp >= start && timestamp <= end {
                add(totals, "Harness", model, input, output);
            }
        }
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}

fn parse_codex(
    path: &Path,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let mut model = "Unknown model".to_owned();
    let mut seen = HashSet::new();
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        let typ = v.get("type").and_then(Value::as_str).unwrap_or("");
        if typ == "turn_context" {
            if let Some(m) = v
                .pointer("/payload/model")
                .or_else(|| v.get("model"))
                .and_then(Value::as_str)
            {
                model = m.to_owned();
            }
        } else if typ == "token_usage_record" {
            let timestamp = v
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_timestamp)
                .or_else(|| {
                    v.pointer("/payload/timestamp")
                        .and_then(Value::as_str)
                        .and_then(parse_timestamp)
                });
            let Some(ts) = timestamp else {
                ok = false;
                return Ok(());
            };
            if ts < start || ts > end {
                return Ok(());
            }
            let payload = v.get("payload").unwrap_or(&Value::Null);
            let usage = payload.get("usage").ok_or(())?;
            let id = payload
                .get("response_id")
                .or_else(|| payload.get("id"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if !id.is_empty() && !seen.insert(id.to_owned()) {
                return Ok(());
            }
            let input = usage
                .get("input_tokens")
                .and_then(Value::as_u64)
                .ok_or(())?;
            let output = usage
                .get("output_tokens")
                .and_then(Value::as_u64)
                .ok_or(())?;
            add(totals, "Codex", &model, input, output);
        }
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}
fn parse_timestamp(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|x| x.timestamp_millis())
}

fn read_journal_sessions(root: &Path) -> Result<HashSet<String>, ()> {
    if !safe_dir(root) {
        return Ok(HashSet::new());
    }
    let files = recursive_jsonl_files(root)?;
    let mut ids = HashSet::new();
    for path in files {
        lines(&path, |line| {
            let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
            let event = v.get("event").unwrap_or(&Value::Null);
            if event.get("type").and_then(Value::as_str) == Some("sessionStarted") {
                if let Some(id) = event.get("sessionId").and_then(Value::as_str) {
                    ids.insert(id.to_owned());
                }
            }
            if let Some(id) = v.get("session_id").and_then(Value::as_str) {
                ids.insert(id.to_owned());
            }
            Ok(())
        })?;
    }
    Ok(ids)
}
fn parse_claude(
    path: &Path,
    allowed: &HashSet<String>,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    let mut ok = true;
    let mut seen = HashSet::new();
    let res = lines(path, |line| {
        let v: Value = serde_json::from_slice(line).map_err(|_| ())?;
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            return Ok(());
        }
        if !v
            .get("sessionId")
            .or_else(|| v.get("session_id"))
            .and_then(Value::as_str)
            .is_some_and(|id| allowed.contains(id))
        {
            return Ok(());
        }
        let ts = v
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_timestamp)
            .ok_or(())?;
        if ts < start || ts > end {
            return Ok(());
        }
        let msg = v.get("message").unwrap_or(&v);
        let id = msg.get("id").and_then(Value::as_str).unwrap_or("");
        if !id.is_empty() && !seen.insert(id.to_owned()) {
            return Ok(());
        }
        let usage = msg.get("usage").ok_or(())?;
        let input = [
            "input_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
        ]
        .iter()
        .filter_map(|k| usage.get(k).and_then(Value::as_u64))
        .fold(0u64, u64::saturating_add);
        let output = usage
            .get("output_tokens")
            .and_then(Value::as_u64)
            .ok_or(())?;
        let model = msg
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("Unknown model");
        add(totals, "Harness", model, input, output);
        Ok(())
    });
    if res.is_err() {
        ok = false;
    }
    ok
}

// Minimal protobuf wire reader. Returns (field number, wire type, scalar, bytes).
fn protobuf_fields(mut b: &[u8]) -> Result<Vec<(u32, u8, u64, &[u8])>, ()> {
    let mut out = Vec::new();
    while !b.is_empty() {
        let (key, n) = varint(b)?;
        b = &b[n..];
        let field = (key >> 3) as u32;
        let wire = (key & 7) as u8;
        if field == 0 {
            return Err(());
        }
        let (scalar, bytes) = match wire {
            0 => {
                let (x, n) = varint(b)?;
                b = &b[n..];
                (x, &b[0..0])
            }
            1 => {
                if b.len() < 8 {
                    return Err(());
                };
                let x = u64::from_le_bytes(b[..8].try_into().unwrap());
                b = &b[8..];
                (x, &b[0..0])
            }
            2 => {
                let (len, n) = varint(b)?;
                b = &b[n..];
                let len = usize::try_from(len).map_err(|_| ())?;
                if len > b.len() {
                    return Err(());
                };
                let x = &b[..len];
                b = &b[len..];
                (0, x)
            }
            5 => {
                if b.len() < 4 {
                    return Err(());
                };
                let x = u32::from_le_bytes(b[..4].try_into().unwrap()) as u64;
                b = &b[4..];
                (x, &b[0..0])
            }
            _ => return Err(()),
        };
        out.push((field, wire, scalar, bytes));
    }
    Ok(out)
}
fn varint(b: &[u8]) -> Result<(u64, usize), ()> {
    let mut x = 0u64;
    for (i, c) in b.iter().enumerate().take(10) {
        x |= ((c & 0x7f) as u64).checked_shl((i * 7) as u32).ok_or(())?;
        if c & 0x80 == 0 {
            return Ok((x, i + 1));
        }
    }
    Err(())
}
fn parse_antigravity_db(
    path: &Path,
    start: i64,
    end: i64,
    totals: &mut BTreeMap<(String, String), Totals>,
) -> bool {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !m.file_type().is_symlink()) {
        return false;
    }
    let conn = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(_) => return false,
    };
    // Antigravity stores each step's protobuf in steps.metadata and model-name
    // mappings in gen_metadata.data. Avoid generic blob/table guessing.
    let mut model_by_step = BTreeMap::new();
    let mut gen_stmt = match conn.prepare("SELECT data FROM gen_metadata") {
        Ok(s) => s,
        Err(_) => return false,
    };
    let gen_rows = match gen_stmt.query_map([], |row| row.get::<_, Vec<u8>>(0)) {
        Ok(rows) => rows,
        Err(_) => return false,
    };
    for data in gen_rows {
        let Ok(data) = data else { continue };
        if data.len() > MAX_LINE {
            continue;
        }
        let Ok(fields) = protobuf_fields(&data) else {
            continue;
        };
        let model = fields
            .iter()
            .filter(|(field, wire, _, _)| *field == 1 && *wire == 2)
            .filter_map(|(_, _, _, bytes)| model_name(bytes))
            .next();
        let Some(model) = model else { continue };
        for (field, wire, scalar, bytes) in fields {
            if field == 2 && wire == 2 {
                let mut offset = 0;
                while offset < bytes.len() {
                    let Ok((index, used)) = varint(&bytes[offset..]) else {
                        break;
                    };
                    offset += used;
                    model_by_step
                        .entry(index as i64)
                        .or_insert_with(|| model.clone());
                }
            } else if field == 2 && wire == 0 {
                model_by_step
                    .entry(scalar as i64)
                    .or_insert_with(|| model.clone());
            }
        }
    }
    let mut steps = match conn
        .prepare("SELECT idx, step_type, metadata FROM steps WHERE step_type IN (15, 23)")
    {
        Ok(s) => s,
        Err(_) => return false,
    };
    let rows = match steps.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, Vec<u8>>(2)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(_) => return false,
    };
    let mut saw_supported_step = false;
    for row in rows {
        let Ok((index, step_type, metadata)) = row else {
            return false;
        };
        if metadata.len() > MAX_LINE {
            return false;
        }
        saw_supported_step = true;
        if let Some((input, output, at_ms)) = agy_usage(&metadata, step_type).ok().flatten() {
            if (start..=end).contains(&at_ms) {
                let model = model_by_step
                    .get(&index)
                    .map(String::as_str)
                    .unwrap_or("Unknown model");
                add(totals, "AGY", model, input, output);
            }
        }
    }
    saw_supported_step
}

fn model_name(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    let prefixes = [
        "gemini-",
        "claude-",
        "gpt-",
        "grok-",
        "deepseek-",
        "kimi-",
        "glm-",
        "ultramarine-",
        "mimo-",
        "qwen-",
    ];
    let mut found = HashSet::new();
    let raw = text.as_bytes();
    for prefix in prefixes {
        let mut cursor = 0;
        while let Some(offset) = text[cursor..].find(prefix) {
            let begin = cursor + offset;
            let mut end = begin;
            while end < raw.len()
                && (raw[end].is_ascii_alphanumeric() || matches!(raw[end], b'.' | b'-' | b'_'))
            {
                end += 1;
            }
            if end > begin + prefix.len() {
                found.insert(
                    text[begin..end]
                        .trim_matches(|c: char| c == '.' || c == '_')
                        .to_owned(),
                );
            }
            cursor = end.max(begin + prefix.len());
            if cursor >= raw.len() {
                break;
            }
        }
    }
    if found.len() == 1 {
        found.into_iter().next()
    } else {
        None
    }
}

fn agy_usage(metadata: &[u8], step_type: i64) -> Result<Option<(u64, u64, i64)>, ()> {
    if !matches!(step_type, 15 | 23) {
        return Ok(None);
    }
    let fields = protobuf_fields(metadata)?;
    let mut stamp = None;
    let mut usage = None;
    for (field, wire, _, bytes) in fields {
        if field == 1 && wire == 2 {
            stamp = Some(bytes);
        }
        if field == 9 && wire == 2 {
            usage = Some(bytes);
        }
    }
    let (Some(stamp), Some(usage)) = (stamp, usage) else {
        return Ok(None);
    };
    let mut seconds = 0i64;
    let mut nanos = 0i64;
    for (field, _, value, _) in protobuf_fields(stamp)? {
        if field == 1 {
            seconds = value as i64;
        }
        if field == 2 {
            nanos = value as i64;
        }
    }
    let at_ms = seconds
        .saturating_mul(1000)
        .saturating_add(nanos / 1_000_000);
    let mut input = None;
    let mut output = None;
    for (field, _, value, _) in protobuf_fields(usage)? {
        match field {
            2 => input = Some(value),
            3 => output = Some(value),
            // Field 5 is an Antigravity prior-token marker, not cache usage.
            _ => {}
        }
    }
    Ok(input
        .zip(output)
        .map(|(input, output)| (input, output, at_ms)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn trace_counts_usage_once_and_sorts_deterministically() {
        let dir = tempdir().unwrap();
        let project = dir.path();
        let trace = project.join(".graff/traces");
        let traj = project.join(".graff/trajectories");
        fs::create_dir_all(&trace).unwrap();
        fs::create_dir_all(&traj).unwrap();
        fs::write(traj.join("a.jsonl"), "{\"unix_ms\":1795300000000}\n").unwrap();
        fs::write(
            trace.join("a.jsonl"),
            "{\"ev\":\"usage\",\"t\":2,\"model\":\"m\",\"input_tokens\":12,\"output_tokens\":3}\n",
        )
        .unwrap();
        let as_of = Local.timestamp_millis_opt(1795300000002).single().unwrap();
        let snap = collect(
            &[project.to_path_buf()],
            &dir.path().join("missing-codex"),
            &dir.path().join("missing-claude"),
            &dir.path().join("missing-journal"),
            &dir.path().join("missing-agy"),
            as_of,
        )
        .unwrap();
        assert_eq!(
            snap.rows
                .iter()
                .find(|r| r.runtime == "Harness")
                .map(|r| (r.input_tokens, r.output_tokens)),
            Some((12, 3))
        );
    }

    #[test]
    fn codex_counts_timestamped_response_usage_once_and_tracks_model_switches() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        fs::write(
            &path,
            concat!(
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-a\"}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r1\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n",
                "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-b\"}}\n",
                "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"payload\":{\"response_id\":\"r2\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n",
                "{\"type\":\"thread_token_usage\",\"payload\":{\"usage\":{\"input_tokens\":999,\"output_tokens\":999}}}\n"
            ),
        )
        .unwrap();
        let timestamp = parse_timestamp("2026-11-22T00:00:00Z").unwrap();
        let mut totals = BTreeMap::new();
        assert!(parse_codex(
            &path,
            timestamp - 1,
            timestamp + 1,
            &mut totals
        ));
        assert_eq!(
            totals
                .get(&("Codex".into(), "gpt-a".into()))
                .map(|t| (t.input, t.output)),
            Some((10, 2))
        );
        assert_eq!(
            totals
                .get(&("Codex".into(), "gpt-b".into()))
                .map(|t| (t.input, t.output)),
            Some((3, 1))
        );
    }

    #[test]
    fn claude_counts_cached_input_only_for_harness_linked_sessions() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("session.jsonl");
        fs::write(
            &path,
            concat!(
                "{\"type\":\"assistant\",\"sessionId\":\"linked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":2,\"cache_read_input_tokens\":3,\"output_tokens\":4}}}\n",
                "{\"type\":\"assistant\",\"sessionId\":\"linked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n",
                "{\"type\":\"assistant\",\"sessionId\":\"unlinked\",\"timestamp\":\"2026-11-22T00:00:00Z\",\"message\":{\"id\":\"m2\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":100,\"output_tokens\":100}}}\n"
            ),
        )
        .unwrap();
        let timestamp = parse_timestamp("2026-11-22T00:00:00Z").unwrap();
        let allowed = HashSet::from(["linked".to_owned()]);
        let mut totals = BTreeMap::new();
        assert!(parse_claude(
            &path,
            &allowed,
            timestamp - 1,
            timestamp + 1,
            &mut totals
        ));
        assert_eq!(
            totals
                .get(&("Harness".into(), "claude-test".into()))
                .map(|t| (t.input, t.output)),
            Some((15, 4))
        );
    }

    #[test]
    fn malformed_trace_is_reported_as_partial() {
        let dir = tempdir().unwrap();
        let project = dir.path();
        let traces = project.join(".graff/traces");
        let trajectories = project.join(".graff/trajectories");
        fs::create_dir_all(&traces).unwrap();
        fs::create_dir_all(&trajectories).unwrap();
        fs::write(
            trajectories.join("bad.jsonl"),
            "{\"unix_ms\":1795300000000}\n",
        )
        .unwrap();
        fs::write(traces.join("bad.jsonl"), "not json\n").unwrap();
        let as_of = Local.timestamp_millis_opt(1795300005000).single().unwrap();
        let snapshot = collect(
            &[project.to_path_buf()],
            &dir.path().join("codex"),
            &dir.path().join("claude"),
            &dir.path().join("journals"),
            &dir.path().join("agy"),
            as_of,
        )
        .unwrap();
        assert!(snapshot.partial);
        assert!(snapshot.rows.is_empty());
    }

    #[test]
    fn antigravity_database_uses_step_metadata_and_excludes_prior_token_marker() {
        fn put_varint(mut n: u64, out: &mut Vec<u8>) {
            while n >= 128 {
                out.push((n as u8) | 0x80);
                n >>= 7;
            }
            out.push(n as u8);
        }
        fn msg(field: u64, bytes: &[u8], out: &mut Vec<u8>) {
            put_varint((field << 3) | 2, out);
            put_varint(bytes.len() as u64, out);
            out.extend_from_slice(bytes);
        }
        fn scalar(field: u64, value: u64, out: &mut Vec<u8>) {
            put_varint(field << 3, out);
            put_varint(value, out);
        }
        let mut stamp = Vec::new();
        scalar(1, 1_795_300_000, &mut stamp);
        let mut usage = Vec::new();
        scalar(1, 1, &mut usage);
        scalar(2, 20, &mut usage);
        scalar(3, 4, &mut usage);
        scalar(5, 999, &mut usage);
        let mut metadata = Vec::new();
        msg(1, &stamp, &mut metadata);
        msg(9, &usage, &mut metadata);
        let mut packed_indices = Vec::new();
        put_varint(1, &mut packed_indices);
        let mut gen_blob = Vec::new();
        msg(1, b"gemini-example", &mut gen_blob);
        msg(2, &packed_indices, &mut gen_blob);
        let dir = tempdir().unwrap();
        let path = dir.path().join("synthetic.db");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB); CREATE TABLE gen_metadata(idx INTEGER, data BLOB);").unwrap();
        db.execute("INSERT INTO steps VALUES(1, 15, ?1)", [&metadata])
            .unwrap();
        db.execute("INSERT INTO gen_metadata VALUES(0, ?1)", [&gen_blob])
            .unwrap();
        drop(db);
        let timestamp = 1_795_300_000_000i64;
        let mut totals = BTreeMap::new();
        assert!(parse_antigravity_db(
            &path,
            timestamp - 1,
            timestamp + 1,
            &mut totals
        ));
        let row = totals
            .get(&("AGY".into(), "gemini-example".into()))
            .unwrap();
        assert_eq!((row.input, row.output), (20, 4));
    }
}
