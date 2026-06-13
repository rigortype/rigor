# 03 — Triage, baseline, and surfacing real bugs

Covers **Phase 6** (triage), **Phase 7** (baseline — acknowledge mode
only), and **Phase 8** (real bugs + escalation).

## Phase 6 — Triage the diagnostic stream

Do **not** read the raw `rigor check` output to decide what to do. A
mature codebase's raw stream is hundreds of lines and reads as
hundreds of unrelated problems — it is the wrong first artefact. Run
the triage command instead:

```sh
rigor triage --format json
```

`rigor triage` runs the same analysis as `rigor check`, then returns
a structured summary instead of the per-line dump. It is read-only
and advisory — it never edits config and never writes a baseline.
The JSON shape:

```json
{
  "summary":      { "total": 489, "error": 480, "warning": 9, "info": 0 },
  "distribution": [ { "rule": "call.undefined-method", "count": 437 } ],
  "selectors":    [ { "receiver": "String", "method": "squish", "count": 31,
                      "files": 12, "rules": { "call.undefined-method": 31 } } ],
  "hotspots":     [ { "file": "app/models/status.rb", "count": 42,
                      "by_rule": { "call.undefined-method": 40 } } ],
  "hints": [
    { "id": "activesupport-core-ext", "confidence": "likely",
      "diagnostic_count": 365, "summary": "...", "action": "..." }
  ]
}
```

Use the sections like this:

- **`summary` / `distribution`** — the scale, and which rules
  dominate. Decides nothing on its own; feeds the mode sanity-check
  (>100 errors → acknowledge mode is the right default).
- **`selectors`** — the by-(class, method) axis. Each row is a
  dispatch target (`String#squish`) with its `count`, the `files` it
  spans, and the `rules` that fired. Read it with `jq` to find the
  *shape* of the problem before touching code — these are structured
  fields, never parse the `message`:
  ```sh
  # the 10 methods responsible for the most diagnostics
  rigor triage --format json | jq -r '.selectors[:10][] | "\(.count)\t\(.receiver)#\(.method)"'
  # methods missing on the same receiver across many files = one config
  # gap (an unloaded core-ext / unseen monkey-patch), not many bugs
  rigor triage --format json | jq '.selectors[] | select(.files >= 5)'
  ```
  A high `count` + high `files` selector is almost always a *systemic
  cause* (a plugin / `pre_eval:` fix clears it in bulk); a low `count`
  selector is a candidate genuine bug.
- **`hotspots`** — files carrying the most diagnostics. A single hot
  file is often one structural cause, not many bugs.
- **`hints`** — the heuristic catalogue. Each hint names a *likely
  cause* and a *suggested action*. They are signal, not verdicts —
  the `confidence` field is `likely` or `possible`; verify before
  acting.

### Hint catalogue → what to do

| Hint `id` | Cause | Where this skill handles it |
| --- | --- | --- |
| `activesupport-core-ext` | ActiveSupport core-class monkey-patches not loaded. | Go back to Phase 3/4: add `rigor-activesupport-core-ext` to `plugins:` (it is an RBS-bundle plugin), re-run triage. This is a config gap, not a bug. |
| `gem-without-rbs` | A dependency ships no RBS. | If `rbs_collection.lock.yaml` was present and Phase 1 installed the collection, re-run `rigor triage` — the hint may shrink or disappear. Otherwise: Phase 8 escalation — `bundle exec rbs collection install`, or `dependencies.source_inference:`, or open a Rigor issue. |
| `project-monkey-patch-known` | **High confidence.** The engine proved the called method *is* defined by a project file (a reopened core/stdlib/gem class) but is not applied cross-file. The hint **names the defining file(s)**. | Phase 7 escalation — copy the named file(s) straight into `pre_eval:`. No detective work needed; the diagnostic already found the source. |
| `project-monkey-patch` | An in-project monkey-patch / refinement Rigor did not see, inferred from the *spread* of the same method across ≥3 files (no proven def site). | Phase 7 escalation — find the defining file (grep for `def <method>` / `class <Receiver>`), register it via `pre_eval:`, or (if it is a DSL) write a project plugin. |
| `unresolved-toplevel` | Toplevel calls (outside any `def`/`class`/`module`) that resolve to nothing visible — usually a script relying on a monkey-patch or a `require`d helper Rigor did not walk (ADR-34). | Phase 7 escalation — if a project file defines these (toplevel `def`, or a patch on `Object`/`Kernel`), list it in `pre_eval:`. If nothing defines them, treat as genuine typos / missing requires (Phase 8). |
| `activerecord-relation-misinference` | An ActiveRecord relation inferred as `Array`. | Ensure `rigor-activerecord` is enabled (Phase 3). If it persists, it is an engine gap — open a Rigor issue. |
| `systemic-file-cluster` | One file × one rule, large count. | Acknowledge mode: a clean baseline bucket. Strict mode: a single fix may clear many — review that file first. |
| `genuine-bugs` | Low-count rules scattered across files. | **Phase 7** — these are the localised bugs Rigor caught. Review first, in both modes. Note: the hint groups all low-count rules regardless of severity — filter for `error` severity when prioritising actionable items. |

