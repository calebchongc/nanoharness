# harness-nano: resources

`make_replay.py` writes a deterministic, made-up transcript replay (a prompt,
then a long Markdown reply streamed as small text appends). `zig build
profile` builds `harness-nano-profile` (`src/profile.zig`), which plays it
offscreen with real CoreText and Metal at 1320 by 880, 2x, with no window,
engine or account, so a sampler such as `scripts/macos-resource-stat.c` can
measure CPU time, resident size, footprint and wakeups while it runs.

```bash
cd apps/nano
python3 bench/make_replay.py > bench/replay.json
zig build profile -Doptimize=ReleaseSafe
zig-out/bin/harness-nano-profile bench/replay.json /tmp/nano-profile
```

Nothing here needs Rust. The side-by-side comparison with the GPUI app was
removed with the GPUI build it needed; the last recorded results are in
`docs/performance/nano-gpui-offscreen.json`.
