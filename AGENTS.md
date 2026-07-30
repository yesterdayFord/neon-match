# AGENTS.md

<!--
Engineering guidance snapshot:
- Source: engineering/languages/zig/base.md
- Source: engineering/languages/zig/versions/0.17.md
- Snapshot date: 2026-07-27
- Source revision: unavailable
-->

These instructions apply to this repository tree.

This file is a portable project-local snapshot. The repository must not require external orchestration layers, symlinks to shared guidance, or external language-guidance files to build, test, review, package, or submit.

## AGENTS.md Scope

- This `AGENTS.md` applies to files in this directory and its subdirectories.
- A deeper `AGENTS.md` may add to or override these instructions for its own subtree.
- Instructions from unrelated directories do not apply.
- Markdown links do not import instructions. Linked guidance is inactive unless its relevant text is copied here.

## Project Brief

The canonical project brief is [neon-match.md](neon-match.md). Keep goals, principles, scope, roadmap, and non-goals there.

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

## Shared Engineering Guidance

NeonMatch consumes canonical VIHO guidance from `engineering/principles/viho.md` as shared engineering guidance, currently targeting VIHO `0.3.0`.

Before architectural or performance-sensitive work, retrieve and read the canonical VIHO document from `engineering/principles/viho.md`. If it cannot be retrieved, report that clearly instead of using a remembered or cached version.

Do not copy, vendor, summarize, or maintain a local `viho.md`. VIHO is shared guidance: explicit NeonMatch requirements and repository-local instructions take precedence. NeonMatch-specific decisions, adaptations, and justified exceptions remain in NeonMatch.

VIHO adoption policy:

- Patch revisions may be adopted immediately.
- Minor revisions should be adopted at a clean boundary, normally after a clean merge.
- Major revisions require explicit review and a migration decision. They may require validation in a separate real project before NeonMatch adopts them.
- Never interrupt active work merely because VIHO changed.

## Zig Guidance Snapshot

Copied guidance lives under `docs/agent/`:

- `docs/agent/zig.md`
- `docs/agent/zig-0.17.md`

The canonical Zig guide has not been written yet. For now, treat those files as placeholders for copied Zig-wide guidance once it is established under `engineering/languages/zig/`. Do not infer extra Zig standards from the existence of the placeholders.

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
- Do not require shared `engineering/` paths in build scripts, tests, editor settings, or CI.
- If language guidance is refreshed from `engineering/`, update the snapshot metadata above.