If triage flags `activesupport-core-ext` (or any config gap),
**fix the config and re-run `rigor triage` before continuing**. The
baseline and the real-bug review should both run against the
post-config diagnostic set, not the inflated one.

## Phase 6a — Pre-baseline cleanup

Before generating the baseline, **apply every quick fix that triage
has already diagnosed**. A smaller baseline is a better baseline: each
bucket it omits is a regression that will surface the moment it
appears, rather than hiding behind a ceiling that the monkey-patch
noise inflated.

Quick fixes that belong here (apply now, not as post-baseline
escalation):

### `project-monkey-patch` / `project-monkey-patch-known` → `pre_eval:`

When triage reports either hint, act before Phase 7:

1. **`project-monkey-patch-known`** — the hint's action line **names
   the defining file(s)**. Copy them straight into `pre_eval:` in
   `.rigor.dist.yml`:

   ```yaml
   pre_eval:
     - lib/core_ext/user_extensions.rb   # exact path(s) named by the hint
   ```

2. **`project-monkey-patch`** (spread-based, no proven def site) —
   find the defining file manually:

   ```sh
   # Replace `current` / `User` with the method and receiver named in the hint
   grep -rn "def self\.current\|cattr_accessor.*current" app/ lib/
   grep -rn "def deliver_\|def find_by_" app/ lib/
   ```

   Then add the file(s) to `pre_eval:`.

After adding `pre_eval:` entries, **re-run `rigor triage`** and note
the new total. If the count dropped by more than ~50 diagnostics,
the reduction is significant enough to justify this round; proceed
with the new, smaller count.

Repeat the loop (find → `pre_eval:` → re-triage) until the hint
disappears or the remaining count is stable. Then move to Phase 7.

> **If a cluster does NOT drop after you add its file to `pre_eval:`**,
> the methods are almost certainly **generated dynamically**
> (`define_method` with a computed name, `method_missing`, or a
> `class_eval` heredoc) — the pre-eval walker found no literal `def` to
> register. That is not a `pre_eval:` failure to retry; it is the signal
> that the durable fix is a **project-owned plugin**. Leave the file in
> `pre_eval:` only if it also defines literal methods; otherwise remove
> it and carry the cluster to Phase 8 § "Escalation path A", which
> hands off to the `rigor-plugin-author` skill.

> **Why `pre_eval:` reduces the count.** `pre_eval:` files are walked
> before per-file inference. Methods defined in them — including those
> added to existing classes via `class Foo; def bar; end; end` — become
> visible to every subsequent file analysis. The monkey-patched methods
> are no longer unknown, so `call.undefined-method` diagnostics that
> depended on them disappear.

### `gem-without-rbs` (if rbs collection was not yet installed)

If Phase 1 did not install the collection (project had no
`rbs_collection.lock.yaml`) and triage now reports `gem-without-rbs`,
this is the right moment to act before the baseline:

```sh
bundle exec rbs collection install   # if rbs is in Gemfile
# or: rbs collection install
```

Re-run `rigor triage`. If the `gem-without-rbs` count drops,
re-generate the baseline against the new number.

## Phase 7 — Generate the baseline (acknowledge mode only)

**Strict mode skips this phase entirely.** A strict project has no
baseline; every diagnostic stays live.

In acknowledge mode, snapshot today's diagnostics:

```sh
rigor baseline generate
```

This writes `.rigor-baseline.yml` at the project root — one
`(file, rule, count)` bucket per cluster. The command refuses to
overwrite an existing baseline without `--force`.

Then **wire it into the config**. Per Rigor's no-magic rule, the
baseline file does nothing until `.rigor.dist.yml` names it. Add (or
uncomment) the line written in Phase 4:

```yaml
baseline: .rigor-baseline.yml
```

`rigor baseline generate` prints a note reminding you of this if the
config does not yet declare `baseline:`. Do both edits — generate and
wire — in one step so the user never has a generated baseline that
silently does nothing.

