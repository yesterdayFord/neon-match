<!--
Source: engineering/principles/viho.md
VIHO version: 0.3.0
Reference date: 2026-06-29
Snapshot date: 2026-08-13
Source revision: unavailable
-->

# VIHO

**Vertically Integrated Hardware Orchestration**

Version 0.3.0
Reference date: 2026-06-29

VIHO is an engineering lens for systems in which topology, locality, ownership, data movement, coordination, and failure behavior materially affect correctness or performance.

Its central premise is:

> Physics is part of the architecture.

Moving bytes is often more expensive than computing on them. A system therefore cannot be understood only through its logical components; it must also be understood through the physical and operational paths that connect those components.

## Core Principles

- Locality is leverage.
- Coordination is the new clock speed.
- Dependencies, build systems, tests, generated scaffolds, and development topology are part of the architecture.
- A system is not complete if it cannot be built, tested, replayed, and understood locally without hidden external coordination.
- The smallest working system is the first truthful architecture.

VIHO favors explicit ownership, bounded complexity, operational readability, deterministic behavior, and evidence-driven architecture.

## Four-Path Deterministic Layout

> Hot decides. Storage remembers. Warm interprets. Replay explains.

The Four-Path Deterministic Layout prevents hot execution, rich semantic interpretation, raw evidence capture, and forensic replay from collapsing into one accidental system.

The paths are responsibilities, not necessarily separate services, processes, or threads. They should become physically separate only when real coordination, isolation, or performance pressure justifies the split.

### Hot Path

The hot path executes localized tactical decisions with minimal coordination.

Examples include:

- admission control
- scheduling
- routing decisions
- safety gates

Rules:

- Prefer a single writer.
- Do not make blocking calls.
- Keep generic schemas, GUI semantics, and database dependencies out.
- Keep the logic simple enough to explain on a whiteboard.

### Storage Path

The storage path captures raw truth with minimal transformation.

Examples include:

- raw wire bytes
- PCAP
- append-only journals
- sequenced event logs

Rules:

- Write append-only whenever practical.
- Favor sequential I/O.
- Preserve original event ordering.
- Minimize extraction cost.
- Do not normalize data on the hot path merely to make later consumers more comfortable.

### Warm Path

The warm path maintains richer semantic state for controls, operator interfaces, analytics, and higher-level coordination.

Examples include:

- canonical schemas
- derived state
- policy views
- health views
- subscription fanout
- operator dashboards

Rules:

- Keep it asynchronous from the hot path.
- Use explicit publication mechanisms such as RCU or double buffering where appropriate.
- Treat derived state as disposable and rebuildable.
- Keep complex recalculation out of the execution lane.

### Replay Path

The replay path reconstructs behavior, tests hypotheses, investigates anomalies, and verifies determinism.

Examples include:

- replaying raw events
- rebuilding state from logs
- simulating decisions
- reconstructing derived state
- investigating anomalies

Rules:

- Use the production parser where possible.
- Isolate replay from production execution.
- Make runs reproducible.
- Preserve the physical footprint and ordering of events.
- Turn incidents into permanent test cases.

## Dependency Philosophy

Dependencies are coordination contracts, not free utilities.

- Minimize transitive dependencies.
- Do not outsource core invariants to opaque frameworks.
- Avoid dependency sprawl in critical runtime paths.
- Require every dependency to justify its operational, semantic, and lifecycle cost.

This does not require zero dependencies. A useful dependency may be entirely appropriate when it is explicit, justified, reproducible, and kept out of paths where its hidden behavior would compromise the system.

## Local and Offline Completeness

A VIHO-aligned system should be buildable, testable, and explainable without internet access.

- Local builds work offline.
- Tests run locally.
- Test fixtures are checked in or generated deterministically.
- Replay datasets required for correctness are locally available.
- No task is complete when it depends on unstated external services.

Production may still require venues, feeds, or other external systems. Offline completeness applies to build, test, replay, simulation, and understanding—not to pretending that a connected production system has no external boundary.

## Prototype Discipline

Do not scaffold architecture before behavior exists.

- Start with the smallest working executable.
- Prefer one file until separation is forced.
- Do not create empty directories.
- Do not create abstraction layers without a concrete use.
- Every directory must contain working code or be removed.
- Separate components only along real coordination domains.
- Name possible future domains in design notes if useful, but do not instantiate them prematurely in code.

Architecture should emerge from solving real problems. Each abstraction should reduce complexity rather than advertise sophistication.

## Guidance for AI-Assisted Engineering

AI should accelerate implementation, not generate architectural noise.

Good uses include:

- local optimization
- test generation
- replay-fixture generation
- small executable prototypes
- measured refactoring

Without evidence, AI should not introduce:

- speculative folder trees
- empty service directories
- future-proof interfaces
- generic platform scaffolding
- framework-style abstractions before runtime pressure exists

AI-generated structure should be treated as suspect until the behavior, ownership boundary, or measurement that justifies it is visible. Humans retain responsibility for topology, ownership, failure economics, and operational readability.

## Working Heuristics

- Dependencies are operational liabilities until proven otherwise.
- A build should not require the internet to explain itself.
- Development topology affects production topology.
- Do not scaffold future architecture.
- Every directory must earn its existence.
- Establish local completeness before integration.
- Measure before adding coordination.
- Preserve raw evidence before deriving interpretations.
- Prefer a smaller system that is fully understood over a larger system that merely appears sophisticated.

## Possible Future Extractions

Some VIHO guidance may eventually justify separate principle files, especially around simplicity and local testing/replay. Do not split these prematurely.

- Simplicity is currently part of VIHO's topology discipline: start with the smallest working system, avoid speculative scaffolding, and separate components only along real coordination domains.
- Testing guidance is currently about VIHO-specific local completeness, deterministic fixtures, replay, and incident reproduction. If extracted, prefer a focused name such as `local-testing-and-replay.md` over a general `testing.md`.

Create separate files only when their guidance is independently reusable without weakening VIHO's unified claim that physics, topology, coordination, and evidence are part of the architecture.

## Applying VIHO

VIHO is a decision framework, not a mandatory target architecture.

Projects should selectively apply it:

1. Begin with the smallest complete behavior.
2. Identify actual ownership and coordination domains.
3. Preserve deterministic evidence and replayability early.
4. Measure data movement and coordination before optimizing computation.
5. Split paths, threads, processes, or machines only when correctness, isolation, or measurement justifies the cost.

This keeps VIHO from becoming the kind of speculative infrastructure it warns against.
