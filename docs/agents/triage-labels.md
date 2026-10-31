# Triage Labels

The engineering skills speak in terms of five canonical triage roles. This repo uses the default
strings unchanged:

| Role | Label in this tracker | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate this issue |
| `needs-info` | `needs-info` | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent` | Fully specified — an AFK agent can pick it up with no human context (named files, gates, criteria) |
| `ready-for-human` | `ready-for-human` | Needs human judgment or a decision before implementation |
| `wontfix` | `wontfix` | Will not be actioned |

Alongside the triage role, every backlog issue carries exactly one **area label**:

`area:engine` · `area:plugins` · `area:perf` · `area:sig-gen` · `area:editor` · `area:docs` ·
`area:playground` · `area:self-testing` · `area:release`

The bar for `ready-for-agent` is the ADR-43 shape: the issue names the injection point, the
constraint envelope, and the gate that proves it done. When in doubt, `ready-for-human`.

## Known limitations

`known-limitation` marks soundness or precision given up on purpose, or a current limit of the
engine or tooling, kept as future work. It is added on top of the triage and area labels, not in
place of them. File one when a change lands a deliberate tradeoff (a conservative floor that loses
true positives, a budget cut, an over-approximation) or leaves a known false-positive shape
unhandled; label the issue that still tracks a shape instead of filing a duplicate. The body
states:

- **Kind** — which way it errs: a false positive left on correct code, or true positives (precision)
  traded for false-positive safety.
- **Why** — the constraint that forced it, linking the PR and any `approval-queue.d/` entry.
- **Cost** — the measured or reproduced effect, with a minimal example.
- **Revisit when** — the change that would lift it, and what proves it done.

List them with `gh issue list --label known-limitation`.
