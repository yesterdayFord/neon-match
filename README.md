# NeonMatch

NeonMatch is a tiny Zig executable for a deterministic limit order matching engine.

The project brief lives in [neon-match.md](neon-match.md). Keep this README focused on setup and day-to-day commands.

## Requirements

- Zig 0.17, or the project-pinned Zig version once one is added

## Build

```sh
zig build
```

## Run

```sh
zig build run
```

Commands are read from stdin:

```text
BUY 1 100 10
SELL 2 99 4
CANCEL 1
```

The program prints trades and the full book state after every command.

## Test

```sh
zig build test
```

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast -- --measurement throughput --mode matcher --workload matching --commands 1000000 --warmup 10000
zig build bench -Doptimize=ReleaseFast -- --measurement latency --mode matcher --workload matching --commands 100000 --warmup 10000
zig build bench -Doptimize=ReleaseFast -- --measurement throughput --mode journal --workload matching --commands 1000000 --warmup 10000 --journal-dir .zig-cache/bench-journal
```

Measurements are intentionally separate. `throughput` uses one batch timer around the command loop and does not collect per-command service-time percentiles. `latency` measures isolated command service time and excludes ingress queueing, so its percentiles are not end-to-end system latency under offered load.

Workloads are `matching`, `resting`, `cancel_heavy`, and `full_capacity`. Each workload declares bounded live-order count, price range, id range, expected operation counters, and checksum output. Journal mode measures record serialization, checksum work, and buffered writes accepted by the OS page cache; it does not measure stable-storage persistence because NeonMatch does not issue per-command `fsync` or `fdatasync`.

## Layout

- `src/main.zig` - stdin command loop
- `src/engine.zig` - fixed-capacity matching engine
- `src/bench.zig` - deterministic benchmark harness
- `tests/` - public behavior and regression-style tests
- `tests/fixtures/` - replayable command corpora with expected output
- `build.zig` - Zig build definition
- `docs/agent/` - copied agent guidance snapshots
- `neon-match.md` - canonical project brief
