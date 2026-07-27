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
