# NeonMatch Project Brief

NeonMatch is a small, explicit, deterministic matching-engine project. Its purpose is to build a clear reference implementation of limit order book behavior before pursuing low-level performance work.

## Goals

- Build a deterministic limit order matching engine in Zig.
- Model core order book behavior with clear names and testable state transitions.
- Preserve a simple reference path for validating any future optimized path.
- Keep correctness claims grounded in fixtures and reproducible tests.
- Make the project portable as a standalone repository, with copied local guidance rather than runtime links back to shared engineering guidance.

## Principles

- Correctness comes before latency optimization.
- Determinism is part of the product, not an implementation detail.
- Every behavior-changing state transition should be easy to test.
- Data structure choices should remain understandable until measurements justify more complexity.
- Benchmarks should describe performance observations, not replace correctness tests.
- Project documentation should have one canonical home for each kind of knowledge.

## MVP Status

The MVP is complete once `CommandEvent` is merged into `main`: the project has a deterministic fixed-capacity matching engine, stdin command handling, a direct command-event boundary, fixture-backed replay coverage, and focused tests for order acceptance, cancellation, matching, and capacity edges.

The first post-MVP increment is durable journaling. Treat event logs, replay beyond the current deterministic fixtures, and audit-oriented storage as post-MVP work.

## Journaling Guidance

The journal preserves the ordered input truth of the engine.

The command journal is authoritative. Trades, errors, and book state are deterministic consequences that can be regenerated.

Live and replay differ only in where the next `CommandEvent` comes from.

NeonMatch stores journals in a configurable runtime directory as append-only `.nmj` segments. Each engine start creates a new UTC-named segment. Segment and record order, not timestamps, define command order. Closed segments are immutable and replayed in sequence.

General rules:

- Journal parsed `CommandEvent` values, not stdin text and not derived book state.
- Append each valid command before it may mutate the book.
- Use one append-only, single-writer binary stream.
- Preserve exact command order.
- Replay journaled commands through the same application path used during live execution.
- Treat trades, errors, and final book state as deterministic outputs that can be regenerated.
- A journal write failure must prevent the corresponding command from executing.
- Verify replay by comparing observable output and final book state with the original execution.

Admission and durability:

- The live admission path is `parse -> append -> apply`.
- A command must be completely appended to the OS-managed journal before it is applied to the engine.
- Per-command stable-storage sync is not required before applying a command.
- Stable-storage durability is committed at controlled boundaries and during graceful shutdown.
- Do not put a disk barrier such as per-command `fsync` on the default command path.
- The initial guarantee is process-replayable journaling, not zero-loss recovery from sudden machine or power failure.
- If stronger crash recovery becomes a real requirement, use batching or group commit rather than per-command sync.

Runtime layout and naming:

- Treat the journal as runtime data, not repository content.
- Use `./journal/` as the development default.
- Use a configurable absolute directory in production, conventionally `/var/lib/neon-match/journal/`.
- Keep journal files out of `src/`; the implementation belongs in `src/journal.zig`.
- Add `journal/` to `.gitignore`.
- Tests must use a temporary directory, never the real journal directory.
- Name segments `journal-<UTC-start-time>-<sequence>.nmj`, for example `journal-20260730T014500Z-000001.nmj`.
- Use UTC only in filenames.
- The timestamp records when the segment was created.
- Use a zero-padded sequence to prevent collisions and preserve lexical order.
- Do not put mutable information, such as ending time or record count, in the filename.

Segment lifecycle:

- The journal is logically one ordered stream composed of immutable segments.
- For the first implementation, use one process run as one segment.
- Open a new segment each time the engine starts.
- Append records only.
- Never reopen an old segment for appending.
- Never overwrite an existing filename.
- On collision, advance the sequence or fail safely.
- Replay segments in timestamp-and-sequence order.
- Add size-based rollover later, probably with a simple bound such as 256 MiB.
- Do not use midnight as the primary rollover boundary.

Date and ordering rules:

- Store timestamps in UTC.
- Do not encode local timezone, DST, or trading date into the core journal format.
- If a business or trading date becomes useful later, derive or index it separately.
- Ordering must come from record order and segment sequence, not wall-clock timestamps.

Recovery and retention:

- An open segment may be appended to but never modified in place.
- A closed segment is immutable.
- An incomplete final record after a crash is ignored or safely truncated during recovery.
- Corruption before the final record is an error, not something replay silently skips.
- Retention, archival, deletion, and compression remain outside the matching engine initially.

The first journaling increment should include only:

- Versioned record header.
- Record length.
- Serialized `CommandEvent`.
- Checksum.
- Journal writer.
- Journal reader.
- Replay test proving identical output and state.

Explicitly defer:

- Memory mapping.
- Asynchronous journal threads.
- Batching.
- Compression.
- Database integration.
- Snapshots.
- Log rotation.
- Recovery from partially corrupted files beyond safely rejecting or truncating an incomplete final record.
- Journaling derived trades as separate authoritative events.

## Zig Testing Guidance

Follow current Zig best practices while recognizing that the language, tooling, build system, and community conventions continue to evolve.

Do not preserve an existing testing structure solely because it already exists. Likewise, do not adopt a new convention simply because it is fashionable.

When there is a meaningful change in recommended Zig practices, prefer the current idiomatic approach unless the project has explicit reasons to differ.

General principles:

- Use Zig's built-in testing facilities.
- Favor clear failure diagnostics, such as `expectEqual`, `expectEqualStrings`, and `expectError`, over generic assertions when appropriate.
- Ensure `zig build test` executes the project's supported test suite.
- Keep tests deterministic and locally reproducible.
- CI should reproduce local developer workflows rather than introduce different behavior.

Current Zig convention generally favors colocated unit tests for implementation-level behavior and separate integration tests for higher-level scenarios.

