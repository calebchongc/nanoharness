#!/usr/bin/env bash
# Proves the LEGACY/OFFLINE HZD1 mode builds, tests, packages and runs with
# Zig alone. It does NOT validate retained-Loro synchronization, whose
# explicit -Dloro-lib dependency requires Rust (scripts/local-loro.sh).
# On the committed tree:
#   1. zig build no-rust
#   2. the full test suite, in a fresh cache, from a copy of HEAD that has no
#      crates/, Cargo.toml or Cargo.lock
#   3. the macOS bundle, checked to hold harness-engine and no Rust binary
#   4. the bundle's own harness-engine under a temporary HOME, data folder
#      and free port: a project, a chat on the mock harness, a turn and its
#      reply, a terminal's echo, and git status and diff after an edit
#   5. the desktop app rendered offscreen showing that chat, from that engine
#   6. apps/nano/docs/proof/REPORT.md and the PNGs
# Exits non-zero on any failure. Every step has a deadline and runs in its
# own process group, which is killed at the deadline; everything started is
# stopped on exit. Heavy steps queue on scripts/heavy-build.sh's lock (set
# HARNESS_HEAVY_BUILD_LOCK to share one with other worktrees). Never touches
# the real HOME, data folder, engine port or the preview port 7331.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NANO="$ROOT/apps/nano"
PROOF="$NANO/docs/proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-prove.XXXXXX")"
HEAVY="$ROOT/scripts/heavy-build.sh"
ENGINE_PID=""
RESULTS=()
FAILED=0
unset HARNESS_NANO_ENGINE_BIN HARNESS_NANO_NO_ENGINE_START

