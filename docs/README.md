# docs/

| Directory | Contents |
|---|---|
| `adr/` | Architecture Decision Records — why the system is built this way |
| `milestones/` | Per-milestone: what changed, why, how to verify, how to undo |
| `diagrams/` | Mermaid source for architecture diagrams |
| `generated/` | **Machine-written.** Produced from `services.yml`. |

## ADRs

Every significant decision is recorded with context, alternatives considered,
trade-offs, consequences and follow-up actions. The alternatives sections
matter most: in a year, "why not nginx?" is answered without re-deriving it.

An ADR is never edited to reverse a decision. Write a new one that supersedes it.

## Milestone docs

Each milestone documents rollback. If a change cannot be undone, that is stated
explicitly rather than omitted.
