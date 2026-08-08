# NeonMatch Roadmap

NeonMatch is being built as a small, deterministic exchange core that can grow into serious infrastructure without losing simplicity, ownership, or comprehensibility.

This roadmap defines **product direction**, not implementation planning.

Substantial changes to this roadmap should be deliberate. Detailed design, implementation tasks, tests, and short-term execution belong in GitHub issues, project documentation, pull requests, and code.

Each roadmap item is a **bounded project phase** with:

- an entry condition;
- a clear capability to deliver;
- a completion condition.

Phases are outcome-driven, not time-boxed. A phase may create several GitHub issues, but implementation detail should not leak back into this document unless it changes the product direction.

---

## 1. Deterministic Single-Instrument Matching Core

**Entry condition:** Project scaffold exists and the core order vocabulary is defined.

**Outcome:** A small, understandable single-instrument matching engine with explicit order semantics and deterministic state transitions.

The matcher should be simple enough that its behavior can be reasoned about directly and tested completely enough to serve as the reference behavior for later implementations.

**Done when:** A single book can accept, match, rest, cancel, reject, and replay commands deterministically through one authoritative command path.

---

## 2. Persistence and Recovery

**Entry condition:** The deterministic matcher and command boundary are stable.

**Outcome:** Process-replayable authoritative command history and deterministic restart recovery.

Ordering and authority must be explicit. Recovery should reconstruct the same book state from the same accepted command history without depending on wall-clock behavior or derived output.

**Done when:** NeonMatch can restart from its authoritative journal, reconstruct state deterministically, reject corrupted authoritative history, and continue with new live commands.

---

## 3. Measure Before Optimizing

**Entry condition:** The single-book runtime and recovery shape are stable enough to measure honestly.

**Outcome:** A reproducible performance and allocation baseline for the simple reference engine.

The purpose is not to chase impressive numbers. It is to understand the current system well enough that later optimization decisions can be justified by evidence rather than instinct.

**Done when:** Representative matcher and journal workloads can be measured reproducibly, allocation behavior is understood, and future changes can be compared against a trusted baseline.

---

## 4. Multiple Instruments

**Entry condition:** The single-book engine has a trustworthy baseline and remains the reference behavior.

**Outcome:** Commands can be routed deterministically to independent books for multiple instruments.

The instrument/book boundary becomes the first real scale-out boundary. Multiple instruments should not require turning the matcher into one large shared-state system.

**Done when:** Multiple instruments operate independently, routing is deterministic, and replay/recovery preserve the same instrument separation.

---

## 5. Harden Correctness

**Entry condition:** Multiple core execution paths exist and the state space is beginning to expand.

**Outcome:** Stronger confidence that malformed, unusual, long, or adversarial command streams cannot silently violate book invariants or replay behavior.

Hardening should stay practical: validate invariants, generate deterministic command sequences, mutate serialized input, and compare equivalent execution paths. Avoid creating testing infrastructure that is more complex than the product.

**Done when:** Core invariants are continuously testable and generated/adversarial inputs provide meaningful additional coverage beyond hand-written fixtures.

---

## 6. Real Exchange Ingress and Egress

**Entry condition:** The multi-instrument core is stable enough to be driven by external clients.

**Outcome:** Define the boundary between NeonMatch and real exchange participants or upstream systems.

This includes session/protocol ingress and authoritative command submission, plus market-data or other derived output. Commands and derived output must remain conceptually separate.

External arrival order is not authoritative until NeonMatch establishes an explicit deterministic command order. The ingress boundary must convert externally arriving requests into that authoritative order before they mutate exchange state or enter authoritative history.

Reference clients should exist at more than one level where useful:

- protocol/API for real integration;
- CLI for reference behavior, scripting, debugging, and automation;
- GUI for human understanding, order entry, market data, order lifecycle, fills, cancels, rejects, and session state.

**Done when:** External clients can submit commands through a defined protocol/session boundary and consume clearly defined output without bypassing the authoritative execution path, with at least one simple reference client and a clear path to a human-facing client where useful.

---

## 7. Exchange Controls Around the Matcher

**Entry condition:** Real external sessions can drive the engine.

