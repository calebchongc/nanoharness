# The Zig engine against the local edge

`scripts/local-edge.sh check` runs the edge Worker (`edge/`, unchanged) with
`wrangler dev --local` (Miniflare/workerd, state in a temporary folder,
`edge/wrangler.local.jsonc`) and two Zig `harness-engine headless` processes
as two devices of one made-up user. It is the first run of the Zig engine
against the real Worker code; before it, the engine was only tested against
in-process fakes of the edge.

Everything stays on the machine: no Cloudflare account, no deployed edge, no
secrets. Wrangler runs with metrics, error reports, its npm update check and
the `request.cf` download turned off, and the check samples every process it
started for non-loopback connections (reported below).

## How sign-in works here

The Worker authenticates with `edge/src/auth.ts` `verifyToken`. Deployed
(`AUTH_MODE=codegraff`) it takes only its own HS256 JWTs, which it issues
after a CodeGraff OAuth code exchange (`/auth/exchange`, against
`codegraff.com`, hard-coded in `edge/src/codegraff.ts`) or a cloud sandbox's
lease token (`/auth/sandbox`, against the gateway). Neither identity provider
can be pointed at a loopback stand-in without changing `edge/src`, which this
work does not do.

The local edge runs `AUTH_MODE=dev`, the mode `npm run dev` and the edge's own
workerd tests use: the bearer is `user` or `user@org`. The check makes up
`ada-xxxxxx` and uses the Worker's personal workspace for it,
`user-ada-xxxxxx`, so `GET /auth/orgs` lists exactly the org the engine syncs.
The engine takes that bearer as `HARNESS_EDGE_TOKEN` with no CodeGraff client
(its development mode, as in Rust). `/auth/orgs` answers only because the
local config sets a made-up client id and signing key; nothing is signed
with them.

A deployed Worker never runs dev auth, so this check does not cover the
OAuth exchange, refresh rotation or JWT expiry. It does cover everything
after the bearer: the registry, the device room, chat tails, blobs and
rooms.

## Mismatches found

Fixed in Zig, each with a test that fails without it:

1. **A development bearer never reached the edge.** `engine_main.zig` set
   `HARNESS_EDGE_TOKEN` as the key but never the edge URL in development
   mode, so the registry sync and the device relay returned before their
   first request. `dev_edge_auth.zig` now sets the URL, and the user id and
   org the Worker reads from `user@org` (its `/registry/:org/*` routes answer
   403 unless the bearer's org is the URL's). Test: `dev edge auth: a
   development bearer points the engine at the configured edge`.
2. **A prompt for another device's chat ran on the wrong machine and erased
   the host's history on the Worker.** Device B ran the turn itself, then
   `PUT /chat2/:id/tail` with only its own turn, which the Worker serves as
   the chat's history. B's attachment upload also stayed on B. `relay_dial.zig`
   now dials the Worker's DeviceRoom as a client (`/device/:id/ws?role=client`)
   for one call: a remote `targetDeviceId` call runs on that device, and a
   `QueueCommand` for a chat another device hosts goes to the host as
   `RelayCommand` with a durable entry. Test: `relay dial: a run for a chat
   another device hosts runs on that host, and an upload lands there`.
3. **A remote chat's transcript never refreshed.** B fetched the host's tail
   once and never again, and an open chat (with an empty local doc) was never
   prefetched. `remote_tail.zig` now drops the cached tail when a remote
   chat's `chats`/`sessions` row changes, prefetches open-but-empty chats, and
   the host now PUTs its tails before it pushes the rows that announce them.
   Tests: the three `remote tail:` tests.

Open:

4. **No chat2 log rows (Loro).** The Zig engine never opens
   `/chat2/:id/ws`; the chat's log on the Worker stays at `headSeq 0`, and
   history reaches other devices only through the tail sidecar. A Rust or Swift
   client opening a Zig-hosted chat gets the tail (instant open) but no live
   doc, and a command it writes into the doc never reaches the Zig host (only
   `RelayCommand` does). `chat2_client.zig` is only used in tests. This needs
   a Loro codec in Zig, which is out of scope.
5. **No tool-output sidecars.** The engine never uploads
   `PUT /blob/:chat/:part` for a long tool output or diff; `FetchToolBlob`
   reads a blob the Worker holds correctly. The upload belongs where the turn
   folds a tool result (`turn_host.zig`), queued like the tails in the sync
   worker: roughly 100 to 150 lines, no Worker change.
