<!--
Source repository: yesterdayFord/engineering
Source: principles/engineering.md
Snapshot date: 2026-08-12
Source revision: 25061973d755cca6cfcdb4839d4277e5ce7bbc24
-->

# Engineering

General engineering principles that apply across projects and are broader than any one architecture or implementation style.

## Optimize the Interface Before the Implementation

Optimize the interface before you optimize the implementation.

A poor implementation can be replaced behind a good interface. A poor interface spreads assumptions, coupling, and complexity throughout the system.

Optimize interfaces for correctness, clarity, and change — not merely for fewer methods or shorter syntax.

## Optimize Maintenance Before the Feature

Optimize maintenance before the feature.

Make the system easier to understand, test, operate, debug, recover, and change before asking it to do more.

A feature creates immediate capability. Maintenance determines the continuing cost of that capability and the cost of every feature that follows.

## Prefer Domain-Semantic Representations

Prefer domain-semantic representations over incidental data structures when the concept has identity, behavior, or likely evolution.

Use this precedence when choosing representations:

```text
domain model
    >
clear interfaces and invariants
    >
concrete data structures
    >
minimal syntax or code footprint
```

Do not create a named type merely because two values travel together. Transient, obvious groupings may remain tuples, pairs, or simple return aggregates.

Promote raw structure into a named domain type when several signals indicate that the value represents a real concept rather than temporary grouped data. Useful signals include:

- the value has a meaningful domain name;
- fields are referenced in multiple places;
- field order or tuple position must be remembered;
- the object moves between components or states;
- additional fields are plausible;
- invariants or behavior belong to it;
- generic accessors such as `.first`, `.second`, or tuple indices obscure intent;
- nested generic containers make the representation harder to understand than the concept itself.

For example, this may be appropriate for transient values:

```cpp
return {minValue, maxValue};
```

But a representation such as:

```cpp
queue<pair<pair<int, char>, int>>
```

is a strong signal that the data structure has overtaken the domain model. If the system is manipulating tasks, prefer modeling a `Task` and then choosing the container that holds it.

The goal is not more types. The goal is to preserve the larger semantic model before optimizing local implementation convenience.
