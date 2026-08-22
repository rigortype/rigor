# Effect system — first-adopter user story on Redmine (2026-08-22)

A walkthrough of the ADR-103 effect system as a competent Ruby/Rails developer who has never seen it, run
against the survey checkout at `rigor-survey/redmine` (Rigor 0.3.4, never added to Redmine's Gemfile).
Only user-reachable material was consulted: `rigor help`, `rigor <cmd> --help`, `docs/manual/`, and the
CLI's own output. `lib/` was not opened to interpret behaviour.

Redmine's checkout already carried a `.rigor.dist.yml` from earlier survey work (config rank 2, so it is
picked up automatically); `.rigor.yml` did not exist. Everything written during the session
(`.rigor.yml`, `.rigor-effects.yml`, `.rigor/cache`, two edited `app/models/*.rb`, a temporary `sig/`)
was removed; `git status --porcelain` in the survey checkout is byte-identical to its pre-session
snapshot, and the rigor tree is clean.

---

## Step 1 — Discovery

```
$ rigor help
  effects    Report each method's effect labels, and the committed effect snapshot
             (ADR-103, opt-in; effects update/check/diff/explain)

$ rigor effects --help
Usage: rigor effects [options] [paths]

With no subcommand, prints one line per method: its proven effect labels and whether that
list is exhaustive.

Subcommands (the committed effect snapshot, ADR-103 WD7):
  update      Write the snapshot to effects.snapshot.path. Commit it; review its diff.
  check       Recompute and compare; exits 1 on drift, 0 when fresh.
  diff        The same comparison, never gating.
  explain     The shortest edge path behind a reach change (--symbol KEY for one unit).

Run `rigor effects <subcommand> --help` for subcommand options.
```

What the adopter can learn: the command exists, it is opt-in, there are four subcommands. What is
missing: **how to opt in** (neither help text names `effects: {}`), **what an effect label is**, and
**what the vocabulary is**.

`rigor effects --help` prints `[options]` and then lists **zero options**, while every subcommand's
`--help` lists five or six. `--full`, `--format`, `--config` and `--no-tolerated-effects` are documented
for the bare verb in chapter 02 and are invisible from the CLI.

Both help strings, and four of the manual passages, cite **ADR-103**. `rigor docs --list` ships
`install`, `manual/*` and `handbook/*` — no ADRs, no `type-specification/`. So:

```
$ rigor docs type-specification/effect-labels
Unknown doc: type-specification/effect-labels
```

Chapter 02 (`the label vocabulary is [the effect-labels specification](../type-specification/effect-labels.md)`)
and chapter 16 (`a comma-separated list of bare [effect labels](../type-specification/effect-labels.md)`)
both point the reader at a file an installed gem does not carry. **There is no user-reachable list of
effect labels anywhere.** The manual's own `README.md` table of contents never mentions effects at all;
grepping the manual, only chapters 02, 03, 04, 08, 12, 15, 16, 17 and three plugin pages contain the
word, and chapter 11 (CI) contains it zero times.

## Step 2 — First run

```
$ rigor effects              # .rigor.dist.yml, no effects: block (implicit empty)
real  0m10.362s
31191 lines on stdout
```

Composition of those 31,191 lines:

| | count | share |
| --- | --- | --- |
| method rows | 4,223 | 13.5% |
| indented unresolved-reason lines | 26,968 | 86.5% |
| rows carrying ` …?` (not exhaustive) | 3,930 | **93.1% of rows** |
| rows that are exhaustive | 293 | 6.9% |
| rows reading exactly `Foo#bar: [] …?` — no proven labels, no declared lane | **1,627** | **38.5% of rows** |
| rows carrying a `≤ [...]` declared lane | 1,320 | 31.3% |

Unresolved-reason histogram over the whole report:

```
15652  unresolved-self-call
 8912  dynamic-receiver
 1340  unknown-ownership
  685  dynamic-send
  249  template-not-analysed
  130  opaque-callable
```

Typical row:

