# NeonMatch

NeonMatch is a Zig scaffold for a deterministic limit order matching engine.

The project brief lives in [neon-match.md](neon-match.md). Keep this README focused on setup and day-to-day commands.

## Requirements

- Zig 0.17, or the project-pinned Zig version once one is added

## Build

```sh
zig build
```

## Test

```sh
zig build test
```

## Layout

- `src/root.zig` - initial library entry point
- `build.zig` - Zig build definition
- `docs/agent/` - copied agent guidance snapshots
- `neon-match.md` - canonical project brief
