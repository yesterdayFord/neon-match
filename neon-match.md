# NeonMatch Project Brief

NeonMatch is a small, explicit, deterministic matching-engine project. Its purpose is to build a clear reference implementation of limit order book behavior before pursuing low-level performance work.

## Goals

- Build a deterministic limit order matching engine in Zig.
- Model core order book behavior with clear names and testable state transitions.
- Preserve a simple reference path for validating any future optimized path.
- Keep correctness claims grounded in fixtures and reproducible tests.
- Make the project portable as a standalone repository, with copied local guidance rather than runtime links back to Groot.

## Principles

- Correctness comes before latency optimization.
- Determinism is part of the product, not an implementation detail.
- Every behavior-changing state transition should be easy to test.
- Data structure choices should remain understandable until measurements justify more complexity.
- Benchmarks should describe performance observations, not replace correctness tests.
- Project documentation should have one canonical home for each kind of knowledge.

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

Future scope may include:

- Market orders or additional order types.
- Performance benchmarks.
- Alternative optimized data structures.
- Event logs, replay, and audit-oriented fixtures.
- A command-line simulation or inspection tool.

## Roadmap

1. Establish the project scaffold, brief, local guidance, build file, and empty library entry point.
2. Define the core domain vocabulary: side, price, quantity, order id, timestamp or sequence, order, trade, and book state.
3. Implement a simple reference matcher with focused unit tests.
4. Add deterministic fixtures for representative matching and cancellation scenarios.
5. Measure baseline performance only after behavior is covered by tests.
6. Introduce optimized structures only when the reference path can validate them.

## Non-Goals

- Do not build an exchange, broker, trading bot, or production market gateway.
- Do not optimize before the matching rules are stable and tested.
- Do not add networking, persistence, authentication, or UI concerns during the initial scaffold phase.
- Do not make the project depend on Groot at runtime or through symlinks.
- Do not duplicate this full brief into `README.md`; link to it instead.