```
AccountController#activation_email: [io.net, mutate.instance, mutate.local, mutate.self, nondet.random] ≤ [global.read, io, io.db.read, io.db.write, mutate, rails.flash.write, rails.i18n.translate, rails.response.write, rails.session.read, rails.session.write] …?
    dynamic-receiver
    dynamic-receiver (external_gem_without_rbs)
    dynamic-receiver (inferred_return_untyped)
    dynamic-receiver (unsupported_syntax)
    dynamic-send
    unknown-ownership
    unresolved-self-call (action)
    unresolved-self-call (headers)
    … 8 more
```

Observations an adopter makes here:

- No header, no footer, no totals, no pager, no `--limit`. 31k lines land in the terminal.
- Rows are sorted alphabetically by key, so "which controllers reach the network" — the question the
  manual says this answers — cannot be asked. There is no `--label`, `--only-exhaustive`, or sort option.
  Path arguments do work (`rigor effects app/models/change.rb` → 3 lines) but nothing signposts them as
  the way to make the report tractable.
- 1,627 rows say literally nothing. The manual's omission rule ("omitted when it is exhaustive and proves
  nothing beyond `mutate.local`") does not cover the far larger "not exhaustive and proves nothing" class.
- **The declared lane has no provenance.** Chapter 02's worked example shows
  `Gateways::Client#fetch: [] ≤ [io.net.http] …?` / `    plugin-attribution (Acme::Http.get)`. In 31,191
  lines of real output the string `plugin-attribution` appears **0 times**, while 1,320 rows carry a `≤`
  clause. Redmine's config has no `effects.attribution:` at all, so every one of those claims came from a
  plugin — and the report never says which plugin, or for which call.
- Chapter 02 describes the declared lane as "today the `effects.attribution:` table you wrote for gem
  methods it cannot see". On a plugin-equipped Rails app that is simply not where it comes from.
- Credibility: `AuthSource#save: [] ≤ [io.db.read]`, and likewise `save!`, `update!`, `decrement!`,
  `touch`. A Rails developer reading "`save` reads the database" and no write will distrust the tool, and
  has no CLI affordance to ask why.

Unrelated but reproduced on every run against this target (stderr, pre-existing):

```
rigor: RBS definition build failed for `Date`: RBS::DuplicatedMethodDefinitionError:
  rbs-4.1.1/stdlib/date/0/date.rbs:1485 ::Date#to_time has duplicated definitions in
  plugins/rigor-activesupport-core-ext/sig/active_support/core_ext.rbs:602
```

`Date` and `DateTime` degrade to `Dynamic[top]` for any project using `rigor-activesupport-core-ext` with
rbs 4.1.1. Not an effects finding, but it silently degrades this survey target and any Rails adopter.

## Step 3 — The snapshot

```
$ rigor effects update
rigor: wrote .rigor-effects.yml (1529 method(s), 0 reach entries)
rigor: note — `effects.snapshot.reach:` is empty, so the snapshot records `methods:` only.
real  0m0.925s
```

File: 5,940 lines, 293,276 bytes.

| | value |
| --- | --- |
| method keys | 1,529 (vs 4,223 rows in the report — different population, unexplained) |
| entries carrying `unresolved:` | 1,082 |
| bytes spent on `unresolved:` arrays | **144,771 of 293,276 = 49.4%** |
| longest single `unresolved:` line | 821 chars |
| `reach:` entries | 0 |

Would I commit it? The `methods:`/`declared:` half, yes — it is the schema.rb analogy the manual claims.
The `unresolved:` half, no: half the bytes are inference-quality metadata that churn on every Rigor
upgrade and on unrelated code changes, on 821-character single lines that no reviewer will read.

The default snapshot has **no `reach:` table at all**, so the pitch — "which controllers reach the
network, which jobs write, which presenters query" — does not happen out of the box. The note says reach
is empty; it does **not** say what to write to fix it.

Also: `config_digest: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"` is the SHA-256
of `{}`, so an implicit block and an explicit `effects: {}` agree — good, no spurious regeneration there.

Same method key, two different answers, no visual cue that they are different questions:

```
report   AccountController#activation_email: [io.net, mutate.instance, mutate.local, mutate.self, nondet.random] ≤ [global.read, io, io.db.read, …]
snapshot AccountController#activation_email:  effects: []   declared: ["io","mutate","mutate.self","rails.response.write","rails.session.read","rails.session.write"]
```

The manual explains transitive-vs-direct in prose; the two surfaces give no signal at the point of use.

### The realistic edit

Added an audit-log write to `Change#init_path` in `app/models/change.rb`:

```rb
  def init_path
    self.path ||= ""
    File.open(Rails.root.join("log", "change_audit.log"), "a") do |f|
      f.puts("#{Time.now.utc.iso8601} #{changeset_id} #{path}")
    end
  end
```

```
$ rigor effects check        # exit 1
Effect drift against .rigor-effects.yml:

methods:
  Change#init_path  + io.fs.write
  Change#init_path  + nondet.time
  Change#init_path  exhaustive → not

Run `rigor effects update` and commit the result if this change is intended.

$ rigor effects diff         # identical text, exit 0
$ rigor effects explain      # exit 0
methods:
  Change#init_path [io.fs.write] ← catalogue:File#puts
  Change#init_path [nondet.time] ← catalogue:Time.now
```

**This is the best part of the product.** Precise, short, attributable, correct exit codes (verified
unpiped: text 1, `--format=json` 1, `--no-tolerated-effects` 1). Residual friction:

- The drift report carries **no `file:line`**. `Change#init_path` sends the reviewer to grep.
- `explain` covers two of the three drift lines. `exhaustive → not` — the one a reader least understands
  — is not explained by any command.
- The failure footer routes only to `rigor effects update`. The manual's narrative has the author run
  `rigor effects explain` first; the CLI never mentions it.
- `rigor effects explain --symbol "Nope#nope"` prints **`Nothing to explain.` and exits 0**. A typo'd
  symbol is indistinguishable from a symbol with no effects.

## Step 4 — Annotations

Wrote rbs-inline annotations into two real Redmine files, per chapter 16 (no plugin needed; `# rbs_inline:
enabled` at the top was enough).

Without an `effects:` block — exactly as documented, and genuinely good:

```
app/models/anonymous_user.rb:31:1: info: Effect annotations (`%a{pure}` / `%a{rigor:v1:effect …}`) are
present in your project's signatures, but `.rigor.yml` carries no `effects:` block, so effect collection
never runs and nothing checks them — they are documentation, not a contract. Add `effects: {}` …
```

With `effects: {}`:

```
app/models/anonymous_user.rb:31:1: info: Effect envelope on AnonymousUser#available_custom_fields names
io.bd.read, which is not a known effect label (did you mean io.db.read?); the annotation now bounds nothing.

app/models/change.rb:34:1: warning: Method Change#init_path performs mutate.self (receiver-mutation),
but is declared %a{pure} at app/models/change.rb:5, so mutate.self exceeds the envelope.
```

`%a{pure}` on `AnonymousUser#logged?` (`def logged?; false end`) — silent. Correct round-trip.

Two hard findings:

1. **`effect.envelope-exceeded` reports a bogus declaration line for rbs-inline annotations.** The
   annotation was on line 33; the message says line 5 — a GPL copyright comment. Adding ten blank lines
   moved the `def` from 34 to 44 and the diagnostic position tracked it, while the declaration site
   **stayed pinned at 5**. Writing the same envelope in `sig/effects_probe.rbs` instead gave the correct
   `declared %a{pure} at sig/effects_probe.rbs:2`. So it is specific to the rbs-inline lane, which
   chapter 16 presents as co-equal.

2. **Effect diagnostics print without their rule ID.** Every message above ends with a full stop; the
   plugin warning on the adjacent line ends with `[plugin.activerecord.load-error]`. My first grep for
   `effect\.` returned nothing and I concluded the feature was broken. Chapter 03's own worked example
   shows `… exceeds the envelope. [effect.envelope-exceeded]`, and chapter 04 tells the reader to
   `disable:` these rules by ID — an ID the CLI never prints.

