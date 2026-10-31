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

`known-limitation` marks a limit a change knowingly lands and keeps as future work: soundness or
precision given up on purpose, or a shape the binding spec (`docs/type-specification/`,
`docs/internal-spec/`) records as not handled. It is part of the documented contract, not an
unfixed defect, which is what separates it from an ordinary `bug`: a false-positive report nobody
has decided to leave is a `bug`. It is added on top of one triage label and one area label, never
in place of them.

File one when a change lands a deliberate tradeoff (a conservative floor that loses true positives,
a budget cut, an over-approximated resolution set) or ships with a shape it documents as not
followed. When an open issue already tracks the shape, label it instead of filing a duplicate, and
add a comment carrying the fields below. A limit that will never be lifted is not this label: say so
in the spec, or close the issue as `wontfix`. Close the issue when the limit is lifted.

The body (or, for a labelled existing issue, a comment) covers:

- **Kind** — which way it errs: a false positive left on correct code (soundness), precision traded
  for false-positive safety (lost true positives), or another limit (tooling, performance).
- **Why** — the constraint that forced it, linking the PR that made the call. An `approval-queue.d/`
  entry is deleted when it is ratified, so cite it only alongside the PR.
- **Cost** — the measured or reproduced effect, with a minimal example.
- **Revisit when** — the change that would lift it, and what proves it done.

List them with `gh issue list --label known-limitation --state all`.
