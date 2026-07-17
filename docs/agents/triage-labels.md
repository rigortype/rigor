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