Lesser: hanging an envelope on one method in `.rbs` forces you to author its whole type signature
(`def init_path: () -> untyped`) just to carry the annotation. The rbs-inline lane does not.

Also worth a manual sentence: `%a{pure}` on `AnonymousUser#name`, whose report row reads
`[] ≤ [global.read, rails.i18n.translate]`, stays **silent** — declared labels never make a diagnostic
fire. Correct per ADR-103 and completely counter-intuitive at the point of use.

## Step 5 — Policy

`effects.tolerated:` typo — good, with a did-you-mean, though positioned at `.rigor.yml:1:1` rather than
at the key:

```
.rigor.yml:1:1: info: `effects.tolerated:` in .rigor.yml names telemtry, which is not a known effect
label (did you mean telemetry?); the entry discharges nothing.
```

`effects.envelopes:` message quality is **excellent** — the best diagnostics in the feature:

```
app/helpers/activities_helper.rb:34:1: warning: Method ActivitiesHelper#activity_authors_options_for_select
performs mutate.self (ivar-write via Query#users → Query#principals), but is declared effect: [] at
.rigor.yml effects.envelopes[0], so mutate.self exceeds the envelope.

app/helpers/avatars_helper.rb:23:1: warning: Method AvatarsHelper#assignee_avatar performs exit
(Kernel#abort via AvatarsHelper#avatar → AvatarsHelper#gravatar_avatar_tag →
GravatarHelper::PublicMethods#gravatar → GravatarHelper::PublicMethods#gravatar_url →
GravatarHelper::PublicMethods#gravatar_api_url → Redmine::Configuration.[] →
Redmine::Configuration.load), but is declared effect: [] at .rigor.yml effects.envelopes[0], so exit
exceeds the envelope.
```

Volume is the problem. One stanza —

```yaml
effects:
  envelopes:
    - match: "app/helpers/**/*.rb"
      effect: []
```

— produces **343 warnings across 18 files**, one per (method, label) pair:

```
 91 mutate.self      86 mutate.static    83 io.fs.read     38 mutate.instance
 16 global.read      13 io.output.stderr 13 exit            3 nondet.time
```

`tolerated: [mutate.self]` correctly discharges per origin: 343 → 252. `--no-tolerated-effects` restores
343. Chapter 03's "the surface that pays on day one" undersells what day one looks like: the first stanza
a reader copies from the chapter lands 343 warnings and no advice on how to work down from there.

Glob semantics are fine — `app/helpers/*.rb` and `app/helpers/**/*.rb` both give 343, so `**/` does match
zero segments and chapter 03's `app/presenters/**/*.rb` example works on a flat directory.

### Two config errors crash with a raw backtrace

Chapter 03's flagship Rails recommendation is `reach: [rails]`. On this project:

```
$ rigor effects update
bundler: failed to load command: exe/rigor
lib/rigor/effects/snapshot.rb:168:in 'block in Rigor::Effects::Snapshot.expand_reach':
  effects.snapshot.reach names no registered entry-point preset: "rails"
  (registered: ["rails-controllers", "rails-mailers"]; a preset is named by the plugin that
  models the framework, so listing that plugin is what registers it)
  (Rigor::Effects::EntryPoints::Error)
    … 30 more frames of Rigor, Bundler, Thor and rubygems internals
```

The sentence inside the exception is good. Everything around it is a 30-frame stack trace naming
`lib/rigor/effects/snapshot.rb`. Same for a malformed attribution key:

```
$ rigor effects update       # effects.attribution: {"Net::HTTP get": [io.net.http]}
lib/rigor/configuration.rb:812:in 'block in Rigor::Configuration#coerce_effects_attribution':
  effects.attribution key is not a method key (`Owner#method` / `Owner.method`): "Net::HTTP get"
  (ArgumentError)
