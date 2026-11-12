# harness-nano

Harness's desktop app on [nanoui](https://github.com/justrach/nanoui), in Zig.

Its engine is `harness-engine`, also in Zig (`src/engine_main.zig`): it keeps
the workspaces, sessions and agents, runs each agent's turns, and serves the
local WebSocket RPC the app talks to (the same RPC the Rust engine served,
so the GPUI app and this one can be open on one engine at once).
`harness-engine headless` is the engine; `harness-engine daemon install`
runs it as a service, and `harness-engine mcp` is Harness's MCP server.

HTTPS goes through [http-zig](https://github.com/justrach/http-zig), the HTTP/2
client codegraff uses. For now it fetches the newest release's manifest.

## What it does

- Sidebar: your spaces and their chats, newest first, with each chat's status
  (working, waiting for you, errored). **Add folder** adds a space on this
  device. Workspaces and their panel tabs stay in ordinary navigation;
  **Chat history** reopens conversations, including archived ones.
- Chat: the transcript as it streams in, with Markdown replies (code
  highlighted, with a Copy button), reasoning, and each tool call with how it
  went. In Compact mode, progress stays visible while a turn runs and
  folds when it finishes; the final reply stays visible and the work can
  be reopened.
- Composer: Return sends, Shift-Return starts a new line, **Stop** interrupts a
  running turn. A new chat picks its agent, model, and execution computer
  through **Run on**. Choosing another computer clears an incompatible
  project; an existing conversation stays on its original host. Drop local
  files or images into a chat pane to attach them to that pane (24 MB per
  file), or use the attachment picker. Rejected files show an explanation.
- Agent rows stay visible and open their live transcript in a side tab without
  leaving the parent chat. Finished agents use their saved transcript, falling
  back to the document feed if the snapshot is unavailable.
- A native Browser side tab opens websites, localhost previews and generated
  HTML/MCP App pages. Transcript links open there, not in a separate browser.
  See [the browser's boundaries and checks](../../docs/nano-browser.md).

Also: answering the agent's questions, the message queue, the changes pane
and file explorer, project actions with their terminal dock, attachments,
dictation, pins and settings.

Not there yet: typing into the dock, split diffs, editing files,
dragging queued messages, Linux and Windows.

## Release status

This is a macOS preview, not a feature-complete replacement for the GPUI app.
A passing screenshot comparison covers the scenes and GPUI revision in this
checkout; it does not prove parity with newer desktop changes or the missing
interactions above. Bring the GPUI reference up to date before a release
parity run.

The version is `build.zig.zon`'s `.version`: the app, the engine, the iOS
bundle and the macOS bundler's two version fields all read it, so a release
bumps it there. The bundler builds the app icon from `dist/macos/icon-1024.png`
and ad-hoc signs the completed app. Public distribution still needs
Developer ID signing and notarization, passing unit and shared protocol
tests, and, while the GPUI app is the visual reference, a strict visual run
(`--max-changed 0.0005`, below; the only step that needs Rust). An ad-hoc signature
check alone is not a public-distribution gate.

## Build and run

You need Zig 0.17.0 and, on macOS, Xcode or the Command Line Tools. Nothing
else: no Rust toolchain, and nothing from `crates/`.

```sh
cd apps/nano
zig build test          # unit tests
zig build no-rust       # fails if the build, scripts/ or a test reaches for Rust
zig build run           # build and open the window
sh scripts/bundle.sh    # release build as zig-out/Harness Nano.app
zig build snap -- scenes/narrow-panes.json /tmp/nano-snap   # draw a scene offscreen
open "zig-out/Harness Nano.app"
sh scripts/ios.sh sim       # iOS Simulator app, zig-out/ios/Harness.app
sh scripts/ios.sh device    # the same for devices (aarch64-ios)
zig build --release=safe -Dtarget=x86_64-linux-gnu     # cross-compile
zig build --release=safe -Dtarget=x86_64-windows-gnu
```

`scripts/ios.sh` exists because Zig 0.17.0's std can't build for iOS as it
ships; it passes the patched lib folder the pinned nanoui's
`tools/ios/zig-lib.sh` makes. Off Apple platforms SQLite is compiled from the
amalgamation pinned in `build.zig.zon` (fetched only for those targets); on
macOS and iOS the SDK's libsqlite3 is linked.

The bundler forwards Zig build arguments. When testing a local nanoui fork,
use the same override for the release app: `sh scripts/bundle.sh --fork=/path/to/nanoui`.
Otherwise it builds the dependency pinned in `build.zig.zon`.

harness-nano needs an engine. When one already answers on the port, it uses
that one. When nothing answers, it starts `harness-engine headless` itself
(the `harness-engine` beside its own executable, then
`/Applications/Harness.app`, `~/Applications/Harness.app`, then `PATH`;
`HARNESS_NANO_ENGINE_BIN` names another, but never the Rust `harness`), with
its own environment, and writes the engine's output to
`harness-nano-engine.log` in Harness's logs folder. That engine keeps running
when harness-nano quits: it holds the chats' runs, and other windows and
chats attach to it. Stop it with `harness-engine daemon stop` or by its pid
in `engine.lock` in the data folder. Set `HARNESS_NANO_NO_ENGINE_START` to
wait for an engine instead. `sh scripts/bundle.sh` packages only the app;
`scripts/package-macos.sh` (at the repository root) ships the app and
`harness-engine` together.

harness-nano connects to `127.0.0.1:27664`. Set `HARNESS_IPC_PORT` to use
another engine.

## Proving it builds and runs with Zig alone

```sh
HARNESS_HEAVY_BUILD_LOCK=/path/to/a.lock scripts/prove-zig.sh   # from the repository root
```

One command, on the committed tree: `zig build no-rust`; the full test suite
in a fresh cache from a copy of HEAD with no `crates/`, `Cargo.toml` or
`Cargo.lock`; the macOS bundle, checked to hold `harness-engine` and no Rust
binary; the bundle's own engine under a temporary HOME, data folder and port
(a project, a chat on the `mock` harness, a turn and its reply, a terminal's
`echo`, git status and diff after an edit, through `scripts/prove_engine.py`);
and the desktop app rendered offscreen showing that chat. Every step has a
deadline, everything it starts is stopped, and it never touches the real
HOME, data folder, engine port or the preview port 7331. It writes
`docs/proof/REPORT.md` and the image, and exits non-zero on any failure.

## Trying it against a throwaway engine

To keep your own chats out of it, run a second engine with its own port, data
and home:

```sh
zig build                       # zig-out/bin/harness-nano and harness-engine
dir=$(mktemp -d)
env -u HARNESS_NANO_ENGINE_BIN HARNESS_IPC_PORT=27990 HARNESS_DATA_DIR="$dir/data" \
  HOME="$dir/home" HARNESS_AUTH_DISABLED=1 zig-out/bin/harness-engine headless &
HARNESS_IPC_PORT=27990 HARNESS_DATA_DIR="$dir/data" HOME="$dir/home" zig build run
```

`HARNESS_NANO_HARNESS` sets the agent new chats start with. With no graff
installed in that home, a graff chat's turn is acknowledged in place, without
a model or an account; other agents need their CLI on `PATH`.

nanoui's flags render the window offscreen, with no window on screen, for
checks and screenshots:

```sh
HARNESS_IPC_PORT=27990 zig-out/bin/harness-nano --nanoui-snapshot=/tmp/nano.png \
  --nanoui-wait=3 --nanoui-script="click:Do anything…;type:Hello;key:enter;live:8"
```

To open a chat at launch (for those checks), set `HARNESS_NANO_OPEN_CHAT` to
its id.

## Against the edge Worker, run locally

`scripts/local-edge.sh` (at the repository root) runs the real edge Worker
from `edge/` with `wrangler dev --local` and this engine against it:

```sh
scripts/local-edge.sh check            # end-to-end proof, one line per step
scripts/local-edge.sh check --repeat 3 --proof   # and rewrite docs/proof/LOCAL-EDGE.md
scripts/local-edge.sh up --phone       # leave it running, with the app open
scripts/local-edge.sh status
scripts/local-edge.sh down
```

`check` signs a made-up user in on two engines (two devices), runs a mock
turn, asks the Worker itself for the chat's row and history, relays a
prompt and an attachment from the second device to the host, uses a room
and a tool blob, restarts the edge and the host, and stops everything,
exiting 1 if a step fails. `up` leaves the edge, a signed-in engine with a
seeded chat and the `harness-nano` window running on that throwaway profile
(`--phone` adds a second device in the phone layout), and prints the ports,
the state folder and how to stop it. A watchdog stops it after two hours
(`--ttl-minutes`).

It needs Node 20 or newer and `edge/node_modules` (the script runs
`npm ci` in `edge/` once if it is missing, so wrangler is the lockfile's),
and builds with `zig build` through `scripts/heavy-build.sh` unless
`LOCAL_EDGE_NO_BUILD=1`. Nothing leaves the machine: the Worker runs in
Miniflare with `edge/wrangler.local.jsonc` (no account, no routes, made-up
values, explicit `AUTH_MODE=local`), its state lives in a temporary folder,
and every user, repo and device is made up. The runner creates a fresh
opaque session per run; the engine requires `HARNESS_LOCAL_EDGE_AUTH=1`
and a literal `http://127.0.0.1:<port>` origin, then asks the Worker to
verify that session before signing in. Missing, forged and stale sessions
fail closed. Local mode cannot exchange or refresh production credentials. Wrangler's telemetry, update check and
`request.cf` download are off, the app skips its release check, and `check`
reports any non-loopback connection it sees from the processes it started.
See `docs/proof/LOCAL-EDGE.md` for how sign-in works there and what the run
found.

## Tests that it keeps the desktop's rules

`protocol/desktop/` holds the desktop's rules as data: the sidebar's rules (times, status marks, order), tool chips
and group summaries, how transcript frames apply, the theme's roles, and every request this app sends the engine.
`zig build test` runs them (`src/parity.zig`). The Rust desktop's runners for the same files
(`crates/*/tests/desktop_*`) are the behaviour reference only: nothing here builds or runs them. See
`protocol/desktop/README.md`.

After changing a request on purpose: `zig build vectors`.

The engine's RPC contract (method names, `Mutate` ops, queued-edit actions,
command kinds, queue gates) and its doc and sync constants are data too:
`src/engine_contract.json`, which the engine's parity tests assert against.

## Matching the desktop app

Nano embeds the **desktop** theme catalog, not the mobile catalog (desktop
Codegraff has its own palette). Both catalogs, `themes.json` and
`ios_themes.json`, are checked-in inputs edited directly; nothing generates
them at build time. `src/theme_catalog_check.zig` refuses a catalog with a
repeated id, a variant outside its family, an unknown appearance, a missing
role section or a malformed colour. Desktop color-vector changes also update
`protocol/desktop/theme.json`.

Sizes, spacing, colours and rules come from the GPUI source and are checked
side by side against the real app on the same throwaway engine: the title
bar's buttons, the tab list, the project filter, session rows (status mark,
agent mark, project monogram, fading title, relative time), the header's
"project @ device", the transcript column (736 points), folded tool groups
("Ran 2 commands"), and the composer pill with its model chip. The icons are
Harness's own SVGs (`crates/ui/assets/icons`); the interface icons are Solar
Linear by 480 Design (CC BY 4.0). File badges, explorer rows, tabs and diffs
reuse Harness's Symbols artwork and `crates/ui/src/file-icons.json` manifest,
including exact filenames, compound extensions and named folders. The app
keeps their authored colors and the GPUI dark palette; the manifest is
compiled at build time rather than parsed into memory on launch.

## Layout

| File | |
|---|---|
| `src/ws.zig` | WebSocket client for the engine's socket. It sends no `Origin` header, which the engine refuses. |
| `src/rpc.zig` | The RPC frames: calls, replies, streams, cancel. |
| `src/engine.zig` | The connection: a reader thread, messages handed to the UI thread, reconnecting every 2 s. |
| `src/workspace.zig` | Spaces, chats, sessions, agents and models, each list replaced whole. |
| `src/transcript.zig` | A chat's transcript: resets and deltas, checked as `apply_transcript_frame` checks them. |
| `src/app.zig` | The state, and the calls the GPUI app makes to open a chat, create one and send. |
| `src/view*.zig`, `src/theme.zig` | The window: title bar, sidebar, transcript, composer, new-chat canvas, menus and pickers, in Harness's Codegraff Light and Dark roles. |
| `src/tabs.zig`, `src/rules.zig`, `src/tools.zig` | Tabs; relative times, project monograms and reasoning labels; how tool calls fold and what their groups say. |
| `src/icons.zig`, `src/icons/` | Harness's icons and agent marks, tinted as drawn. |
| `src/markdown.zig`, `markdown_html.zig`, `highlight.zig` | nanoterm's Markdown parser and code highlighting, unchanged. |
| `src/release.zig` | The newest release, over HTTP/2. |

## Seeing the window without opening it

`zig build snap -- scene.json out-dir` draws the window offscreen from a
made-up scene (no window on screen, no engine) and saves a PNG for each
`snap` step. A scene gives the window's size and theme, the spaces, chats
and transcripts to show, and steps that press shortcuts, click, type and
check what's drawn (`expect`, `expectNot` fail the run). The format is at
the top of `src/snap.zig`; `scenes/` has examples.

## Checking it against the GPUI app (optional, needs Rust)

This is the one check that builds Rust, and it is not part of building,
testing or packaging: a visual comparison against the GPUI app as reference.
`python3 parity/check.py` draws every scene in `parity/scenes` in both apps
offscreen, the GPUI app through `crates/ui/examples/ui-scenes.rs` (built
once; the script never builds it) and nano through `harness-nano-snap`,
and compares them frame by frame. It writes gpui | nano | difference
images and `report.json` with unrounded per-frame differences and their mean.
Use `--max-changed 0.0005` to require every frame, including new scenes, to
stay within 0.05% changed pixels; the older per-frame budgets alone allow a
0.5-percentage-point regression and do not constrain new scenes. `--update`
records new budgets but cannot bypass an explicit ceiling.

Scenes declare the synthetic device's `dictationAvailable` capability
(default false). Both renderers use it rather than racing a probe of the
host's installed Codex; the model-picker scenes explicitly exercise the mic.
Run against the same nanoui revision as the app:
`NANOUI_FORK=/path/to/nanoui python3 parity/check.py --max-changed 0.0005`.