How the baseline behaves afterwards (acknowledge mode's whole point):

- A `(file, rule)` bucket is silenced while its live count stays at
  or below the recorded number.
- If a commit pushes a bucket *over* its recorded count, **every**
  diagnostic in that bucket surfaces — the bucket is now a regression
  to review.
- New `(file, rule)` pairs that were not in the baseline surface
  immediately.

So ordinary coding cannot quietly grow the diagnostic count: the
baseline is a ceiling, not a blanket. Reducing it later is the
`rigor-baseline-reduce` skill's job.

Commit `.rigor-baseline.yml` — it documents project state.

Print the suppression summary for the user: "N diagnostics recorded
as baseline; M will surface on subsequent runs."

## Phase 8 — Surface real bugs & offer escalation

The triage `genuine-bugs` hint (and any low-count, scattered rule in
`distribution`) points at the diagnostics most likely to be **actual
bugs** — a `nil`-receiver crash on a rarely-exercised line, a typo'd
method. In **both modes**, surface 2–3 of these to the user and offer
to walk them: a small, scattered rule is rarely systemic.

In acknowledge mode these still went into the baseline — that is
fine; the baseline is a starting envelope, not a verdict that the
bug is acceptable. Recommend the user run the `rigor-baseline-reduce`
skill next to work them down.

### Distinguishing sig quality false positives from real bugs

Some diagnostics in the `call.wrong-arity` and
`def.return-type-mismatch` families are caused by **incomplete or
incorrect `sig/` declarations**, not by real bugs in the project code.
Identify them before presenting findings to the user — a sig FP looks
alarming but needs a sig fix, not a code fix.

#### `call.wrong-arity` on `Struct.new(...)` subclasses

When a project defines a class as:

```ruby
MyStruct = Struct.new(:foo, :bar, :baz)
# or
class MyRecord < Struct.new(:id, :name)
```

and its `sig/` entry is an empty shell:

```rbs
class MyRecord
end
```

Rigor reads the empty sig and infers `initialize` takes 0 arguments
(the default). Any `MyRecord.new(x, y)` call then fires
`call.wrong-arity`. This is a **sig quality issue** — the sig is
missing the generated `initialize`.

To confirm: check the sig file for the class. If the sig has no
`initialize` def AND the Ruby source inherits from `Struct.new(...)`,
the diagnostic is a FP. Note it as a sig improvement task (add
`initialize` matching the Struct fields) rather than a code bug.

#### `def.return-type-mismatch` when the declared type is `bot`

A sig that declares `-> bot` (or `-> void` for a `raises`-only
method) says: "this method never returns normally". If Rigor infers
an actual return value, it fires `def.return-type-mismatch`.

Two interpretations:

| Sig says `-> bot` and … | Interpretation |
| --- | --- |
| the implementation has a missing `raise` on one branch | **Likely real bug** — the method was *intended* to always raise, but a code path escapes. High priority: review the branch. |
| the sig was written conservatively (e.g. auto-generated) and the method does sometimes return | **Sig quality issue** — the sig is too strict. Fix by loosening the return type in the sig. |

To distinguish: read the method body. If every branch ends in `raise`
or `exit` except one, the missing raise is likely a bug. If the
method has intentional return values but the sig says `bot`, it is a
sig issue.

#### `call.argument-type-mismatch` on regex capture variables (`$1`, `$~`)

Rigor infers `$1`, `$~`, and similar capture variables as
`String | nil` everywhere, even inside `gsub`/`match` blocks where
they are guaranteed non-nil by the match condition. Diagnostics of
the form:

```
expected String, got String | nil   (on $1 / $~)
```

are **engine FPs** (ADR-24 WD3 / known limitation). Note them as
noise rather than surfacing them as bugs. They belong in the
baseline.

### Escalation path A — application-specific metaprogramming

If triage reports `project-monkey-patch-known`, `project-monkey-patch`,
`unresolved-toplevel`, or a `call.undefined-method` cluster lands on
the project's own DSL / `define_method` factory / in-house macro,
Rigor cannot follow it by default.

**The decision that picks the fix is static-vs-dynamic.** Find the
defining file (named by the hint, or `grep -rn 'def <method>\|<Receiver>'
app/ lib/`) and look at *how* the method is defined:

| How the method is defined | Fix | Why |
| --- | --- | --- |
| **Literal `def foo` / `def self.foo`** in a project file (a plain reopen / monkey-patch, e.g. `lib/core_ext/string_extensions.rb`, `User.current`) | **`pre_eval:`** — copy the file into `pre_eval:` in `.rigor.dist.yml`. | Rigor walks `pre_eval:` files before per-file inference, so the literal method becomes visible everywhere. This is Phase 6a; do it now. |
| **Dynamically generated** — computed-name `define_method`, `method_missing`, or a `class_eval <<~RUBY … def #{name} … RUBY` heredoc template | **A project-owned Rigor plugin** (escalation, below). `pre_eval:` will *not* help. | The pre-eval walker finds no literal `def` to register, so the cluster survives `pre_eval:`. If you added the file to `pre_eval:` and re-triage shows the cluster unchanged, this is the case you are in. |

So the routine is: try `pre_eval:` for the static case in Phase 6a; if a
cluster **survives** because the methods are generated, that surviving
residue is the plugin signal.

#### The plugin handoff (the recommended next step)

A genuine generated DSL is **the project's own plugin to own** — Rigor
does not bundle per-application plugins for it. The textbook example is
Redmine's settings accessors:

```ruby
# app/models/setting.rb — generated, NOT a literal def
def self.define_setting(name, options = {})
  # class_eval a heredoc that defines  self.#{name} / #{name}? / #{name}=
end
# names come from config/settings.yml, iterated — not source literals
```

`Setting.app_title`, `Setting.default_language`, … are never written as
literal `def`s, so `pre_eval:` cannot see them; the durable fix is a
project plugin (it matches ADR-16's Tier C heredoc-template shape).
Rigor's stance: application-specific homegrown DSLs are out of scope for
the bundled substrate (ADR-16 § Audience) — the app authors the plugin
in their own repo.

> **Sizing the cluster — `rigor triage` may not isolate it.** Triage's
> `project-monkey-patch` hint groups by method spread and often lumps a
> generated-DSL cluster in with unrelated patches (or buries it), so the
> hint count is not the per-receiver size. To measure the actual cluster,
> drop to the raw stream and count by receiver:
>
> ```sh
> rigor check --format json | \
>   ruby -rjson -e 'd=JSON.parse(File.read(0, encoding: "UTF-8").scrub); \
>     puts d["diagnostics"].count { |x| x["message"].to_s.include?("for singleton(Setting)") }'
> # or quick-and-dirty: rigor check 2>&1 | grep -c "for singleton(Setting)"
> ```
>
> (Force UTF-8 + `.scrub` — diagnostic messages can carry non-ASCII from
> the project's own strings, e.g. i18n content.) Swap `Setting` for the
> receiver the def-site grep identified.

When you reach this point:

1. **Name the cluster and its generator** for the user — the count, the
   receiver, and the defining method (e.g. *"~60 `call.undefined-method`
   on `Setting.<name>`, generated by `Setting.define_setting`"*). Use the
   raw-JSON count above, not the triage hint number.
2. Say plainly that the durable fix is a **project-owned plugin**, not a
   baseline entry — the baseline only parenthesises the noise; the
   plugin removes it and types the synthetic methods.
3. **Offer to launch the `rigor-plugin-author` skill**, and on the
   user's confirmation, invoke it (Skill tool, `rigor-plugin-author`).
   That skill scaffolds a standalone `rigor-<id>` gem or a
   project-private plugin (loadable from the project's own `lib/`
   without a gemspec) in the *user's* repo.

The offer is not mandatory — acknowledge mode may baseline the cluster
for now and author the plugin later. But make the next step explicit:
never leave a generated-DSL cluster in the baseline without telling the
user it has a real fix and what skill builds it.

### Escalation path B — an unsupported external gem

If triage reports `gem-without-rbs`, a dependency ships no type
information and Rigor has no built-in coverage. In order:

1. `bundle exec rbs collection install` (bare `rbs collection install`
   if `rbs` is not in the project's Gemfile) — pulls community RBS for
   the gem if it exists. Re-run triage afterwards.
2. `dependencies.source_inference:` in `.rigor.dist.yml` — opt the
   gem into Rigor inferring `Dynamic`-typed returns from its source.
3. If the gem is widely used and genuinely warrants first-class
   support, **open an issue on the Rigor project** so the maintainers
   can ship a plugin or RBS bundle:
   <https://github.com/rigortype/rigor/issues>. Include the gem name,
   version, and a sample of the diagnostics.

Neither escalation is mandatory — offer them when triage points at
the cause; the user decides whether to act now or defer.

## Output of this module — onboarding complete

- A committed `.rigor.dist.yml`.
- Acknowledge mode: a committed `.rigor-baseline.yml` + an active
  `baseline:` line. Strict mode: neither.
- The user has seen the likely real bugs and knows the two escalation
  paths.
- If a **dynamically-generated project DSL** was found, the user has
  been told it needs a project-owned plugin and offered the
  `rigor-plugin-author` handoff (path A) — not left silently in the
  baseline.

Next sessions, by what the onboarding surfaced:

- **`rigor-plugin-author`** — when a generated project DSL survived
  `pre_eval:` (escalation path A). This is the durable fix for the
  cluster and the most impactful follow-up; offer it as the next step
  before the user reaches for the baseline-reduce loop.
- **`rigor-baseline-reduce`** — acknowledge mode, to work the recorded
  baseline down.
