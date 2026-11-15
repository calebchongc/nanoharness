//! Subprocess helpers delegating auxiliary non-engine work (`visual-check`,
//! `preview-servers`, etc.) to the native Zig `harness` CLI binary.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::Deserialize;
use tokio::io::AsyncWriteExt;

#[cfg(windows)]
const ZIG_CLI_NAME: &str = "harness.exe";
#[cfg(not(windows))]
const ZIG_CLI_NAME: &str = "harness";

#[derive(Debug, Deserialize)]
struct ZigLocalServer {
    port: u16,
    url: String,
    name: String,
    folder: Option<String>,
}

/// Locate the Zig `harness` binary, checking `HARNESS_ZIG_CLI`, a sibling next
/// to the current executable, the workspace Zig build output, and `/Applications`.
pub fn find_zig_cli() -> Option<PathBuf> {
    if let Some(raw) = std::env::var_os("HARNESS_ZIG_CLI") {
        let path = PathBuf::from(raw);
        if !path.as_os_str().is_empty() && path.is_file() {
            return Some(path);
        }
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        let sibling = dir.join(ZIG_CLI_NAME);
        if sibling != exe && sibling.is_file() {
            return Some(sibling);
        }
    }
    let dev = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/nano/zig-out/bin")
        .join(ZIG_CLI_NAME);
    if dev.is_file() {
        return Some(dev);
    }
    #[cfg(target_os = "macos")]
    {
        let bundle = Path::new("/Applications/Harness.app/Contents/MacOS/harness");
        if bundle.is_file() {
            return Some(bundle.to_path_buf());
        }
    }
    None
}

/// Validate a Luau `show_visual` script by piping it into `harness visual-check`.
pub async fn visual_check(script: &str) -> Result<(), String> {
    let Some(cli) = find_zig_cli() else {
        return Err("Zig harness helper binary not found".into());
    };
    let mut child = tokio::process::Command::new(cli)
        .arg("visual-check")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("failed to launch visual-check helper: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(script.as_bytes())
            .await
            .map_err(|e| format!("failed writing script to visual-check: {e}"))?;
        let _ = stdin.shutdown().await;
    }

    let output = child
        .wait_with_output()
        .await
        .map_err(|e| format!("failed waiting on visual-check: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let msg = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if msg.is_empty() {
            Err("visual check failed".into())
        } else {
            Err(msg)
        }
    }
}

/// Scan local loopback HTTP servers via `harness preview-servers --ignore-pid`.
pub fn scan_local_servers(ignore_pid: u32) -> Vec<crate::localhost_view::LocalServer> {
    let Some(cli) = find_zig_cli() else {
        return Vec::new();
    };
    let output = match std::process::Command::new(cli)
        .args(["preview-servers", "--ignore-pid", &ignore_pid.to_string()])
        .output()
    {
        Ok(out) if out.status.success() => out,
        _ => return Vec::new(),
    };
    let parsed: Vec<ZigLocalServer> = match serde_json::from_slice(&output.stdout) {
        Ok(rows) => rows,
        Err(_) => return Vec::new(),
    };
    parsed
        .into_iter()
        .take(crate::localhost_view::MAX_SERVERS)
        .map(|row| crate::localhost_view::LocalServer {
            port: row.port,
            url: row.url,
            name: row.name,
            folder: row.folder,
        })
        .collect()
}
