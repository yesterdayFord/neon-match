# AGENTS.md

<!--
Shared engineering guidance snapshots:
- Source repository: yesterdayFord/engineering
- Source: principles/viho.md
- VIHO version: 0.3.2
- Source: principles/engineering.md
- Shared-guidance snapshot date: 2026-08-12
- Shared-guidance source revision: 25061973d755cca6cfcdb4839d4277e5ce7bbc24

Language guidance snapshot:
- Source: engineering/languages/zig/base.md
- Source: engineering/languages/zig/versions/0.17.md
- Snapshot date: 2026-08-13
- Source revision: unavailable
-->

These instructions apply to this repository tree.

This file is a portable project-local snapshot. The repository must not require external orchestration layers, symlinks to shared guidance, or external language-guidance files to build, test, review, package, or submit.

## AGENTS.md Scope

- This `AGENTS.md` applies to files in this directory and its subdirectories.
- A deeper `AGENTS.md` may add to or override these instructions for its own subtree.
- Instructions from unrelated directories do not apply.
- Markdown links do not import instructions. Linked guidance is inactive unless its relevant text is copied into the repository and explicitly adopted here.

## Canonical Project Documents

Each kind of durable project knowledge has one canonical home:

- [ROADMAP.md](ROADMAP.md) defines high-level product direction and bounded project phases.
- [neon-match.md](neon-match.md) is the canonical project brief for current architecture, principles, scope, and durable NeonMatch-specific engineering decisions.
- `AGENTS.md` defines instructions for agents and contributors working in this repository tree.
- GitHub issues hold detailed implementation work and short-term execution planning.
- The current code and tests are authoritative for what is actually implemented.

Do not duplicate the high-level roadmap into `neon-match.md` or detailed implementation plans into `ROADMAP.md`.

## Engineering Review

Every review begins with inspection, not recollection.

Memory provides context. Inspection establishes truth.

The current repository, document, design, or other engineering artifact is the authoritative source for its present state. Prior conversation and historical discussion are supporting context, not evidence.

When reviewing work:

- Inspect before drawing conclusions.
- Separate verified observations from inferred conclusions.
- Clearly distinguish historical context from current state.
- Separate observation from recommendation.
- Do not modify the artifact while reviewing unless explicitly instructed.

Engineering reviews exist to improve understanding before changing the system.

## Durable Engineering Decisions

Conversation is transient. Repository policy is durable.

When a discussion establishes a reusable engineering rule, workflow, architectural principle, coding standard, review protocol, or other long-lived guidance that is expected to influence future work, determine whether it should become part of the project's permanent documentation.

Do not assume important decisions will be preserved by conversational memory.

If a decision appears durable:

- Recommend the appropriate canonical location.
- Explain why it belongs there.
- Ask whether the project documentation should be updated, or prepare a proposed patch when requested.

Do not automatically modify project documentation without explicit instruction.

Temporary implementation discussions, debugging sessions, exploratory ideas, and one-off preferences should remain conversational unless they evolve into project policy.

## GitHub Operations

Use the connected GitHub integration for GitHub operations when practical.

When local Git is required for working-tree state, rebases, merges, commits, or exact ref handling, use local Git directly. If the managed sandbox blocks `.git` writes or Git-for-Windows SSH transport, request escalation and complete the operation rather than asking the user to run it manually.

## Shared Engineering Guidance

NeonMatch consumes checked-in snapshots of shared engineering guidance under `docs/agent/`.

- `docs/agent/viho.md` contains the adopted VIHO architecture guidance.
- `docs/agent/engineering.md` contains broader engineering design principles.

Before architectural or performance-sensitive work, read `docs/agent/viho.md`.

When making design, interface, representation, maintainability, or abstraction decisions, apply `docs/agent/engineering.md` as relevant. In particular, preserve the domain model and clear interfaces before optimizing local data-structure or syntax convenience.

Do not fetch shared guidance from sibling repositories, parent directories, symlinks, or live shared-guidance paths while working in this repository.

The current VIHO snapshot is `0.3.2`, copied from `principles/viho.md`. The current general engineering snapshot was copied from `principles/engineering.md`. Both were taken from `yesterdayFord/engineering` revision `25061973d755cca6cfcdb4839d4277e5ce7bbc24`.

Shared guidance does not override NeonMatch. Explicit NeonMatch requirements, repository-local instructions, current code, and tests take precedence. NeonMatch-specific decisions, adaptations, and justified exceptions remain in NeonMatch.

Shared-guidance adoption policy:

- Never interrupt active work merely because upstream shared guidance changed.
- Refresh local snapshots only through a deliberate repository change.
- Small clarifications may be adopted at a clean boundary.
- Meaningful behavioral or architectural guidance changes require explicit review before adoption.
- Major changes should be treated like a policy migration and may require validation in another project before NeonMatch adopts them.

## Zig Guidance Snapshot

Copied guidance lives under `docs/agent/`:

- `docs/agent/viho.md`
- `docs/agent/engineering.md`
- `docs/agent/zig.md`
- `docs/agent/zig-0.17.md`

The canonical Zig guide has not been written yet. For now, treat the Zig files as placeholders for copied Zig-wide guidance once it is established under `engineering/languages/zig/`. Do not infer extra Zig standards from the existence of the placeholders.

## Matching Engine Project Guidance

- Correctness comes before latency optimization.
- Keep matching behavior deterministic and covered by fixtures.
- Preserve a simple reference path for validating optimized code.
- Treat order book state transitions as behavioral changes that require tests.
- Follow the Zig testing guidance in `neon-match.md`: prefer current idiomatic Zig practice, distinguish language guidance from project preferences, and keep test layout decisions deliberate.
- Follow the Zig project structure guidance in `neon-match.md`: prefer the smallest truthful executable shape and avoid library topology until it solves a present problem.
- Follow the Zig allocation and lifetime guidance in `neon-match.md`: treat allocation as an architectural choice, keep ownership explicit, and keep allocation-free components allocation-free.
- Prefer explicit names for price, quantity, side, order id, and time-priority concepts.
- Document benchmark results separately from correctness claims.

## Portability

- Do not add symlinks to shared engineering guidance.
- Do not require shared `engineering/` paths in build scripts, tests, editor settings, CI, or agent instructions.
- If shared guidance is refreshed from `yesterdayFord/engineering`, update the local snapshots and provenance metadata together.