cleanup() {
  if [[ -n "$ENGINE_PID" ]]; then
    kill -TERM "-$ENGINE_PID" 2>/dev/null || kill -TERM "$ENGINE_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "-$ENGINE_PID" 2>/dev/null || kill -KILL "$ENGINE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# bounded SECONDS CMD...: run CMD in its own process group; at the deadline
# TERM, then KILL, the whole group and exit 124.
bounded() {
  perl -e '
    my $t = shift;
    my $p = fork();
    die "fork: $!" unless defined $p;
    if ($p == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
    $SIG{ALRM} = sub { kill "TERM", -$p; sleep 2; kill "KILL", -$p; exit 124 };
    alarm $t;
    waitpid($p, 0);
    exit($? >> 8);
  ' "$@"
}

# step NAME SECONDS CMD...: run, time and record one step.
step() {
  local name="$1" secs="$2"
  shift 2
  local log="$WORK/$name.log"
  local start end rc
  start=$(date +%s)
  echo "== $name"
  bounded "$secs" "$@" >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("| $name | pass | $((end - start)) s |")
  else
    [[ $rc -eq 124 ]] && echo "   timed out after ${secs} s" >>"$log"
    RESULTS+=("| $name | **FAIL** (exit $rc) | $((end - start)) s |")
    FAILED=1
    grep -E "^error: '|terminated with signal" "$log" | head -n 20 | sed 's/^/   /'
    tail -n 30 "$log" | sed 's/^/   /'
  fi
  return $rc
}

free_port() {
  python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
ZIG_VERSION="$(zig version)"
if [[ -n "$(git -C "$ROOT" status --porcelain -- apps/nano scripts protocol)" ]]; then
  echo "note: uncommitted changes are not part of the proof (it runs HEAD)" >&2
fi

# 1. The zero-Rust gate.
step no-rust 600 bash -c "cd '$NANO' && '$HEAVY' zig build no-rust --cache-dir '$WORK/gate-cache'"

# 2. The suite, from HEAD without any Rust source, in a fresh cache.
TREE="$WORK/tree"
mkdir -p "$TREE"
git -C "$ROOT" archive HEAD | tar -x -C "$TREE"
rm -rf "$TREE/crates" "$TREE/Cargo.toml" "$TREE/Cargo.lock"
step tests-without-rust 1800 bash -c "cd '$TREE/apps/nano' && '$HEAVY' zig build test --summary all --cache-dir '$WORK/test-cache'"
TEST_TOTALS="$(grep -Eo '[0-9]+/[0-9]+ tests passed[^;]*' "$WORK/tests-without-rust.log" | tail -n 1)"
[[ -z "$TEST_TOTALS" ]] && TEST_TOTALS="$(grep -Eo 'run test [0-9]+ pass[^)]*\)' "$WORK/tests-without-rust.log" | tail -n 1)"

# 3. The macOS bundle: harness-nano and harness-engine, no Rust binary.
APP="$NANO/zig-out/Harness Nano.app"
step bundle 1800 bash -c "cd '$NANO' && rm -rf 'zig-out/Harness Nano.app' && '$HEAVY' sh scripts/bundle.sh"
step bundle-contents 30 bash -c "
  set -e
  test -x '$APP/Contents/MacOS/harness-nano'
  test -x '$APP/Contents/MacOS/harness-engine'
  test ! -e '$APP/Contents/MacOS/harness'
  for f in '$APP'/Contents/MacOS/*; do
    if strings \"\$f\" | grep -q 'rust_begin_unwind'; then echo \"Rust binary: \$f\"; exit 1; fi
  done
  ls '$APP/Contents/MacOS'"

# 4. The bundle's own engine, isolated, driven through its RPC.
HOMEDIR="$WORK/home"
DATA="$WORK/data"
REPO="$WORK/proof-project"
mkdir -p "$HOMEDIR" "$DATA" "$REPO"
PORT="$(free_port)"
ISO_ENV=(env -i "HOME=$HOMEDIR" "TMPDIR=$WORK" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HARNESS_DATA_DIR=$DATA"
  "HARNESS_IPC_PORT=$PORT" "HARNESS_AUTH_DISABLED=1" "HARNESS_PREVIEW_PORT=0" "HARNESS_DISABLE_SHELL_ENV=1"
  "HARNESS_NO_LOGIN_SHELL=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1" "LANG=C")
step proof-repo 30 bash -c "
  set -e
  cd '$REPO'
  git init -q -b main
  printf '# proof project\n' > README.md
  git -c user.name=Synthetic -c user.email=synthetic@example.invalid -c commit.gpgsign=false add README.md
  git -c user.name=Synthetic -c user.email=synthetic@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m init"
if [[ -x "$APP/Contents/MacOS/harness-engine" ]]; then
  perl -e 'setpgrp(0,0); exec @ARGV' "${ISO_ENV[@]}" "$APP/Contents/MacOS/harness-engine" headless >"$WORK/engine.log" 2>&1 &
  ENGINE_PID=$!
  step engine-up 30 bash -c "until nc -z 127.0.0.1 $PORT 2>/dev/null; do sleep 0.2; done"
  step engine-scenario 180 python3 -I "$NANO/scripts/prove_engine.py" "$PORT" "$REPO"
  SCENARIO="$(tail -n 1 "$WORK/engine-scenario.log")"
else
  RESULTS+=("| engine | **FAIL** (no bundled harness-engine) | 0 s |")
  FAILED=1
  SCENARIO="{}"
fi

# 5. The desktop app, offscreen, showing that chat from that engine.
mkdir -p "$PROOF"
rm -f "$PROOF"/*.png
step desktop-render 120 "${ISO_ENV[@]}" "HARNESS_NANO_NO_ENGINE_START=1" "HARNESS_SETUP_OFF=1" "HARNESS_NANO_OPEN_CHAT=chat-proof" \
  "$APP/Contents/MacOS/harness-nano" "--nanoui-snapshot=$PROOF/desktop-chat.png" "--nanoui-wait=6"
test -s "$PROOF/desktop-chat.png" || { RESULTS+=("| desktop-png | **FAIL** (no image) | 0 s |"); FAILED=1; }
IOS_NOTE="skipped: a booted simulator holds the person's own Harness install, which the proof does not replace"
if ! xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
  IOS_NOTE="skipped: no simulator is booted"
fi

# Stop the engine before writing the report.
if [[ -n "$ENGINE_PID" ]]; then
  kill -TERM "-$ENGINE_PID" 2>/dev/null || true
  sleep 1
  kill -KILL "-$ENGINE_PID" 2>/dev/null || true
  ENGINE_PID=""
fi

# 6. The report: synthetic names only, no local paths.
FAKE_ARMS="$(grep -c '^    \.{ \.method = "' "$NANO/src/fake_arm_gate.zig")"
SCENARIO_CLEAN="$(printf '%s' "$SCENARIO" | sed -e "s#$WORK#<tmp>#g")"
{
  echo "# Zig-only legacy/offline proof"
  echo
  echo "This proof does not validate retained-Loro sync; that explicit mode requires Rust."
  echo
  echo "- Commit: \`$COMMIT\`"
  echo "- Zig: $ZIG_VERSION"
  echo "- Result: $([[ $FAILED -eq 0 ]] && echo pass || echo FAIL)"
  echo "- Tests (no crates/, Cargo.toml or Cargo.lock): ${TEST_TOTALS:-unknown}"
  echo "- Fake arms (RPC methods still answering canned data, src/fake_arm_gate.zig): $FAKE_ARMS"
  echo
  echo "| Step | Result | Time |"
  echo "|---|---|---|"
  printf '%s\n' "${RESULTS[@]}"
  echo
  if grep -qE "^error: '" "$WORK/tests-without-rust.log" 2>/dev/null; then
    echo "## Failed tests"
    echo
    grep -E "^error: '" "$WORK/tests-without-rust.log" | sed -e "s#$WORK#<tmp>#g" -e 's/^error: /- /' | head -n 20
    echo
  fi
  echo "## Engine scenario"
  echo
  echo "The bundle's harness-engine, isolated (temporary HOME, data folder and port, auth off, previews on a free port):"
  echo
  echo '```json'
  echo "$SCENARIO_CLEAN"
  echo '```'
  echo
  echo "## Images"
  echo
  [[ -s "$PROOF/desktop-chat.png" ]] && echo "![The desktop app showing the proof chat](desktop-chat.png)"
  echo
  echo "iOS simulator: $IOS_NOTE."
} >"$PROOF/REPORT.md"
echo "wrote apps/nano/docs/proof/REPORT.md"
exit $FAILED