```

Chapter 03 says both are "a load error" / "an error when the snapshot is built" — true, but they are
delivered as uncaught Ruby exceptions, not as `rigor:` messages.

Related doc bug: chapter 03 writes `` `rails` — registered by [`rigor-railties`](plugins/rigor-rails.md) ``.
`rigor plugin list` confirms `rigor-railties` and `rigor-rails` are two different plugins, and the manual
page for `rigor-railties` is filed as `manual/plugins/rigor-rails.md`. The link is right and the reader
will conclude the plugin is called `rigor-rails`.

`reach: [rails-controllers]` works: **482 reach entries**.

### Regeneration events bury their own explanation

Snapshot written with `reach: [rails-controllers]`, then judged with `effects: {}`:

```
Effect drift against .rigor-effects.yml:

regeneration:
  config_digest: "99e03992…" → "44136fa3…"

reach:
  AccountController#account_locked  -symbol [] …?
  AccountController#account_pending  -symbol [] …?
  … 480 more
```

The tool knows it is a regeneration event, prints the one line that explains everything, and then prints
482 `-symbol` lines anyway.

## Step 6 — The CI story, and the bug that breaks it

**Chapter 11 (`Running Rigor in CI`) does not contain the word "effect".** None of the four
`docs/manual/ci-templates/*.yml` contains it. There is no template, no snippet, no cache-key guidance.
The only CI instruction in the whole manual is one sentence in chapter 02: "Add `rigor effects check` to
CI."

That would be a documentation gap. What makes it a product bug is chapter 11 § *Persisting the analysis
cache across runs* — the recommended CI setup — combined with this:

```
$ rm -rf .rigor/cache
STEP1 cold, effects:{} only  -> 0 envelope diagnostics
   (add effects.envelopes: app/helpers/**/*.rb, effect: [])
STEP2 warm, envelopes ADDED  -> 0     ← 0.48s, cache hit
$ rm -rf .rigor/cache
STEP3 cold, same config      -> 343   ← 9.9s
STEP4 warm again             -> 0     ← same config that just produced 343
```

Non-envelope diagnostics round-trip correctly (5 cold, 5 warm). **`effect.envelope-exceeded` is produced
only on a cold run and is silently dropped by every cache hit thereafter.** `touch`ing a helper does not
bring it back; only a genuine content change re-emits it for that file.

Consequences:

- A user who writes a policy stanza, runs `rigor check`, and sees nothing concludes their layer is clean.
  That is a silent false negative in the exact scenario the feature exists for.
- In CI with a persisted cache — which chapter 11 tells you to set up — the envelope half of the feature
  never fires at all.
- Chapter 12 (Caching) does not mention effects anywhere, so nothing warns the reader.

The snapshot half is unaffected: `rigor effects check` detected the `Change#init_path` drift correctly on
a warm cache in 0.9s. The two halves of the feature have opposite cache behaviour, and nothing says so.

---

## Ranked friction list

### The product must change

1. **`effect.envelope-exceeded` vanishes on a warm cache — 343 → 0 with identical config.** The
   diagnostic half of the feature is inert on every run after the first, and inert in CI with the
   persisted cache chapter 11 recommends; a user reads the silence as "my layer is clean". *Smallest fix:*
   restore envelope judgments from the cached effect summaries on a cache hit, exactly as `rigor effects
   check` already does; failing that, make an `effects.envelopes:` change invalidate the diagnostics cache
   and document that warm runs cannot carry envelope findings.

2. **There is no user-reachable list of effect labels.** Chapters 02 and 16 both link
   `../type-specification/effect-labels.md`; `rigor docs` ships no `type-specification/` and no ADRs, so
   nobody can find out what `io.fs.read`, `nondet.time`, `mutate.static` or `exit` mean, or what the full
   set is — while `envelopes:`, `tolerated:`, `attribution:` and `labels:` all require you to type one.
   *Smallest fix:* `rigor effects --list-labels` (or `rigor explain effect.*`), plus a vocabulary table in
   the new manual chapter.

3. **Effect diagnostics print without their rule ID.** `[effect.envelope-exceeded]` /
   `[effect.unknown-label]` / `[effect.annotations-unchecked]` never appear, while neighbouring plugin
   warnings carry theirs. You cannot grep for them, and chapters 03 and 04 both show or instruct the ID.
   *Smallest fix:* emit the ID suffix like every other rule.

