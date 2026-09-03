# CLI command reference

Every Rigor command is a subcommand of the single `rigor`
executable:

```sh
rigor <command> [options] [arguments]
```

`rigor help` prints the command list; `rigor version` prints
the installed version. An unknown command, or a malformed
option, exits `64` — the conventional "usage error" code.

Every command that loads your project configuration also
accepts `--config=PATH` to point at a specific config file
instead of auto-discovery (it is called out below only where it
has an additional effect).

## `rigor check`

Analyse Ruby source for type errors and report diagnostics.
This is the command you run day to day and in CI.

```sh
rigor check [paths...]
```

`paths` are files or directories; when omitted, Rigor checks
the `paths:` list from the configuration file.

| Option | Effect |
| --- | --- |
| `--config=PATH` | Use a specific config file instead of auto-discovery. |
| `--format=FORMAT` | Output format. Default `text`. Also `json` (structured stream), plus the CI-native renderings `sarif`, `github`, `gitlab`, `checkstyle`, `junit`, and `teamcity` — see [Running Rigor in CI](11-ci.md). |
| `--no-ci-detect` | Disable CI auto-detection — by default `text` output also emits the running CI's native annotations / hint (`RIGOR_CI_DETECT=0` does the same). See [Running Rigor in CI § auto-detection](11-ci.md). |
| `--explain` | Surface fail-soft fallback events as `info` diagnostics. |
| `--no-cache` | Skip the persistent cache for this run. |
| `--incremental` | Re-analyse only the files changed since the last run plus the files that depend on them, serving the rest from a cross-process disk snapshot (ADR-46). Diagnostics are identical to a full run; a config / gem / version change (or a file added or removed) transparently forces a full re-analysis. See [Caching](12-caching.md). |
| `--verify-incremental` | Acceptance gate: run the incremental analyzer against a full `--no-cache` run and assert the diagnostics are byte-identical, then exit (0 on match, 1 with the differing diagnostics on mismatch). Used in CI to guarantee `--incremental` never serves a stale result. |
| `--clear-cache` | Delete the cache directory before running. |
| `--cache-stats` | Print the on-disk cache inventory when finished — on stdout under `--format text`, on stderr under every other format, so machine-readable output stays a parseable document. `--clear-cache`'s and `--verify-incremental`'s notes follow the same rule. |
| `--[no-]stats` | Print a run summary (files, classes, memory, wall time) to stderr. Default on. |
| `--coverage` | Add a type-precision coverage block to the output (`coverage` object under `--format json`; a one-line summary in text mode). Off by default — it is a second precision pass over the analyzed files, the same scan [`rigor coverage`](#rigor-coverage) runs, so it is opt-in. |
| `--workers=N` | Dispatch analysis across `N` parallel worker processes (fork-based pool today; ADR-15). Default `0` (sequential). Applies to `--incremental` re-checks as well as full runs. |
| `--baseline=PATH` | Load a baseline file, overriding config. |
| `--no-baseline` | Ignore any configured baseline. |
| `--baseline-strict` | Fail the run on any baseline drift — a CI gate. |
| `--treat-all-as-inline-rbs` | Force-load `rigor-rbs-inline` with `require_magic_comment: false`, so every analysed file is treated as inline-RBS without the `# rbs_inline: enabled` comment (ADR-32). |
| `--bleeding-edge[=ids]` | Adopt the bleeding-edge overlay for this run, overriding the configured [`bleeding_edge:`](03-configuration.md) selection (ADR-50 § WD2). Bare adopts every queued feature; `--bleeding-edge=a,b` adopts only the named feature ids. Inspect it with [`rigor show-bleedingedge`](#rigor-show-bleedingedge). |
| `--no-bleeding-edge` | Ignore any configured `bleeding_edge:` selection for this run (adopt none). |
| `--no-tolerated-effects` | Check effect envelopes as if [`effects.tolerated:`](03-configuration.md) were empty — the audit switch for your discharge policy (ADR-103). Judgment only: the run, what it collects and its cache entry are identical either way, so this never costs a re-analysis. |
| `--tmp-file=PATH --instead-of=PATH` | Editor mode: analyse `PATH` using the buffer in `--tmp-file`. Both required together. Alone, only the buffer's own file produces diagnostics; add `--incremental` for whole-project scope (see below). |

Exit `0` when no error-severity diagnostics remain, `1` when
any are reported, `64` on a usage error.

### Editor mode scope

`--tmp-file` / `--instead-of` on their own analyse **only** the
buffer's file: fast, and blind to what the unsaved edit does to the
rest of the project.

Adding `--incremental` analyses the **whole project with the buffer
substituted** — the edited file and the files that depend on it are
re-analysed, everything else is served from the incremental snapshot.
An unsaved change to a method's return type therefore surfaces in its
callers, not just in the file being edited.

Two things to know:

- It needs a snapshot to reuse. Run `rigor check --incremental` once
  (it is also what a normal terminal check should use) and every later
  editor invocation gets whole-project scope. Without one, Rigor says
  so on stderr and analyses the buffer alone.
- An editor-mode run never writes the snapshot — the buffer's bytes
  exist only in your editor, and recording them would make the next
  ordinary run believe it had already analysed a file in a state it
  was never in.

`--verify-incremental` refuses a buffer: it compares against a full
analysis of the files on disk, which a buffer contradicts by
construction.

## `rigor init`

Write a starter configuration file.

```sh
rigor init [--path=PATH] [--force]
```

Writes `.rigor.dist.yml` by default. `--path` chooses a
different target; `--force` overwrites an existing file.
Exit `1` if the file exists and `--force` was not given.

## `rigor annotate`

Reprint a file with every line tagged by the type of the
expression it evaluates to, as a trailing `#=>` comment. See
[Inspecting inferred types](05-inspecting-types.md).

```sh
rigor annotate [--[no-]color] [--[no-]bat] [--format=text|json] [--config=PATH] FILE
```

`FILE` is required. Colour is auto-detected for a tty and
honours `NO_COLOR`; `--color` / `--no-color` override. When
colour is on and [`bat`](https://github.com/sharkdp/bat) is on
`PATH`, highlighting goes through bat (`--no-bat` opts out;
`--bat` warns if bat is missing and falls back to the built-in
colorizer). `--format=json` emits a `{ line => type }` map
instead of the annotated source. Exit `1` on a parse error or a
missing file.

## `rigor type-of`

Print inferred types at one or more source positions.

```sh
rigor type-of [options] FILE:LINE[:COL] [FILE:LINE[:COL] ...]
rigor type-of [options] FILE LINE COL
```

The colon form is repeatable and keeps argument order while
parsing and scope-indexing each file once. Omit `COL` to print a
table of up to 40 expressions that start on that line, outermost
first at each 1-based column; the table marks when further
expressions were omitted. The legacy three-argument form accepts
one exact position.

`--format=json` keeps one result as the original flat object and
wraps several results in a `results` array. Line queries add a
`line_enumerations` array whose `shown` and `total` counts make
truncation explicit. `--trace` records fail-soft fallbacks,
after the rows of a line table in text output. The editor-mode
`--tmp-file` / `--instead-of` pair is accepted as on `check`.

## `rigor trace`

Replay HOW the engine typed a file, step by step, as a
terminal animation. It is a teaching probe over the same
inference `rigor check` runs.

```sh
rigor trace [--delay=SECONDS] [--line=N] [--verbose] [--format=json] FILE
```

Each frame highlights the source range being evaluated next to
the scope's locals and describes one inference moment: a local
binding entering the scope (`bind`), branch types merging
(`union`), or a method call resolving — or fail-softening to
`Dynamic[top]` (`dispatch`). On a tty the replay steps on a key
press (`q` quits); `--delay` autoplays. `--verbose` adds every
expression enter/result frame, `--line=N` keeps only events on
one line, and `--format=json` dumps the raw event stream for
tooling or course material. See
[Inspecting inferred types](05-inspecting-types.md).

## `rigor type-scan`

Report `type_of` inference coverage across paths — a
diagnostic-of-the-diagnoser, useful when investigating why a
class infers poorly.

```sh
rigor type-scan PATH...
```

`--limit=N` caps the printed examples (default 10),
`--show-recognized` includes fully-covered classes,
`--threshold=RATIO` makes the command exit non-zero when the
unrecognized-node ratio exceeds `RATIO`, and `--format=text|json`
selects the output format.

## `rigor effects`

Report what each method *does* — its effect labels — rather
than what it returns, and manage the committed **effect
snapshot** that gates drift. Opt-in and observational: nothing
here emits a diagnostic or changes `rigor check`'s output, and
only `rigor effects check` ever exits non-zero. The workflow
around these verbs — the label vocabulary, how to read the
report at scale, the review loop and the CI step — is
[Effect labels](19-effect-labels.md).

```sh
rigor effects [PATH...]                       # the report
rigor effects {update,check,diff,explain}     # the snapshot
```

With no paths the report analyses the configured `paths:`. It
runs with effect collection enabled even when your `.rigor.yml`
carries no `effects:` block, so you can try it before
configuring anything; such an ad-hoc run shares no cache with
`rigor check`, because a run served from that cache would have
collected nothing.

Passing paths narrows the **analysis**, not just the output.
Labels are transitive over what was analysed, so a method whose
callees were not analysed reports fewer labels and a wider
"possibly more" than the same method in a whole-project run —
honest, but not a cheaper way to get the whole-project answer.
Filter the output when you want the real footprint.

Each line is one method, sorted by key:

```
Tracer::Reporter#report: [io.output.stdout, nondet.time]
Tracer::Gateway#fetch: [] …?
    dynamic-receiver (external_gem_without_rbs)
```

The labels are the **transitive** footprint — the method's own
plus every project method it reaches. A ` …?` suffix means the
list is not exhaustive: some call could not be resolved, so the
reading is "these effects, and possibly more". The indented
lines say why. A taint is never a finding.

A ` ≤ [...]` clause after the labels is the **declared** lane:
what a source Rigor trusts but did not verify *claims* the
method does. Two sources feed it — the plugins you activated,
which on a framework application contribute most of it
(`rails.session.write` and the rest of `rails.*` are Action
Pack's rows, not yours), and the `effects.attribution:` table
you wrote for gem methods nothing models. It is printed apart
from the proven labels and never folded in among them, because
the two answer different questions. It follows call edges exactly as
the proven labels do, so a controller two hops above an
attributed gem call carries the claim rather than only a
"possibly more"; a declared label the proven list already
covers is not printed twice.

```
Gateways::Client#fetch: [] ≤ [io.net.http] …?
    plugin-attribution (Acme::Http.get)
```

Two kinds of method are omitted: one that proves nothing
beyond `mutate.local` and claims nothing — mutation of objects
its own frame allocated and never let out, which every effect
envelope tolerates — and one with no label in either lane,
which exists only to record that something below it was
unresolved. `--full` lists both. `--pure` asks for the first
group by name, which is the set worth annotating `%a{pure}`.

`--label=LABEL` prints only the methods carrying `LABEL` or a
label under it, in either lane. `--limit=N` caps the rows.
`--why` expands each row's unresolved reasons and the plugin
row behind each declared label, which are collapsed to a count
by default. The report closes with a footer counting the two
lanes apart, because they have different powers: a proven label
can fail a build and a declared one cannot
([ADR-103](../adr/103-effect-labels.md) § WD17).

A `PATH` argument selects which methods are **printed**, never
which are analysed: Rigor analyses your configured `paths:`
either way, so a selected row carries exactly the labels the
whole-project run gives it, and a note on stderr says how many
of how many you are looking at. A path outside `paths:` is
analysed as well as them, so pointing the command at a tree
your configuration does not cover still works.

`--format=text|json` selects the output format; the JSON
payload additionally carries each method's *direct* summary
broken down per origin. `--config=PATH` picks a config file.
`--no-tolerated-effects` is accepted for symmetry with the
subcommands and does nothing here: the report is an
observation, and observations are undischarged.

What is collected and how it propagates is
[the effect-summaries internal spec](../internal-spec/effect-summaries.md).
`--list-labels` prints the vocabulary this project can name —
every shipped label with its root's meaning, plus whatever your
plugins and your `effects.labels:` opened — and exits without
analysing anything. The same table is in
[Effect labels § The label vocabulary](19-effect-labels.md), and
the grammar is specified normatively in the effect-labels
specification, which the gem does not ship:
<https://rigor.typedduck.fail/type-specification/effect-labels/>.

### The effect snapshot

Four subcommands manage a committed record of the effects
Rigor observed — `.rigor-effects.yml`, the effect equivalent
of `db/schema.rb`:

```sh
rigor effects update    # write the snapshot; commit it
rigor effects check     # 0 fresh, 1 drift — the CI gate
rigor effects diff      # the same comparison, never gating
rigor effects explain   # why an entry point reaches a label
```

Unlike the report, the subcommands take no paths: a snapshot
records the whole project, and one written over a subset would
read as a project where every other method vanished. They all
accept `--config=PATH`, `--format=text|json` and `--full`;
`check`, `diff` and `explain` additionally accept
`--baseline=PATH` (compare against a file other than the
configured one — `--baseline <(git show
origin/main:.rigor-effects.yml)` in a bot),
`--strict-tolerated` and `--no-tolerated-effects`.

The file records two tables. `methods:` holds each method's
**direct** summary — what its own body does, block literals
and catalogued callees included, but not what the project
methods it calls do. That is deliberate: an entry moves only
when its own lines changed, so the diff stays attributable to
the pull request that caused it. `reach:` holds the
**transitive** footprint at the entry points
`effects.snapshot.reach:` names, where a leaf change is
supposed to fan out — the fan-out is the blast radius.

```yaml
# .rigor-effects.yml — generated by `rigor effects update`. Commit it; review its diff.
schema: 2
rigor: "0.3.5"
vocabulary: 1
config_digest: "9ec82bfc…"
methods:
  "PaymentGateway#charge":
    effects: ["io.net.http", "telemetry"]
  "Reports::Nightly#perform":
    effects: ["io.db.read"]
    exhaustive: false
    unresolved: 1
reach:
  "OrdersController#create":
    effects: ["io.db.read", "io.net.http", "job.enqueue"]
```

A method is left out when it is exhaustive and proves nothing
beyond `mutate.local`, when its summary is a synthesised
accessor's, and when it carries no label in either lane — a
row that would say only "not exhaustive, and here is why" is
something `rigor effects` and `rigor effects explain` answer
better than a committed record. `--full` records everything.
The header carries
the Rigor and vocabulary versions and a digest of your
`effects:` block, so an upgrade or a policy edit shows up as a
*regeneration event* rather than as silent reinterpretation.

Under `methods:` the declared lane is what that method's own
body claims; under `reach:` it is the transitive claim, like
the proven labels beside it.

`check` prints one line per difference: `+ label` / `- label`
for the proven lane, `≤+` / `≤-` for the declared one,
`materialised` when a declared label became proven,
`exhaustive → not` when someone introduced a call Rigor cannot
follow, and `+symbol` / `-symbol` for methods that appeared or
vanished (a rename is one of each, counted in the footer). A
removal read off a summary that is no longer exhaustive is
printed hedged — "possibly more" cannot prove an absence.

`effects.snapshot.gate:` decides what fails. `symmetric` (the
default) fails on any drift: a job that stopped enqueueing is
news too. `additions` is the ratchet — only growth fails.
`effects.tolerated:` is applied at judgment time, never while
writing: a difference confined to tolerated labels is printed
under a `tolerated:` heading and does not fail the gate unless
you pass `--strict-tolerated`. `--no-tolerated-effects` judges
as if the list were empty; on `update` it changes nothing,
because the record itself is undischarged.

Discharge works **per origin**, not per label. `Logger#info`
carries `io` and `telemetry` together, so `tolerated:
[telemetry]` frees the `io` that came with the logging — and
leaves an `io.fs.read` from a `File.read` two lines down
exactly where it was. An added label is discharged only when
every origin that introduces it is discharged.

### Reviewing effect drift

Day one, run `rigor effects update` and commit the result. The
diff you are committing is the team's first map: which
controllers reach the network, which jobs write, which
presenters query.

Add `rigor effects check` to CI. From then on a pull request
that changes what the code *does* fails it with the reason
spelled out:

```
Effect drift against .rigor-effects.yml:

methods:
  PaymentGateway#charge  + io.net.http  (app/services/payment_gateway.rb:18)

reach:
  OrdersController#create  + io.net.http  (app/controllers/orders_controller.rb:7)

Run `rigor effects explain` to see what caused this, and `rigor effects update` to accept it.
```

Each row names where the method is defined, so the reviewer reads the report
rather than searching for the method.

The author runs `rigor effects explain` to see the route —

```
reach:
  OrdersController#create → OrderService#place → PaymentGateway#charge → Net::HTTP.get [io.net.http]
```

— then runs `rigor effects update` and commits the regenerated
file. **Intent is expressed by committing the regenerated
snapshot**, not by annotating the code; the reviewer reads the
two-line diff alongside the code change and either nods or
pushes back. A bundle update that moves effects with no code
diff of its own works the same way, and is exactly the case
worth seeing.

None of this is a diagnostic. `rigor check`'s output and exit
code are identical whether or not you use the snapshot, and
drift is never a finding: whether it *matters* is the
reviewer's judgment, which is what makes it a review artefact.

## `rigor explain`

Print the catalogue entry for a diagnostic rule, or list every
rule when called with no argument.

```sh
rigor explain [rule]
```

`rule` is a rule ID (`call.undefined-method`), a legacy alias,
or a family wildcard (`call`, `flow`, `def`, `assert`, `dump`).
`--format=json` is available. Exit `64` for an unknown rule.

## `rigor diff`

Compare the current diagnostics against a saved baseline JSON
and report only what is new.

```sh
rigor diff <baseline.json> [paths...]
```

`--current=PATH` compares against a saved diagnostics JSON
instead of running a fresh check. Exit `1` when new
diagnostics appear.

## `rigor sig-gen`

Emit RBS signatures inferred from your Ruby source. See
[handbook chapter 11](../handbook/11-sig-gen.md) for the
classification model and the `--params` policy.

```sh
rigor sig-gen [paths]
```

| Option | Effect |
| --- | --- |
| `--print` | Write RBS to stdout. Default. |
| `--diff` | Write a unified diff against existing RBS. |
| `--write` | Write RBS to `sig/<path>.rbs` files. |
| `--overwrite` | Allow tighter-return updates to replace user-authored RBS. |
| `--include-private` | Emit private and protected methods too. |
| `--params=untyped\|observed\|observed-strict` | Parameter-typing policy. Default `untyped`. |
| `--observe=PATH` | Scan `PATH` for call-site observations. Repeatable. |
| `--new-files` / `--new-methods` / `--tighter-returns` | Emit only that classification. |
| `--format=text\|json` | Output format. |

Every signature is parsed before it is emitted. A method whose
generated RBS does not parse is **skipped** (`sig.skipped.unrenderable-rbs`)
and reported on stderr rather than written — an unparseable
`.rbs` is quarantined *whole* by `rigor check`, so one bad line
would take every other type in the file down with it. Under
`--write`, a file whose assembled content does not parse is
**refused** (the existing file is left untouched) and the command
exits `1`: you asked for a write and did not get one. Such a skip
is a bug in Rigor's RBS rendering, not in your code — please
report it.

## `rigor lsp`

Run the Language Server over stdio. See
[Editor integration](09-editor-integration.md).

```sh
rigor lsp [--transport=stdio] [--log=PATH] [--config=PATH]
```

`stdio` is the only transport in v1. `--log=PATH` is accepted
but not yet wired in this release — it is reserved for routing
the server's wire log to a file; until then logging stays on
stderr.

## `rigor baseline`

Manage diagnostic baselines. See [Baselines](06-baseline.md)
for the file format and workflow.

```sh
rigor baseline <generate|regenerate|dump|drift|prune> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `generate` | Write a fresh baseline from the current diagnostics. Refuses to overwrite without `--force`. |
| `regenerate` | Rewrite the baseline unconditionally — use after a quality pass. |
| `dump` | Print the baseline contents, filterable by `--rule` and `--file`. |
| `drift` | Audit how each bucket has drifted; filter with `--only=within\|over\|cleared\|reducible`. |
| `prune` | Drop buckets that no longer match any diagnostic. `--dry-run` previews. |

`generate` and `regenerate` accept `--output=PATH` and
`--match-mode=rule|message`; `dump`, `drift`, and `prune` accept
`--baseline=PATH` to read a non-default baseline file.

## `rigor triage`

Summarise a diagnostic stream — rule distribution, **class/method
selectors**, per-file hotspots, and heuristic "why" hints — instead
of dumping the raw list. See [Baselines](06-baseline.md).

```sh
rigor triage [paths]
```

`--top=N` sets the hotspot count (default 10); `--hints-only`,
`--selectors-only`, and `--no-hints` select which sections print.
`triage` is advisory and always exits `0` — it never gates a build.

By default the distribution, selectors, and hotspots sections count
only the **actionable** diagnostics (`error` + `warning`). `info`
diagnostics are excluded from these volume views — on a Rails project
they are dominated by plugin *recognition trace* (`Account.find
resolves to Account`, `users_path → GET /users`), positive "Rigor
resolved this" records that would otherwise bury the genuine signal
and skew the hotspot ranking toward the files with the most *working*
code. The summary line still reports the full `info` count, and
heuristic hints still see every diagnostic (so the `gem-without-rbs`
notice survives). Pass `--include-info` to route `info` into the
volume views as well.

The **`selectors`** section is the by-(class, method) axis: it
aggregates the structured `receiver_type` / `method_name` fields the
diagnostics carry into `{receiver, method, count, files, rules}`
rows, so you can ask "which method concentrates the diagnostics?"
without parsing message text. Under `--format json` the full list is
emitted, keyed on a normalised receiver class (literals fold to their
class), ready for a `jq` query:

```sh
# methods with diagnostics spread across ≥ 3 files (systemic clusters)
rigor triage --format json | jq '.selectors[] | select(.files >= 3)'
# everything Rigor flagged on String receivers, by method
rigor triage --format json | jq '[.selectors[] | select(.receiver == "String")]'
```

The same `receiver_type` / `method_name` fields ride on each
diagnostic of `rigor check --format json`, for per-site (rather than
aggregated) grouping.
## `rigor unused`

Report project constants that nothing reachable references — a
starting point for dead-code removal.

```sh
rigor unused [paths] --entry-point='lib/cli.rb'
```

**Read the output as a review queue, not a defect list.** On a
hand-adjudicated corpus target only **7% of the rows were genuinely
unused**; the rest were reachable by means static analysis cannot
see. That is why this is a separate command and never a `rigor check`
diagnostic — see
[ADR-102](../adr/102-unused-code-reachability-report.md).

Reachability is computed from **roots**, not by counting references,
so a cluster of classes that only reference each other is still
reported. Roots are the declarations in files matching
`--entry-point=GLOB` (repeatable), anything referenced at file level
by non-test code, and anything the project's **plugins** contribute.

Plugin-supplied roots are where framework knowledge enters. A Rails
controller is reached by name at request time, so nothing in the
project references it and a reference index cannot tell a live
controller from a dead one. `rigor-rails-routes` closes that by
reading `config/routes.rb` statically and naming every controller it
dispatches to — no Rails boot, and a route written under a
conditional (`get "/beta", to: "beta#index" if ENV["BETA"]`) is
visible where a booted app's route table would not show it. On two
Rails corpus targets this removed 56 % and 84 % of the candidate list.

`rigor unused` loads the same `plugins:` your `rigor check` run uses,
and prints how many roots came from them:

```
  roots:                    404 (288 from plugins, 0 matched no declaration)
```

`matched no declaration` is the number a plugin claimed that this
project does not declare — normally framework classes such as
`Rails::HealthController`. A number climbing away from zero means a
root source has drifted out of step with the code, which matters
because an over-claiming root source silently *hides* dead code. A
framework Rigor has no plugin for supplies no roots, so its
controllers still read as candidates.

`rigor-pundit` supplies the second kind of root: a policy class is
reached as `PostPolicy` from `authorize @post`, a name that appears
nowhere in the source. It publishes the policies your authorization
calls actually name — not every class under `app/policies`, because a
file's location is not evidence that anything authorizes against it.

`rigor-sidekiq` shows how narrow a root source has to be to be worth
having. A worker named as `class: "NightlyReportWorker"` in a cron
schedule is enqueued from YAML, so its name appears nowhere in the
code and it reads as dead — that name becomes a root. The queue list
in the same `sidekiq.yml` does not: a queue name is not a class name,
and inflecting one into a worker name would root a class on a naming
coincidence.

A plugin can also contribute a **reference** rather than a root, and
`rigor-factorybot` is why the distinction exists. `factory :user,
class: "Admin::User"` names a class as a string the scan cannot see,
so it is real evidence of use — but a factory lives in the test tree.
Supplied as a reference carrying the `test` role, the class leaves
the candidate list and appears under *Reachable only from test code*;
supplied as a root it would have been promoted to
production-reachable, and the more interesting finding would have
disappeared.

Most bundled plugins deliberately contribute nothing.
`MyJob.perform_later`, `MyMailer.welcome`, `MyWorker.perform_async`
and `RSpec.describe User` all write the class name as an ordinary
constant, which the report already records — and for the spec case,
records with the `test` role that makes the section above possible.
Each plugin's page says which choice it made and why.

Three things the report separates rather than merges:

- **Reachable only from test code** gets its own section — a class
  used solely by its own spec is dead production code with a live
  test, which is a more actionable finding than either bucket alone.
- **Constants something can name at runtime** are demoted to a
  `cannot decide` section with the reason, never claimed as unused.
  `"Foo".constantize` names `Foo` exactly, so it counts as an ordinary
  reference; `"Foo::#{key}".constantize` instead marks everything
  under `Foo` undecidable. A class name appearing as a string in a
  `.yml`, `.json`, or template file demotes it the same way — that is
  weaker evidence than a constant reference, so it is neither proof of
  use nor grounds to call it dead.
- **Namespace modules** wrapping live code are excluded and counted,
  because nothing references an intermediate namespace by itself. A
  namespace whose contents are *all* unreachable is still reported.

Only class and module constants are reported at all; value constants
are omitted because they do not resolve across files.

References are harvested from a wider file set than the analysed
paths — `.rake` tasks, `config/`, specs and the project's own `sig/`
all count as references — because a constant used only from a Rake
task is not dead.

`--format json` emits the same data; `--limit=N` truncates the
printed lists. `--incremental` is refused: reachability is only sound
over a whole-project run.

## `rigor coverage`

> For the value proposition and a workflow guide to the
> `--protection` tiers, see
> [Type-protection coverage](15-type-protection-coverage.md). This
> section is the flag reference.

Report type-precision coverage — the ratio of call sites that
resolve to a precise type versus those that fall back to
`Dynamic`. A quality gate for "how much is Rigor actually
inferring".

```sh
rigor coverage [paths]
```

`paths` are files or directories; when omitted, Rigor uses the
`paths:` list from the configuration file (default `lib`), the same
as [`rigor check`](#rigor-check).

`--format=text|json` selects the output format and
`--config=PATH` overrides config discovery. `--threshold=RATIO`
exits `1` when the precision ratio falls below `RATIO`
(`0.0`–`1.0`), making it a CI gate.

`--protection` switches to **type-protection coverage**: it
reports "if I introduce a bug, would Rigor catch it" rather than
"how precise are my types". Each dispatch site (a call with an
explicit receiver) is *protected* when the receiver types to a
concrete class (a site where Rigor's call rules can catch a
wrong method or argument) and *unprotected* when the receiver is
`Dynamic`. The report leads with the protected ratio, then a
ranked "add a type here" list (the methods most often called on
an untyped receiver), then the least-protected files;
`--threshold` and `--format=json` work the same. It is a sound
upper bound on real protection — a concrete receiver is necessary
but not sufficient for a diagnostic to fire. `--workers=N`
fork-parallelizes the protection scan (both the parameter-inference
pre-pass and the per-file scan) with output byte-identical to a
sequential run; it resolves the worker count the same way `check`
does — `--workers` › `RIGOR_RACTOR_WORKERS` ›
[`parallel.workers:`](03-configuration.md) › `0` (sequential
default).

Adding `--mutation` (with `--protection`) switches to the
**effectiveness** tier: it measures whether Rigor *does* catch a
bug, rather than whether it *could*. It introduces
type-visible breakages at each dispatch site — dropping a
call-argument to `nil`, swapping its type, renaming a call to a
missing method — re-analyses the mutated source against a clean
baseline, and reports the kill rate (caught breakages). It
defaults to the git-changed `.rb` files (whole-project is
minutes; pass explicit paths to widen), and leads with the
effectiveness ratio, then the breakages Rigor missed ("add a type
here"), then the least-effective files. `--threshold` gates on
the effectiveness ratio and `--format=json` carries `mode`,
`killed`, `survived`, `effectiveness_ratio`, per-file rows, and
`add_a_type_here`. It is the truth tier behind the static
`--protection` proxy, at the cost of many analyses — an opt-in CI
deep-dive, not an interactive check. `--workers=N` fork-parallelizes
this tier too (the whole-project pre-pass is paid once on the parent
and the per-file measurement is spread across workers), with the
same precedence chain and the same byte-identical output.

```sh
rigor coverage --protection --mutation [paths]
```

Adding `--with-tests` (with `--protection --mutation`) turns
that into the **fused static∪dynamic** view: for each breakage
the type checker does *not* catch, it runs your test suite to see
whether a **test** catches it. Each site is then classified
`type-protected` (the type checker caught it), `test-protected`
(a test caught what the type checker missed), or `unprotected`
(neither — the actionable "add a type **or** a test here" list),
and the report names the cheaper missing axis. A type-killed
mutant never reaches the suite (a gradual short-circuit), so the
cost is proportional to the protection hole. `--format=json`
carries `mode` (`protection-fused`), `type_killed`,
`test_killed`, `unprotected`, `protected_ratio`, per-file rows,
and `add_protection_here`; `--threshold` gates on the fused
ratio. This tier is always sequential — the suite hook shells out
to your test runner, and concurrent runs would race over one
working tree — so `--workers` does not apply and an explicit one
is reported as ignored on stderr.

`--test-command=CMD` is the runner hook (default
`bundle exec rake`). The suite must pass on clean code first, or
the run aborts — point it at a plain pass/fail runner (a coverage
floor that exits non-zero on a passing suite trips this). It runs
with Bundler's environment stripped, so a `bundle exec` command
resolves your project's bundle even when Rigor itself was
launched under its own, with no env wrapper needed. The command
runs **without a shell** (it is split into an argv and executed
directly), so shell constructs are not interpreted — including an
inline `BUNDLE_GEMFILE=… ` prefix. For a non-default Gemfile, set
it with `bundle config set --local gemfile PATH` (it persists in
`.bundle/config`) or wrap the command in `bash -c '…'`.

`--include-dynamic` extends the overlay to `Dynamic`-receiver
(untyped) sites, where a test is the only possible protection —
completing the map to *every* dispatch site rather than only the
ones Rigor can type-check. Every such site is a type-survivor, so
it runs the suite far more; it is an explicit opt-in.

`--limit=N` (with `--seed=N`, default `1`) caps the measurement
to a deterministic sample of `N` mutations per file, bounding the
cost on large files. Per-file ratios then become estimates, noted
on stderr so `--format=json` stdout stays clean.

A re-run is served from a per-file measurement cache while
nothing that could change a file's number has moved: the file
itself, any file it was recorded as reading from, the resolved
configuration, `sig/`, the gem set, the engine version, `--limit`
/ `--seed`, and the adopted bleeding-edge features. It reads the
cross-file edges a `rigor check --incremental` run records, so
warm one once per project; without a usable snapshot every file
is measured, never silently served. `--no-cache` measures
everything from scratch. A one-line stderr report says which of
those happened — see
[Type-protection coverage](15-type-protection-coverage.md).

```sh
rigor coverage --protection --mutation --with-tests \
  --test-command "bundle exec rspec" --include-dynamic [paths]
```

## `rigor mcp`

Run the Rigor MCP (Model Context Protocol) server over stdio,
so AI coding assistants can call Rigor tools directly. See
[MCP server](10-mcp-server.md).

```sh
rigor mcp [--transport=stdio] [--config=PATH]
```

`stdio` is the only transport. The server is a pure-Ruby
JSON-RPC 2.0 implementation exposing seven read-only tools:
`rigor_check`, `rigor_type_of`, `rigor_triage`,
`rigor_annotate`, `rigor_sig_gen`, `rigor_explain`,
`rigor_coverage`.

## `rigor lsp` vs `rigor mcp`

`lsp` speaks the Language Server Protocol to editors; `mcp`
speaks the Model Context Protocol to AI assistants. Both run
over stdio and wrap the same analysis engine.

## `rigor plugins`

Report the activation status of every plugin configured in
`.rigor.yml` — loaded, load-error (with reason), and each
plugin's declared extension surfaces. See [Plugins](07-plugins.md).

Each loaded plugin's row also reports the resolved file it
loaded from (a `path:` line in text, a `"path"` key in JSON), so
if a stale installed gem is shadowing a newer checkout's bundled
plugin copy the mismatch is visible at a glance.

```sh
rigor plugins [--format=text|json] [--strict] [--capabilities] [--config=PATH]
```

Without `--strict` the command always exits `0`; with
`--strict` it exits `1` when any plugin failed to load (a CI
gate).

`--capabilities` switches to the **extension-protocol
catalogue** ([ADR-37](../adr/37-plugin-interface-segregation.md)):
a focused, machine-readable map of what each loaded plugin
contributes — the AST node types its `node_rule`s match, the
receiver classes its `dynamic_return`s gate on, the methods its
`narrowing_facts` hooks narrow, and the facts it `produces` /
`consumes`. Combine with `--format=json` for tooling (an AI
agent can enumerate every plugin's behaviour without reading a
line of plugin source). The same narrow surfaces also appear in
the default full report. Not to be confused with the singular
`rigor plugin`.

## `rigor plugin`

Browse the on-disk source of the plugins bundled in the
toolchain, so you can read a real, working plugin as a worked
example when authoring your own.

```sh
rigor plugin <list|path|print|root> [name]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | Table of every bundled plugin and example, name + absolute directory path (default when no subcommand given). |
| `path <name>` | One-line absolute path to the plugin's directory. |
| `print <name>` | A header (dir / lib / sig / README paths) followed by the plugin's main source body inlined. |
| `root` | The `rigortype` gem root and its key subdirectories. |

Paths resolve at runtime from the gem location (a documented
caveat for container / cross-filesystem setups).

## `rigor playground`

Start the browser playground (a CodeMirror editor with
real-time diagnostics). Requires the separate `rigor-playground`
gem; if it is not installed the command prints an install hint
and exits `64`.

```sh
rigor playground
```

## `rigor skill`

List or print the bundled Agent Skills shipped inside the
`rigortype` gem, so an AI coding agent installed alongside
Rigor can discover and follow them without a project-side
source checkout. See [Skills](08-skills.md).

The positional slot is a skill *name*; alternative outputs are flags,
so a skill can never be shadowed by a verb.

```sh
rigor skill [<name>] [--full <name>] [--path <name>] [--list] [--describe]
rigor skill describe [--deep]
```

| Form | Purpose |
| --- | --- |
| (none) / `--list` | Table of every bundled skill (name + absolute path). |
| `<name>` | Print the `SKILL.md` body to stdout, with a header pointing at the skill's `references/` directory. |
| `--full <name>` | Print the `SKILL.md` body **followed by every `references/*.md` inline** — the complete, version-current procedure in one call. This is what a skill's "First: load the version-current copy" directive points at, so a copy vendored into a project (e.g. via `npx skills add`) re-fetches its current steps from the installed gem instead of following a frozen copy. |
| `--path <name>` | Print the single-line absolute `SKILL.md` path, suitable as input to a file-reading tool. |
| `--describe` | Probe the project's state (config / baseline / `sig/` / CI — presence only, never runs `rigor check`) and recommend the next skill to run. Also spelled `describe`; surfaced top-level as [`rigor describe`](#rigor-describe) below. |
| `describe --deep` | The same report, except it **runs `rigor check` first** and routes the headline recommendation on the result. Opt-in, because it costs a full analysis and writes `.rigor/cache` — the un-flagged form stays presence-only and side-effect-free. |

### `describe --deep`

By default the recommendation comes from a presence-only probe, so it can
tell that a project *has* a config but not whether the analysis is
healthy. `--deep` runs the check for you and lets the result pick the
headline, using the same routing the `## For the agent` section already
teaches:

| Deep check result | Headline becomes |
| --- | --- |
| RBS environment built to 0 classes, or a `configuration-error` diagnostic | `rigor-doctor` — the analysis is hollow until the setup is fixed. |
| Call sites resolving to the project's own definitions (reopened core / gem classes), as at least a third of the errors | `rigor-monkeypatch-resolve` — list them in `pre_eval:` and they clear wholesale. |
| Any remaining error diagnostics | `rigor-baseline-reduce`. Proven monkey-patch sites below that share are still reported here, so the finding survives even when the headline stays on the larger problem. |
| Clean, or the project has no config yet | Unchanged — the presence-only recommendation stands. |

If the check **cannot run at all** (no config, an unloadable plugin, a
malformed config) `--deep` does not fail and does not pretend the project
is clean: it reports what went wrong, falls back to the presence-only
recommendation, and points you at `rigor doctor`. It deliberately does
*not* route on weaker signals — "framework calls typing as `Dynamic`" is
still a judgement call left to you and your agent.

```sh
rigor skill describe --deep   # also: rigor describe --deep
```

The verb spellings `rigor skill list` / `print <name>` / `path <name>`
were **removed in v0.3.0** — the positional slot is a skill name, so
they now read as an unknown skill. Use the forms above.
`describe` / `--describe` stay first-class.

## `rigor describe`

Top-level alias for [`rigor skill describe`](#rigor-skill) — the
onboarding entry point that recommends the next skill for this project.
A bare `rigor describe` is the intuitive guess most users reach for
first, so it is surfaced as its own command ([ADR-73](../adr/73-skill-driven-user-experience.md)
§ WD2).

```sh
rigor describe
```

It reports a presence-only project-state probe (does a `.rigor.yml`,
`.rigor-baseline.yml`, `sig/` directory, or CI integration exist?) and a
recommended next skill. It is read-only and side-effect-free — it never
runs `rigor check`. Identical output to `rigor skill describe`.

`rigor describe --deep` forwards to
[`rigor skill describe --deep`](#rigor-skill), which opts into running the
check first — slow, and it writes the cache.

## `rigor docs`

Print the documentation bundled inside the `rigortype` gem
**offline**, so once Rigor is installed an AI coding agent (or you) can
read the drive-Rigor guidance the SKILL-driven UX routes to without the
network ([ADR-74](../adr/74-offline-doc-access-and-llms-txt.md)). It is
the doc twin of [`rigor skill`](#rigor-skill): the gem ships
`docs/install.md`, `docs/llms.txt`, and the full user-facing
[manual](README.md) and [handbook](../handbook/README.md); the
contributor-facing ADR / spec / notes corpus stays web-only on the site.

The positional slot is a doc *name*; alternative outputs are flags.

```sh
rigor docs [<name>] [--path <name>] [--list [<category>]]
```

| Form | Purpose |
| --- | --- |
| (none) | Print the bundled `llms.txt` offline doc index — the map of what `rigor docs <name>` can serve. |
| `<name>` | Print a doc page to stdout, prefixed with a provenance comment. Accepts a category-qualified path (`handbook/03-narrowing`), the chapter's prefixed name (`02-cli-reference`), its short name (`cli-reference`, when unique), or `install`. |
| `--path <name>` | Print the single-line absolute path of a doc, suitable as input to a file-reading tool. |
| `--list [<category>]` | Table of every bundled doc (name + absolute path); pass `manual` or `handbook` to filter. |

The verb spellings `rigor docs list` / `path <name>` were **removed in
v0.3.0** — the positional slot is a doc name, so they now read as an
unknown doc. Use `--list` / `--path`.

The canonical web copy of the index is
<https://rigor.typedduck.fail/llms.txt>; `rigor docs` serves the same
pages from the installed gem with no HTTP request.

## `rigor show-bleedingedge`

Print the **bleeding-edge overlay** — the Rigor-maintained set of
the next major's queued changes ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
§ WD2) — and report which of them the project's
[`bleeding_edge:`](03-configuration.md) configuration adopts. Read-only:
it loads `.rigor.yml` to resolve the active selection but runs no
analysis.

```sh
rigor show-bleedingedge [--config PATH] [--format text|json]
```

| Flag | Purpose |
| --- | --- |
| `--config PATH` | Use this `.rigor.yml` instead of auto-discovery. |
| `--format text\|json` | Output format. Default `text`. |

Each queued feature appears with its stable id, its **kind** — `severity`
or `behaviour` — and whether your configuration adopts it. A `severity`
feature also prints the rule → severity diff it imposes; a `behaviour`
feature changes a measurement, an algorithm, or a default without moving
any rule's severity, so it has no such diff and its summary is the whole
description. See [`docs/compatibility.md`](../compatibility.md) for how
bleeding-edge fits the stability model.

Queued today:

| Feature id | Kind | What it changes |
| --- | --- | --- |
| `reject-unparseable-signatures` | severity | A broken RBS set **fails the run** instead of degrading it silently: an unparseable `.rbs` under `signature_paths:` (`rbs.coverage.quarantined-signature` → `error`), a declaration that collides on resolve and collapses the whole environment (`rbs.coverage.environment-build-failed` → `error`), and a duplicate method definition that collapses one class's method surface (`rbs.coverage.definition-build-failed` → `error`). |
| `use-of-void-value` | severity | Using a value recovered from an author-declared `-> void` return in value context is reported as `static.value-use.void` (`warning`). |
| `discovery-seeded-mutation-sites` | behaviour | [`rigor coverage --protection --mutation`](15-type-protection-coverage.md) measures against the same cross-file project discovery Tier 1 already uses — both when picking the sites and when deciding whether a breakage was caught — so a call on a project class declared in a *sibling* file is measured instead of dropped, and a breakage there can actually be caught. **Adds sites to the denominator, so the reported effectiveness ratio moves** — check it against any `--threshold` you pin in CI before adopting. |
| `dependent-closure-kill-oracle` | behaviour | [`rigor coverage --protection --mutation`](15-type-protection-coverage.md) counts a breakage as caught when the diagnostic appears anywhere in the mutated file **or the files that depend on it**, instead of in the mutated file alone — so changing what a method returns counts as caught when the error lands in its callers. Can only **add** kills, so the ratio moves up or not at all; it costs about a third more wall time per mutant, and a ratio measured under it is not comparable with one measured without it. |
| `effects-on-by-default` | behaviour | A project whose `.rigor.yml` carries no [`effects:`](03-configuration.md#effect-labels) key at all is treated as if it had written `effects: {}` — [effect collection](03-configuration.md#effect-labels), the `rigor effects` verbs' cache sharing, and `effects.check` all turn on with every sub-key at its default. Writing `effects: false` explicitly still opts out. **Scheduled to graduate at v0.4.0** ([ADR-103](../adr/103-effect-labels.md) § WD15) rather than at the next major — an owner ruling specific to this feature, ahead of the general v1.0.0 majors-only cadence below. |

Once a feature **graduates** — it becomes the default at a major
([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) § WD7)
— it leaves the queued list and appears under `Graduated`, an
acknowledgement that naming it in `bleeding_edge:` no longer does
anything: the behaviour is on for everyone. The section is absent while
nothing has graduated. In `--format json` the same information is the
`graduated` array, alongside `overlay` (every queued feature, each with
its `kind`), `active`, and `unknown_selected`.

## `rigor doctor`

Classify setup problems vs a clean run with routed next actions
([ADR-77](../adr/77-doctor-and-upgrade-commands.md) WD1).

```sh
rigor doctor [--config PATH] [--format text|json]
```

| Flag | Purpose |
| --- | --- |
| `--config PATH` | Use this `.rigor.yml` instead of auto-discovery. |
| `--format text\|json` | Output format. Default `text`. |

Runs a scoped analysis and audits:

- **Configuration audit** — unresolved `signature_paths:`, unknown
  `libraries:`, inert `disable:` / `severity_overrides:` tokens.
- **RBS environment health** — whether the RBS class universe built
  successfully (`0` classes means a broken setup).
- **Plugin load errors** — whether every configured plugin loaded.
- **Baseline drift** — whether the current diagnostics have drifted
  from the saved baseline.
- **Rails plugin gap** — whether `Gemfile.lock` contains Rails gems
  but no Rails plugin is enabled.
- **Gemfile install** — whether Rigor itself resolves as one of the
  project's dependencies, which
  [Installing Rigor](01-installation.md) tells you not to do. Only a
  `rigortype` resolved from a **GEM** remote counts: a `PATH` or `GIT`
  source means you are developing or vendoring Rigor deliberately,
  and Rigor's own repository looks exactly like that.
- **Plugin installation skew** — whether a plugin Rigor bundles
  loaded from a different `rigortype` installation than the engine,
  naming both paths. The engine and its bundled plugins are
  versioned together, so a copy from another installation can run
  the engine with a mismatched plugin. A warning, not a failure;
  third-party plugins from your own bundle are never flagged.

Text output prints `[PASS]`, `[FAIL]`, or `[WARN]` per check plus a
routed hint (e.g. "Run `rigor baseline regenerate`"). JSON output
is a stable contract:

```json
{
  "status": "issues_found",
  "checks": [
    { "id": "config_audit", "status": "fail", "message": "...", "hint": "..." }
  ]
}
```

Exits `1` when any check fails, `0` when all pass.

## `rigor upgrade`

Migration command skeleton ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
WD7). The real body lands when a concrete backwards-compatibility
break gives it a target (e.g. re-running `baseline regenerate`
against a strengthened default profile, surfacing renamed
suppression ids, reporting `bleeding_edge:` graduations).

```sh
rigor upgrade
```

Until then it prints the current version and notes that upgrade is
queued. Exits `0`.

## Environment variables

Most behaviour is driven by flags and `.rigor.yml`; a few
operational knobs read the environment instead.

| Variable | Effect |
| --- | --- |
| `NO_COLOR` | Disable coloured output (honoured by `rigor annotate`; `--no-color` does the same). |
| `RIGOR_CI_DETECT=0` | Turn off CI auto-detection — the same as `--no-ci-detect`. See [Running Rigor in CI § auto-detection](11-ci.md). |
| `RIGOR_RACTOR_WORKERS=N` | Worker count for parallel analysis. Sits between the CLI flag and the config key in precedence: `--workers=N` > `RIGOR_RACTOR_WORKERS` > `parallel.workers:` > `0` (sequential). |
| `RIGOR_POOL_BACKEND=ractor` | Opt back into the (off-by-default) Ractor worker pool instead of the active fork-based pool ([ADR-15](../adr/15-ractor-concurrency.md)). Only relevant with a non-zero worker count; the fork pool is the supported backend. |
| `RIGOR_LSP_POOL_MIN_BATCH=N` | Fewest buffers an [`rigor lsp`](#rigor-lsp) batch must carry before analysis is dispatched across the worker pool rather than run in-process (default `16`). Lower it if your project's per-file analysis is expensive enough that pooling pays off sooner. |
| `RIGOR_PLUGIN_ISOLATION=none\|process\|ruby_box` | How a plugin's direct calls into its target library are isolated. Default `process`. See [Using plugins § Isolation strategy](07-plugins.md). `RIGOR_BOX` is a legacy alias for `ruby_box`. |
| `RIGOR_STRICT_VALIDATION=1` | Force full-content cache validation for one run (the same as `cache.validation: digest`, and winning over it) — re-hash every file's content instead of trusting its stat metadata. Use it if a filesystem's timestamps or inode numbers cannot be trusted. See [Caching § How a file is checked for changes](12-caching.md#how-a-file-is-checked-for-changes). |
| `RIGOR_DISABLE_YJIT=1` | Opt out of Rigor's deferred YJIT enablement. Rigor turns YJIT on partway through any long run so short runs never pay the JIT warm-up; this variable leaves it off entirely. Diagnostics and allocations are identical either way — the effect is wall-time only. |
| `RIGOR_YJIT_DEADLINE=<seconds>` | Advanced: tune how long a run must last before deferred YJIT enables (default `5.0`). Lower it if your runs are long and you want the JIT sooner; raise it to protect short runs. Ignored when `RIGOR_DISABLE_YJIT=1` is set or YJIT is unavailable. |

Three further variables (`RIGOR_BUDGET_TRACE`,
`RIGOR_HEAP_PROFILE`, `RIGOR_HEAP_TRACE`) enable developer-facing
diagnostics about Rigor's own inference cutoffs and memory — see
[Troubleshooting § Advanced diagnostics](13-troubleshooting.md#advanced-diagnostics).

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — no error-severity diagnostics. |
| `1` | Diagnostics found, or a per-command failure (parse error, missing file, new diagnostics on `diff`, effect drift on `effects check`). |
| `64` | Usage error — unknown command, bad flag, malformed argument, or a value in `.rigor.yml` the loader cannot proceed on. |

`rigor triage` is the exception: it is advisory and always
exits `0`.

A configuration mistake prints one `rigor:` line naming the key
and nothing else — no backtrace, on every command:

```
$ rigor effects update
rigor: effects.attribution key is not a method key (`Owner#method` / `Owner.method`): "Net::HTTP get"
```