As a starting point:

- Small implementation-focused unit tests may live beside the code they validate.
- Integration, replay, regression, and end-to-end behavior tests should normally live under a dedicated `tests/` directory.

Treat this as the default, not an immutable rule.

If future Zig guidance, official documentation, or broad community consensus evolves toward a different organization, adopt the newer approach when it provides a measurable improvement in clarity, tooling, maintenance, or developer experience.

When proposing changes to test organization:

1. Explain the current Zig recommendation.
2. Explain why it is preferable.
3. Explain the migration cost.
4. Distinguish language guidance from project-specific preferences.
5. Do not reject a newer convention simply because "this project has always done it this way."

Projects may intentionally override these guidelines for architectural or operational reasons. Such deviations should be documented with a short explanation so future maintainers understand that the choice was deliberate rather than accidental.

## Zig Project Structure Guidance

Favor the smallest truthful project structure that accurately reflects the current behavior of the software.

Project topology is part of the architecture. Directories, modules, libraries, and abstractions should exist because they solve a present coordination problem, not because they might become useful later.

General principles:

- Start with the smallest working executable.
- Prefer a single source file until separation improves clarity.
- Every file and directory should contain meaningful, working code.
- Avoid speculative abstractions and placeholder modules.
- Split code only when a natural ownership boundary appears.

When code becomes difficult to navigate or multiple responsibilities emerge:

- Separate by behavior, not by file size.
- Group code by ownership and coordination domain.
- Keep public interfaces small and explicit.
- Avoid unnecessary wrapper types and forwarding layers.

Keep `build.zig` simple and declarative. Build configuration should describe the project, not hide project logic. Avoid unnecessary custom build steps, and prefer standard Zig build conventions unless there is a measurable reason not to.

Applications should optimize for simplicity and readability. Libraries should additionally provide a clear public API through `root.zig`, stable exported types, documentation, and focused public behavior tests. Do not force application code into a library architecture before there is a demonstrated need.

This guidance reflects current Zig practices and the project's engineering philosophy. As Zig evolves, reassess these recommendations against official Zig documentation, accepted community conventions, compiler capabilities, and measurable improvements in maintainability, correctness, or performance.

Do not preserve historical structure without justification, and do not reorganize code solely to follow trends.

## Zig Allocation and Lifetime Guidance

Treat memory allocation as an explicit architectural decision.

Dynamic allocation is a coordination mechanism with runtime, performance, and operational costs. It should never be introduced simply because it is convenient.

The preferred design is one in which object lifetime, ownership, and storage are obvious from reading the code.

General principles:

- Prefer fixed-size storage when practical.
- Prefer stack allocation for temporary values.
- Prefer embedding data directly when ownership is exclusive.
- Use dynamic allocation only when it solves a real problem.
- Make ownership explicit.
- Lifetime should be obvious without tracing multiple layers of code.

Accept an allocator only when the component genuinely performs dynamic allocation. Do not add allocator parameters preemptively, and avoid passing allocators through multiple layers merely because they might eventually be needed.

The execution hot path should avoid dynamic allocation whenever reasonably possible. Where feasible, allocate during initialization, reuse existing storage, recycle buffers, bound memory growth, and keep allocation outside latency-sensitive execution.

Every allocation should have a clearly identifiable owner responsible for its release. Avoid ambiguous ownership, and avoid shared mutable ownership unless it is required by the architecture.

Functions should not expose allocation requirements unless allocation is part of their responsibility. Do not force callers to manage allocators unnecessarily.

Allocation behavior is part of correctness. When testing allocating components, verify expected ownership, detect leaks, verify cleanup paths, and exercise allocation failures where appropriate. Allocation-free components should remain allocation-free during testing.

As Zig's allocator APIs and best practices evolve, prefer current idiomatic guidance while preserving the project's architectural goals: explicit ownership, predictable lifetime, bounded resource usage, and deterministic execution.

Language evolution should improve implementation, not weaken these principles.

## Scope

Initial scope includes:

- Limit order book types and operations.
- Buy and sell side handling.
- Price-time priority.
- Order acceptance, cancellation, and matching behavior.
- Deterministic fixtures for order book transitions.
- A concise operational README and project-local agent guidance.

Post-MVP scope may include:

- Durable journaling as the first post-MVP increment.
- Market orders or additional order types.
- Performance benchmarks.
- Alternative optimized data structures.
- Event logs, replay, and audit-oriented fixtures.
- A command-line simulation or inspection tool.

## Roadmap

1. Complete: establish the project scaffold, brief, local guidance, build file, and executable entry point.
2. Complete: define the core domain vocabulary: side, price, quantity, order id, order, trade, and book state.
3. Complete: implement a simple reference matcher with focused unit tests.
4. Complete: add deterministic fixtures and direct `CommandEvent` replay for representative matching and cancellation scenarios.
5. Complete: add append-only command journaling and deterministic replay from journal records.
6. Post-MVP: turn journal replay into operational startup recovery, so process-replayable storage becomes the normal startup path rather than only an internal verification path.
7. Post-MVP: measure the simple single-book engine and verify allocation behavior before expanding its architecture, so future changes have a truthful baseline.
8. Post-MVP: introduce routing and multiple books for multiple instruments after the recovery path and baseline are established.
9. Post-MVP: introduce optimized structures only when the reference path and performance baseline can validate them.

## Non-Goals

- Do not build an exchange, broker, trading bot, or production market gateway.
- Do not optimize before the matching rules are stable and tested.
- Do not add networking, persistence, authentication, or UI concerns during the initial scaffold phase.
- Do not make the project depend on shared engineering guidance at runtime or through symlinks.
- Do not duplicate this full brief into `README.md`; link to it instead.
