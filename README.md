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

## Layout

- `src/main.zig` - stdin command loop
- `src/engine.zig` - fixed-capacity matching engine
- `tests/` - public behavior and regression-style tests
- `tests/fixtures/` - replayable command corpora with expected output
- `build.zig` - Zig build definition
- `docs/agent/` - copied agent guidance snapshots
- `neon-match.md` - canonical project brief