4. **`effect.envelope-exceeded` points at the wrong line for rbs-inline annotations** — "declared
   `%a{pure}` at app/models/change.rb:5" for an annotation on line 33 (line 5 is a copyright comment).
   The `.rbs` lane is correct. *Smallest fix:* carry the rbs-inline comment's own source position into
   the declaration reference.

5. **Two config mistakes crash with a 30-frame Ruby backtrace** — `reach:` naming an unregistered preset
   (which is chapter 03's flagship `reach: [rails]`) and a malformed `effects.attribution:` key. The
   message inside the exception is good. *Smallest fix:* rescue both into a one-line `rigor:` error with
   a non-zero exit.

6. **`rigor effects` prints 31,191 unpaged lines on a mid-size Rails app, 86.5% of it unresolved-reason
   noise and 38.5% of the rows content-free (`Foo#bar: [] …?`).** There is no summary, no `--limit`, no
   filter, no ordering but alphabetical. *Smallest fix:* suppress the no-proven-no-declared rows behind
   `--full`, collapse the reason block to a count with `--why` to expand, and print a footer with the
   totals.

7. **The declared lane has no provenance on a real project.** 1,320 rows carry `≤ [...]`; the string
   `plugin-attribution` appears zero times. The reader cannot tell which plugin claimed what, and chapter
   02's example promises they can. *Smallest fix:* emit the `plugin-attribution (Owner#method)` reason
   line the manual already documents.

8. **`rigor effects update` with the default config writes a snapshot with zero `reach:` entries** — the
   headline benefit does not happen out of the box — and the note that says so does not say what to
   write. *Smallest fix:* have the note name `effects.snapshot.reach:` and the presets actually
   registered in this project (the crash in item 5 already knows how to list them).

9. **Half the snapshot's bytes are `unresolved:` arrays** (144,771 of 293,276), on lines up to 821
   characters. It is the half a reviewer cannot read and the half that churns on unrelated changes.
   *Smallest fix:* record a stable count/summary rather than the full origin list, or move it behind
   `--full`.

10. **A regeneration event still prints the full diff** — one `config_digest:` line followed by 482
    `-symbol` lines. *Smallest fix:* when the digest moved, print the regeneration line, the counts, and
    stop.

11. **`rigor effects --help` lists no options** while every subcommand lists five or six. *Smallest fix:*
    list `--full`, `--format`, `--config`.

12. **`rigor effects explain --symbol <typo>` prints `Nothing to explain.` and exits 0.** *Smallest fix:*
    distinguish "no such symbol" (exit non-zero) from "no effects".

13. **The drift report carries no `file:line`,** and `explain` covers the label lines but never
    `exhaustive → not`. *Smallest fix:* add the definition site to each drift row; teach `explain` to name
    the call that lost exhaustiveness.

14. **The `check` failure footer routes only to `rigor effects update`,** never to `rigor effects
    explain`, which is the command the manual's own narrative reaches for first.

15. **`rigor help` and both help strings cite ADR-103 as the only pointer** to a document no installed
    gem carries. Cite the manual chapter instead.

16. *(Not effects, reproduced on every run)* `rigor-activesupport-core-ext` collides with rbs 4.1.1's
    `stdlib/date` on `::Date#to_time`, degrading `Date` and `DateTime` to `Dynamic[top]` for every Rails
    adopter using that plugin.

### The manual must explain this

1. **There is no effects chapter, and the manual README's table of contents never mentions effects.** A
   feature with four subcommands, four diagnostics, seven config keys and two annotation forms is
   discoverable only by already knowing to grep chapters 02, 03 and 16.

2. **Chapter 11 (CI) contains the word "effect" zero times, and none of the four CI templates does.** The
   whole CI story is one sentence in chapter 02. There must be a `rigor effects check` step, a statement
   about which cache is safe to persist, and the `--baseline <(git show origin/main:.rigor-effects.yml)`
   trick promoted out of a parenthesis.

3. **Direct vs transitive is the single hardest idea and it is explained once, in prose, far from where
   it bites.** The same method key prints five labels in the report and none in the snapshot; the reader
   needs that contrast shown side by side, with both outputs, before either surface.

4. **`…?` on 93.1% of rows needs to be the chapter's opening expectation, not a footnote.** "These
   effects, and possibly more" is the normal state of a Rails app; a reader who expects exhaustiveness
   will conclude the tool does not work.

5. **The declared lane needs its own section.** That a method visibly carrying
   `≤ [global.read, rails.i18n.translate]` passes a `%a{pure}` bound in silence is correct, surprising,
   and undocumented at the point of use.

6. **Chapter 03 undersells day one with `envelopes:`.** "The surface that pays on day one" produced 343
   warnings from one stanza. The chapter needs the real number, and the working-down recipe:
   `rigor effects <that path>` first, then `tolerated:`, then narrow the stanza.

7. **Chapter 03's `rigor-railties` link points at `plugins/rigor-rails.md`.** Two different plugins; the
   reader will list the wrong one and get item 5's backtrace.

8. **Chapter 02 attributes the declared lane to "the `effects.attribution:` table you wrote".** On a
   plugin-equipped Rails app it is entirely plugin-sourced. Contradicted by the CLI.

9. **Chapter 03's worked envelope output ends with `[effect.envelope-exceeded]`; the CLI prints no ID,
   and chapter 03's example path is relative while a full-project run prints absolute paths.** Two
   verbatim-output mismatches in one code block.

10. **Nothing tells you how to find your already-pure methods.** Both the report and the snapshot omit
    exactly the methods worth annotating `%a{pure}`; `--full` surfaces 460 of them
    (`AnonymousUser#logged?`, `ApplicationController#api_request?`, …) and nothing says so.

11. **Nothing tells you that annotating one method in `.rbs` forces you to author its signature,** while
    the rbs-inline form does not.

12. **Chapter 12 (Caching) never mentions effects,** so nothing warns that the two halves of the feature
    behave oppositely under a warm cache.

---

## What the manual chapter should tell me, in the order I needed it

1. **What an effect label is, and the whole vocabulary, in a table.** Roots (`io`, `mutate`, `nondet`,
   `global`, `exit`, `telemetry`, plus plugin roots like `rails.*`), what "`io.db.read` on `save`" means,
   and that `mutate.local` is free everywhere. Nothing else in this chapter can be read without it.
2. **How to turn it on, in one line**: `effects: {}` in `.rigor.yml`, and that nothing else does — not an
   annotation, not a CLI flag. Say that `rigor effects` alone runs without it.
3. **The first run, honestly.** Show the real Redmine numbers: 4,223 rows, 93% hedged, 31k lines. Then
   immediately show the two ways to make it usable — a path argument, and reading only rows with labels.
4. **What a row means, field by field**, in this order: the key, the proven list, ` …?` and why it is
   normal, the `≤` declared lane and where it comes from, then the indented reasons.
5. **Direct vs transitive, side by side**, one method printed by `rigor effects` and by the snapshot.
6. **The snapshot.** `update`, what to commit, what the diff looks like, what `unresolved:` is and that
   you should not read it. Then `reach:` — including that the default records none, and how to pick the
   preset your plugins actually registered.
7. **The review loop as a worked example**: an edit, `check`'s output, `explain`'s output, `update`,
   commit. This is the strongest material in the feature and belongs early enough to sell it.
8. **CI**: the `effects check` step, the `--baseline <(git show origin/main:…)` bot pattern, exit codes,
   and which caches are safe to persist.
9. **Envelopes and annotations**, last, because they are the part that costs real effort:
   `effects.envelopes:` first (no RBS needed, but say it lands hundreds of warnings on a real app and how
   to work down), then `%a{pure}` / `%a{rigor:v1:effect …}`, then `tolerated:` and its per-origin rule,
   then `attribution:` for gems.
10. **A diagnostics section** naming all four rules with their IDs, so `disable:` and `severity_overrides:`
    are usable.