6. **The non-background sync path still pushes rows before tails.**
   `EngineHost.syncFromEdgeRegistry` (`engine_host.zig`, the locked variant
   used when the background worker is off) has the old order. The headless
   engine uses `syncFromEdgeRegistryUnlocked`, which is fixed. Moving one
   block, as in fix 3.
7. **One device-room socket per forwarded call.** `relay_dial.zig` doesn't
   cache peer links as Rust's `LinkCache` does, so a large attachment dials
   once per chunk. A small per-target cache in that file.
8. **Remote turns show up at row changes, not while they stream.** A second
   device sees the host's turn when its chat or session row changes (start
   and end), not token by token, which Rust gets from chat2 rows (see 4).

Worker behaviour the engine follows, not mismatches:

- `POST /auth/orgs` answers 405 in every auth mode: the Worker only has the
  personal workspace. The check asserts the 405 instead of creating an org.
- In development mode the engine's `ListOrgs` answers `[]` without asking the
  Worker, as Rust's engine without CodeGraff does.
- Without Hyperdrive, dev auth keeps agent rooms in the Worker's in-memory
  store, so an edge restart empties them. Step 8 doesn't check rooms.

## `up`

`scripts/local-edge.sh up --phone` leaves the local edge, engine A (signed
in, a synthetic repo, a mock chat with one turn) and engine B running, and
opens `harness-nano` on A's profile and `harness-nano --mobile` on B's.
Each app gets its own HOME, data folder, port and engine (no engine start of
its own, no release check, no graff download).

In this session the display was asleep, so `screencapture` returned black
frames. These two images were drawn by the same binary on the same profiles
and engines with nanoui's offscreen renderer (`--nanoui-snapshot`): A's
desktop window, and B's phone layout showing A's chat (`@ synthetic-a`), read
from the Worker.

![harness-nano on engine A](local-edge-up-desktop.png)

![harness-nano --mobile on engine B](local-edge-up-phone.png)

## Last run

<!-- local-edge:run:begin -->
Last `scripts/local-edge.sh check` run: commit `b69f242e`, harness-engine 0.2.186, Zig 0.17.0, Node v24.10.0, wrangler 4.120.0 (the lockfile's).

| Step | | Result | Time | Detail |
|---|---|---|---|---|
| 1 | local edge starts on fresh persisted state | pass | 1.2 s | wrangler dev --local, dev auth, 2 loopback ports |
| 2 | engine A (Zig) starts against it | pass | 0.7 s | harness-engine 0.2.186, scope development |
| 3 | A signs in, org, device registered | pass | 0.0 s | CLI status ok; AuthStatus signedIn ada-tv879n in user-ada-tv879n (= /auth/orgs); engine ListOrgs [] (dev mode); org creation not offered by the Worker (405); device row + relay host online (1 socket) |
| 4 | A: project, mock chat, turn, transcript | pass | 0.5 s | 2 messages read back, assistant complete, 2 tool parts |
| 5 | the Worker holds the chat row and its history | pass | 0.5 s | chats row (title "Summarise the synthetic demo repo", host A), spaces row present; /chat2/:id/tail 2 messages with the turn; chat2 log headSeq 0 |
| 6 | engine B: lists, reads, relays a prompt to A | pass | 2.7 s | B lists "Summarise the synthetic demo repo" hosted on A and reads it; B's prompt ran on A, reply on B, Worker tail has both turns |
| 7 | rooms, tool blob, attachment | pass | 0.1 s | room: B read A's post; tool blob: skipped, no turn produced one (the Zig engine uploads no tool sidecars); FetchToolBlob of a Worker-held blob ok; attachment: landed in A's uploads, relayed prompt ran on A |
| 8 | edge and A restart on the same state | pass | 2.8 s | A signed in again (dev bearer), chat + both turns local, Worker tail + rows persisted, a rename synced |
| 9 | everything stopped, no process or port left | pass | 0.3 s | 3 process groups stopped; 14 ports closed |

Non-loopback connections seen from the edge and engines during the run: none.
- chat2 log for the chat: headSeq 0 (the Zig engine writes no Loro rows; history is the host-published tail)
- agent rooms are in the Worker's in-memory dev store without Hyperdrive, so an edge restart empties them
<!-- local-edge:run:end -->
