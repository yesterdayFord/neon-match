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
INSTRUMENT 2 BUY 3 101 7
INSTRUMENT 2 CANCEL 3
```

The program prints trades and the full book state after every command.
Commands without an `INSTRUMENT id` prefix use instrument `1`.

## Test

```sh
zig build test
```

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast -- --measurement throughput --mode matcher --workload matching --commands 1000000 --warmup 10000
zig build bench -Doptimize=ReleaseFast -- --measurement latency --mode matcher --workload matching --commands 100000 --warmup 10000 --latency-sample-size 64
zig build bench -Doptimize=ReleaseFast -- --measurement latency --timing tsc_ticks --mode matcher --workload matching --commands 100000 --warmup 10000 --latency-sample-size 64 --logical-cpu 0
zig build bench -Doptimize=ReleaseFast -- --measurement throughput --mode journal --workload matching --commands 1000000 --warmup 10000 --journal-dir .zig-cache/bench-journal
```

Measurements are intentionally separate. `throughput` uses one batch timer around the command loop and does not collect per-command service-time percentiles. `latency` times fixed-size batches and reports per-command service-time estimates from those batches; it excludes ingress queueing, so its percentiles are not end-to-end system latency under offered load. If a latency batch is too short for the platform timer resolution, the harness fails instead of reporting a zero-duration sample.

Nanoseconds are the portable primary measurement. On supported x86 systems, `--timing tsc_ticks` adds serialized timestamp-counter measurements around the same fixed-size batches using `LFENCE; RDTSC` before the batch and `RDTSCP; LFENCE` after it. Reported `tsc_ticks` are finer timestamp deltas, not literal executed core cycles; modern invariant TSC usually advances at a constant reference rate independent of turbo frequency. TSC mode requires RDTSCP, invariant TSC support, and successful benchmark-thread affinity pinning to one logical CPU. Pinning reduces migration noise but does not eliminate interrupts, cache effects, turbo behavior, operating-system interference, or preemption; the TSC continues advancing while the thread is descheduled. Empty serialized timer overhead is reported separately instead of being subtracted from samples.

Workloads are `matching`, `resting`, `cancel_heavy`, and `full_capacity`. Each workload declares bounded live-order count, price range, id range, expected operation counters, and checksum output. Journal mode measures record serialization, checksum work, and buffered writes accepted by the OS page cache; it does not measure stable-storage persistence because NeonMatch does not issue per-command `fsync` or `fdatasync`.

Preserved baselines should include the full command, build mode, CPU model, logical CPU, workload, command count, warmup, measurement repetitions, batch size, checksum, and allocation or journal note printed by the harness.

The current preserved baseline is [docs/benchmarks/2026-08-07-baseline.md](docs/benchmarks/2026-08-07-baseline.md).

## Layout

- `src/main.zig` - stdin command loop
- `src/engine.zig` - fixed-capacity matching engine
- `src/bench.zig` - deterministic benchmark harness
- `tests/` - public behavior and regression-style tests
- `tests/fixtures/` - replayable command corpora with expected output
- `build.zig` - Zig build definition
- `docs/agent/` - copied agent guidance snapshots
- `neon-match.md` - canonical project brief