**Outcome:** Add the minimum operational controls required to behave like an exchange rather than an isolated matcher.

Likely concerns include instrument state, trading state, participant/session permissions, and narrowly scoped pre-trade or risk controls where they genuinely belong.

**Done when:** The exchange can control who may trade, what may trade, and under what state, without spreading policy unpredictably throughout the matching core.

---

## 8. Optimize the Complete Critical Path

**Entry condition:** Reference behavior, correctness hardening, external ingress/egress, exchange controls, and baseline measurements are strong enough to judge optimization safely.

**Outcome:** Improve latency, throughput, memory layout, and predictability across the real critical path without obscuring the reference semantics.

Optimization should account for the complete execution path that real commands traverse, not the matcher in isolation. Possible work may include data structures, memory layout, cache behavior, timing, affinity, parsing, sequencing, and control-path costs, but only where measurements show a real need.

**Done when:** Material bottlenecks identified by measurement have been improved without changing authoritative behavior or making the core needlessly difficult to understand.

---

## 9. Operational Appliance

**Entry condition:** The exchange core has meaningful external interfaces and controls.

**Outcome:** NeonMatch can be deployed, operated, inspected, restarted, and upgraded as a small self-contained system.

The target is intentionally lean: minimal runtime dependencies, explicit configuration, useful observability, clean startup/shutdown, and the ability to run on hardware ranging from constrained ARM systems to serious bare-metal servers without changing the architecture.

A human-facing operational interface may make the engine easier to understand and operate visually: live book state, order lifecycle, matches and cancels, latency distributions, journal replay, historical state inspection, and later replication or HA state.

Instrumentation should stay out of the matching hot path wherever possible. Start with existing observable state and journal data; add engine instrumentation only when the interface demonstrates a concrete need.

**Done when:** A fresh operator can deploy and operate a complete NeonMatch instance from documented configuration without requiring a large supporting platform, and the system can be understood through useful human-facing views rather than raw logs alone.

---

## 10. High Availability and Replication

**Entry condition:** Authority, persistence, recovery, and operational boundaries are already clear on a single node.

**Outcome:** Add redundancy without making transport or replication more authoritative than the exchange state itself.

Replication should follow the authoritative event model. Derived logs, JSON, market data, or operational telemetry should not become accidental consensus mechanisms.

**Done when:** A standby or replicated instance can take over deterministically from the authoritative event stream with clearly defined failure and recovery semantics.

---

## 11. Broader Exchange Functionality

**Entry condition:** The core exchange is operational, externally accessible, and recoverable.

**Outcome:** Add broader functionality only in response to concrete product requirements.

This may eventually include additional order types, RFQ flows, richer participant controls, more sophisticated risk rules, administrative tooling, surveillance/compliance export boundaries, or other exchange features.

This phase is intentionally open-ended. NeonMatch should not reproduce every feature found in existing exchange platforms simply because those features exist.

**Done when:** Required functionality can be added without compromising the authority model, determinism, or architectural simplicity established by the earlier phases.

---

## 12. Commercial Exchange Platform Replacement

**Entry condition:** NeonMatch covers the real operational requirements of a complete exchange deployment.

**Outcome:** Become a credible replacement for commercial exchange platforms, including EP3-class systems, by being smaller, more understandable, more deterministic, and easier for the operator to own completely.

The goal is not feature-for-feature imitation. The goal is the smallest complete exchange core that satisfies the actual requirements of its operators.

The same architecture should scale from a tiny demonstration appliance to production-grade pinned-core hardware.

**Done when:** A real operator can choose NeonMatch instead of a commercial exchange platform without giving up the capabilities they actually require.

---
## Interface Principle

Every important interface should have a simple machine-facing form and, where useful, a human-facing form.

```text
protocol/API  -> real integration
CLI           -> reference/debug/scriptable client
GUI           -> human understanding and operation
```

These are adapters around the same authoritative command and event boundaries. None should become a separate source of truth.

---

## Governing Constraint

> Do not add a subsystem because exchanges usually have one. Add it when NeonMatch has a concrete requirement that makes it necessary.

The roadmap should preserve that constraint as the system grows.
