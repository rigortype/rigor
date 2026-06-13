# 01 — Prioritise and classify

Covers **Phase 1** (pick the rule) and **Phase 2** (sample and
classify its sites).

## Phase 1 — Pick the rule to work

Do not walk the baseline top to bottom. Two commands decide the
order; run both.

### `rigor triage --format json` — the priority signal

```sh
rigor triage --format json
```

`rigor triage` runs the analysis and returns a structured summary —
a rule `distribution`, file `hotspots`, and a `hints` catalogue. It
is the deterministic diagnosis layer; use it rather than counting the
raw `rigor check` stream by hand. The `hints` array is the priority
signal — each hint has an `id`:

| Hint `id` | What it means for reduction | Priority |
| --- | --- | --- |
| `genuine-bugs` | Low-count, scattered rules — the localised bugs Rigor caught. | **Work these first.** Highest value per fix. |
| `systemic-file-cluster` | One file × one rule, large count. | One fix may clear many — high leverage. Or escalate as systemic. |
| `activesupport-core-ext`, `gem-without-rbs` | Config gaps, not code bugs. | **Not reduction work** — these are `rigor-project-init` territory (wire the RBS bundle). Flag to the user; do not walk site by site. |
| `project-monkey-patch` | A DSL / monkey-patch Rigor can't see. | Escalate — a `pre_eval:` entry or a plugin clears the whole cluster. |
| `activerecord-relation-misinference` | Likely an engine gap. | Treat sites as candidate false positives (Phase 2). |

### `rigor triage --format json` `.selectors` — the by-(class, method) axis

Beside `hints`, the triage JSON carries a `selectors` array: one row
per dispatch target the diagnostics cluster on, built from the
structured `receiver_type` / `method_name` fields (never message
parsing). Each row is `{receiver, method, count, files, rules}`. Use
it to pick *which sites within a rule* to sample first — and to tell a
systemic cause from a scatter of real bugs — with `jq`, not eyeballing
the stream:

```sh
# the dispatch targets responsible for the most diagnostics
rigor triage --format json | jq -r '.selectors[:15][] | "\(.count)\t\(.files)f\t\(.receiver)#\(.method)"'
# one method, one receiver, spread across many files → systemic
# (a plugin / pre_eval clears it) rather than N independent bugs
rigor triage --format json | jq '.selectors[] | select(.files >= 4)'
# narrow to a rule you are about to work, ranked by concentration
rigor triage --format json \
  | jq '[.selectors[] | select(.rules["call.possible-nil-receiver"])] | sort_by(-.count)'
```

Read it as: **high `count` × high `files` = a systemic selector**
(escalate as a decision — one fix clears the cluster); **low `count` =
a candidate genuine bug** to sample directly in Phase 2. The `receiver`
is a normalised class (`"hi".squish` and `name.squish` both bucket
under `String#squish`), so a single idiom does not scatter across rows.

### `rigor baseline dump --format json` — the bucket list

```sh
rigor baseline dump --format json
```

This is the authoritative list of `(file, rule, count)` buckets in
`.rigor-baseline.yml`. Within the priority tier the triage hints set,
**sort rules by ascending total count** — the smallest rules first.
A rule with 3 sites is either a quick win or a contained pattern;
either way it is finishable in one session, and finishing a rule is
more motivating than half-clearing a 200-site one.

So the working order is: rules flagged `genuine-bugs` first, then the
rest by ascending count, with config-gap hints handed back to the
user instead of walked.

## Phase 2 — Sample and classify

Pick the chosen rule. Surface its actual diagnostics — run
`rigor check` scoped to the affected files so the user sees real
messages, not baseline rows:

```sh
rigor check app/models/account.rb app/services/feed_service.rb
```

(The baseline still suppresses these in a full run; naming the files
and reading the stream shows them. `--no-baseline` also works if you
want the whole project's live stream.)

From the rule's sites, **sample 3–5 distinct ones** — different
files, different shapes, not five copies of the same line. For each
sampled site, read the code and classify it. Ask the user to confirm
when the call is not clear-cut.

### The three classifications

**Real bug** — Rigor found a genuine defect.

- A `possible-nil-receiver` where the value genuinely can be `nil` on
  some path and the code would crash.
- An `undefined-method` that is a real typo or a removed method.
- An argument-type mismatch that would raise or misbehave.
- Tell: trace the value's origin and you find a path that actually
  produces the bad case.

**Stylistic / safe** — the static reading is worst-case-sound, but
the site is fine in practice.

- `T | nil` where the slot is always initialised before this point
  by code Rigor's narrowing doesn't follow (a memoised getter, a
  framework lifecycle guarantee).
- A dynamic `send` over a known-finite, known-safe tag set.
- An idiom repeated across dozens of files — at that scale the
  pattern *is* the project's style.
- Tell: you can articulate *why* the bad case never reaches this
  line, and that reason is a real invariant, not a hope.

**False positive** — Rigor is simply wrong; a correct analyzer would
not flag this site.

- The narrowing should have followed an `&.` chain or an early
  `return`/`raise` guard and didn't.
- The receiver type is misinferred (e.g. an ActiveRecord relation
  typed as `Array`).
- Tell: the code is correct *and* a reasonable type checker should
  see that it is correct — the gap is in Rigor, not the code.

The distinction between "stylistic / safe" and "false positive"
matters: stylistic-safe sites get a `# rigor:disable` (the code stays
as is, the suppression is intentional); false positives get a Rigor
issue (the analyzer should improve). Both stay out of the count, but
only one of them is feedback Rigor's maintainers can act on.

Carry the per-site classifications into Phase 3
([`02-fix-or-suppress.md`](02-fix-or-suppress.md)).
