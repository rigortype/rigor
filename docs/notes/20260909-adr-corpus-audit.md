# ADR corpus audit — buried work, implementation drift, and obsolescence

Status: **working note, no design commitments.** A point-in-time audit of all 111 ADRs
(ADR-0 … ADR-110) taken 2026-09-09 against `master` (`4d5738c1`), Rigor v0.3.8. Three axes:
**work that was decided and then buried with no issue**, **records that no longer match the
implementation**, and **decisions that reality has overtaken**. This note reports; the spec and the
ADRs bind, not the note. Verify any named file / method / flag still exists before acting on it.

## Method

A 550-agent fleet, in four passes:

1. **Per-ADR audit** — 37 agents, three ADRs each. Each read the ADR end to end, read its
   `docs/adr/README.md` index row, enumerated every deferred / queued / demand-gated item,
   checked each against a local dump of **all 372 GitHub issues (open and closed, with bodies)**,
   then took the ADR's own code anchors — class names, methods, CLI flags, config keys, diagnostic
   ids, plugin hooks — and checked each still resolves in `lib/ plugins/ examples/ exe/ spec/ sig/
   schemas/`.
2. **Adversarial verification** — every finding faced two independent refuters with different
   lenses: *"it is already covered"* (find the issue, the CHANGELOG line, or the code that makes it
   moot) and *"the auditor misread it"* (re-read the passage in context; a deliberate rejection is
   not untracked work). Both defaulted to refuting. 7 findings were killed, 6 survived weakened,
   59 came back with a correction that was folded in.
3. **Seven corpus-level lenses** — unmarked supersession; the ten `Proposed` ADRs; anchor rot
   (17,895 backticked spans extracted and existence-checked); ADR-vs-normative-spec conflict; the
   foundation stratum (ADR-0…13); an exhaustive deferred-item census (721 raw lines → ~177 distinct
   items, each classified tracked / shipped / decided-against / **untracked**); release-roadmap
   coherence.
4. **Completeness critic + a targeted gap round** — the critic found the sweep had converged on
   documentary state and named four unopened surfaces (`plugins/`, the CLI verb surface, both skill
   trees, `docs/notes/`). The gap round opened them and returned 57 more findings, including most of
   the live defects in § 0.

**Prior art honoured.** `docs/notes/20260711-docs-audit-adr-0-41.md` and `…-adr-42-82.md`
(2026-07-11) were read by every auditor in range. All seven drifts their tables recorded have since
been fixed and none is re-reported here. Their lens was status-accuracy across three sources; note
that one of those three, the `CLAUDE.md` ADR bullet list, no longer exists (ADR-97 compressed it),
so the corpus now runs on **two** status sources — a fact that turns out to be the structural cause
of a large share of what follows (§ 4).

**Confidence.** 280 findings survived verification, deduplicated to **237 distinct items**; 30 were
reported independently by two or more agents. Everything in § 0 was additionally re-verified by hand
before being written down. The rest carries the fleet's own citations; treat a `low` item as a
lead, not a fact.

## Headline

| | count |
| --- | --- |
| ADRs audited | 111 |
| ADRs with at least one surviving finding | 93 |
| ADRs clean on every axis run against them | 18 |
| Distinct findings | 237 (high 47 · medium 128 · low 62) |
| — untracked work | 35 |
| — drift | 174 |
| — obsolescence | 28 |

Clean on every axis run against them: ADR-28, 40, 43, 49, 53, 54, 61, 65, 76, 78, 80, 83, 89, 91,
95, 101, 104, 106. (The critic's caveat applies: several carry deferred-intent vocabulary that only a
narrower lens cleared — ADR-43:203-207 defers per-plugin RBS "if sig-gen coverage lands", and
sig-gen's five slices have all shipped, so that trigger has fired inside an ADR marked clean.)

Two shape facts matter more than the totals.

**The corpus does not over-claim; it under-claims.** Almost no ADR announces a feature that was
never built. The dominant failure is the reverse: **work shipped and the record never advanced**.
`ADR-102` says *"Nothing implemented"* about `rigor unused`, which shipped in v0.3.4 and has had
eight follow-up fixes. `ADR-103`'s index row says *"nothing implemented; four items open"* about the
effect system — the v0.3.4 headline, the single most-cited ADR in the normative spec corpus (42
references), with an Accepted ADR-104 built on top of it. Both are still `Proposed`. **The
`Proposed` stratum can no longer be read as "the unbuilt set", which is precisely what makes buried
work hard to see.**

**The `Status:` header and the README row are two ungated sources.** `spec/docs/agent_index_spec.rb`
gates the README row's length, ordering, contiguity and opening status word — and never compares it
to the ADR file's own header. Nothing in `spec/` parses an ADR's `Status:` line at all; an ADR could
lose it entirely and stay green. That is one cheap gate away from being fixed (§ 4).

## 0. Live defects surfaced as a by-product

These are not documentation problems. Each was found by checking an ADR's claim against the code and
finding the code wrong; each was re-verified by hand for this note.

**`rigor playground` drops its first argument, and a bare invocation passes `nil`.**
`lib/rigor/cli.rb:72` shifts the verb off `@argv` before dispatch, so every handler reads `@argv`
directly — except `run_playground`, which is the only one in the file that does
`PlaygroundCommand.new(@argv[1..], …)` (`lib/rigor/cli.rb:323`). `rigor playground --port=4000`
therefore passes `[]`; bare `rigor playground` passes `nil`. Verified: `rg -n '@argv\[1\.\.\]'
lib/rigor/cli.rb` returns exactly that one line. (Reachable only with the `rigor-playground` gem
installed, which is why no spec caught it.)

**`rigor help` documents 23 of the 25 dispatchable verbs.** `baseline` (ADR-22) and `unused`
(ADR-102) are in `HANDLERS` (`lib/rigor/cli.rb:45`, `:50`) and absent from the help text
(`lib/rigor/cli.rb`, `def help`). Two shipped, documented, manual-carrying commands are invisible to
`rigor help`, and no gate compares the two lists.

**`plugins/rigor-rbnacl`'s bundled RBS is never loaded.** Nine bundled plugins ship a `sig/`
directory; eight declare `signature_paths:` in their manifest. `rigor-rbnacl` does not
(`plugins/rigor-rbnacl/lib/rigor/plugin/rbnacl.rb:9-13` — `id`, `version`, `description` only),
so `sig/rbnacl.rbs` is dead weight while its README advertises it. ADR-25 makes `signature_paths:`
the only channel; there is no auto-discovery (`Registry#signature_paths` is
`plugins.flat_map(&:signature_paths)`, `lib/rigor/plugin/registry.rb:358`).

**The `.rigor.yml` key `plugins_isolation:` does not exist.** ADR-39 (`:208`, `:363`), the
**normative** `docs/internal-spec/plugin.md:549`, `docs/CHANGELOG-0.1.x.md:206`, the shipped
`skills/rigor-plugin-author` reference, and a code comment (`lib/rigor/plugin/isolation.rb:10`) all
say the launcher maps a `.rigor.yml` `plugins_isolation:` key onto the isolation strategy. `exe/rigor`
reads only `ENV["RIGOR_PLUGIN_ISOLATION"]` (`exe/rigor:14`); nothing in `lib/` reads such a
configuration key, and it is absent from `schemas/rigor-config.schema.json` — which ADR-99 declared a
source of truth. A user following the normative spec writes a key that is silently ignored.

Others in the same class, from the gap round (fleet-cited, not hand-re-verified):

- **ADR-30** — `rigor-ffi`'s manifest declares no `config_schema`, so both `.rigor.yml` surfaces
  ADR-30 documents (WD4's typedef exception list, WD6's explicit `ffx` target) are unreachable.
- **ADR-102** — `skills/rigor-unused-adjudicate` instructs the agent to look for `0 from plugins`,
  a string `rigor unused` never prints, so that check silently never fires.
- **ADR-99** — the `.rigor.yml` template `rigor init` writes says "the shipped rules are" and then
  lists 7 of the 31 in `ALL_RULES`.
- **ADR-9** — the `:factory_index` cross-plugin channel the ADR calls "in active use" is never
  published; `rigor-rspec`'s `create(:factory)` binding always falls through.
- **ADR-7** — `Merger` builds `Conflict` rows and `Conflict#to_diagnostic` exists, but no production
  code reads `MergeResult#conflicts`, so the `:contribution_merge` diagnostic family is unreachable.
- **ADR-37** — `Plugin::Base#node_rule_diagnostics`, the method ADR-37 names as "the engine-owned
  walk", has zero production call sites.
- **ADR-88** — bundled plugins added after ADR-88 declare no fact surface and are therefore opaque
  to incremental invalidation. *Two lenses disagreed on the blast radius (2 plugins vs "none of
  them"); the critic's wider grep used the wrong token, so this one needs adjudication before it is
  sized.*

## 1. Buried work — decided, still wanted, no issue

35 items. The census pass classified ~177 distinct deferred items across the corpus: **34 tracked**
by an issue (the ADR-98 bulk migration, issues #120–#160, is why that number is as high as it is),
**30 shipped since**, the rest decided-against or trigger-gated — leaving these as genuinely
invisible to the backlog.

Ranked by what it costs to leave them buried:

1. **ADR-96 WD1 + WD2** — the `target_gems:` manifest field and the per-plugin gap advisory are
   recorded as *"committed"* (the index's only use of that word) and have **zero implementation**:
   `rg -n 'target_gems' lib/ sig/ exe/ schemas/ spec/ plugins/*/lib` returns one prose comment. No
   issue. Reported independently by three agents.
2. **ADR-27 WD5 — the self-contained single binary.** "Queued, uncommitted, no milestone", no issue
   anywhere in 372, and it is the **sole gate** on ADR-95's Homebrew deferral. Two ADRs are parked
   behind an item nothing tracks.
3. **ADR-50 — every v1.0.0 freeze obligation.** The `v1.0.0` milestone holds exactly one issue
   (#158, inference budgets). Ratifying ADR-50, promoting `gem-build`/`oss-sweep` to required checks,
   the deprecation policy, the support window — none of it exists on the only surface ADR-98 permits
   for "what the next cut carries".
4. **ADR-2 / ADR-1 — the capability-role catalog and structural-interface assignability.** A settled
   working response backed by a normative MUST in
   `docs/type-specification/structural-interfaces-and-object-shapes.md`. Nothing ships: no
   `_RewindableStream` / `_ClosableStream` / `_FileDescriptorBacked` declaration anywhere, and
   `rbs_type_translator.rb:81` erases every RBS interface to untyped — **while the consumer shipped**
   (`%a{rigor:v1:conforms-to}` and `conformance_checker.rb`). A user who follows the spec writes a
   conformance assertion that fails soft to `:info` and checks nothing.
5. **ADR-68 — class-builder folding.** The demand gate *fired* (faraday's builder layer, open issue
   #525) and the ADR carries a paid-for, de-risked three-walk implementation plan that no issue
   mentions.
6. **ADR-66 — discriminated-union member typing.** Trigger (a) fired when ADR-58 landed; recorded as
   the largest intractable protection hole of the ADR-63 pilot; zero issues.
7. **ADR-17 slice 3b** — `Cache::Descriptor::PreEvalEntry` and per-file pre-eval invalidation never
   landed, yet the ADR, the README row and issue #129 all read as if slices 4–6 are what remains.
   `rg -n 'PreEvalEntry' .` finds it only inside ADR-17.
8. **ADR-7 § 5-C** — wiring `MergeResult#conflicts` into the diagnostic stream (see § 0).
9. **ADR-97** — no spec compares an ADR's `Status:` header to its README row (§ 4).

Then, in the same category but smaller: ADR-11's `dynamic.sorbet.unsupported` / `.degraded` audit
trail (the safety story the lossy-boundary decision rests on, never built); ADR-19's own
re-evaluation trigger (LSP is 2,885 lines against a ~2,000 threshold — the review the ADR *mandates*
has never happened); ADR-22 slice 6 (LSP baseline awareness); ADR-25's `BundleSigDiscovery` GEM_HOME
carry-over; ADR-29's three playground follow-ups (WD8/WD9/hover — **zero of 372 issues mention the
playground at all**); ADR-36 WD3 (the `sealed`-parent fact, which ADR-47 names as its dependency);
ADR-46's Mastodon/GitLab `--verify-incremental` gate extension; ADR-50 WD7 (the bleeding-edge
CHANGELOG section, trigger fired at v0.3.0, five features ago); ADR-56 WD2.9's `Difference` branch;
ADR-73's two `rbs-setup` priority-softening cases; ADR-74's `llms.txt` sync (the divergence it
existed to prevent **has happened**); ADR-82 WD4; ADR-102 WD5's "MUST be pinned by a spec";
ADR-103 WD7's `--promote`; ADR-108 WD4 (`rigor explain` and the `sig.skipped.*` ids).

## 2. Drift — 174 items

### 2a. Reverse drift: shipped, still recorded as unbuilt

The dominant shape, and the one that actively misleads. Highest-value:

| ADR | says | reality |
| --- | --- | --- |
| **102** | `Proposed` · "Nothing implemented" | `rigor unused` shipped v0.3.4, manual chapter, 8 follow-up fixes |
| **103** | `Proposed` · "nothing implemented; four items open" | effect system is the v0.3.4 headline; 14 of 18 slices closed; ADR-104 built on it |
| **20** | slices 2b/4/5/6 open | all four landed (4 and 5 in v0.3.7 with `rigor-dry-monads`) |
| **14** | "slices 2–5 remain demand-driven" | all five shipped, `--write` / `--params=observed` / attr support included |
| **100** | transitive `void` deferred (ADR **and** the normative diagnostic-policy row) | shipped as `VoidTailSummary`, 2026-07-19 |
| **5** | `non-empty-string` "not yet implemented" | carrier shipped; and the `File.basename` tightening it announces was rejected as unsound |
| **38** | block-form additional initializers deferred (ADR + index row) | shipped ~6 weeks ago (#122, `block_initializer?`) |
| **41** | "Nothing here is implemented yet" | its own body records Layer 1 landed and slices 2a/2b done |
| **62** | `arity_extra` opt-in pending an unbuilt signal | all three follow-ups shipped 2026-09-03 |
| **63** | WD5's act-on-coverage skill "proposed; not implemented" | shipped as `skills/rigor-protection-uplift` |
| **24** | slice 4's "required next step" | shipped three months ago |
| **48**, **51**, **57**, **58**, **93**, **96**, **110** | various deferred/queued rows | shipped |

### 2b. A normative obligation the code never honoured

Rarer, and the strongest findings in the sweep.

- **ADR-2's authority tier** — "an incompatible plugin return is a **conflict diagnostic**, not a
  contract override". The dispatcher has silently overridden RBS since v0.1.1. Open issue #700
  already names this; the ADR still states the un-implemented rule as current.
- **ADR-4's status line** claims capability-role inference is live while the **normative**
  `docs/internal-spec/implementation-expectations.md:11-19` says that half has "no implementation
  anywhere in the tree". An ADR and a binding spec asserting opposite things.
- **ADR-72 WD2** — "the overlay cannot manufacture a new diagnostic" is falsified: a partial overlay
  declaration closes a class and produces fresh false `call.undefined-method`.
- **ADR-6** — "the cache never evicts, no size cap" is still asserted in the ADR **and repeated in
  `AGENTS.md`**, four months after ADR-54 WD3 shipped LRU eviction with a 256 MB default that runs at
  the end of every run. `docs/internal-spec/cache.md` contradicts *itself* on this, 760 lines apart.
- **ADR-23 slice 2** is marked LANDED on "H1 derives its selector set from the bundle's `sig/`"; the
  list is hard-coded and has already drifted from that `sig/`.

### 2c. Dead anchors

The anchor-rot lens extracted 17,895 backticked spans (7,346 unique) and existence-checked them.
Most dead spans are benign (comparison vocabulary from PHPStan/TypeScript/Sorbet, deliberately
historical names). What is left is an implementer sent to a symbol that is not there — worst
offenders **ADR-16** (`Manifest#external_files` / `Macro::ExternalFile`, deleted by ADR-60 WD1, still
enumerated as landed public surface and still offered to plugin authors — a manifest written from it
raises `ArgumentError` at class-definition time), **ADR-4** (`Environment::CacheLayer`, two
`FallbackTracer` recorders — never existed), **ADR-13**, **ADR-16**, **ADR-18**, **ADR-51**,
**ADR-55** (`adoptable_self_call_result?`, removed by ADR-57 one day after ADR-55 landed),
**ADR-56**, **ADR-84** (`--budget-trace`, a flag that has never existed — the surface is an env var),
**ADR-109**.

The single most-repeated dead name is **`type_specifier`**: renamed by ADR-80 and removed in 0.3.0,
where it now raises `NoMethodError`. **ADR-37** still teaches it as the narrowing hook, **ADR-2**
still instructs plugin authors to migrate *to* it, and **ADR-50 freezes it in the v1.0.0
frozen-contract table**.

## 3. Obsolescence — 28 items

**No ADR in the corpus carries the `Superseded` status**, and the supersession lens concluded that
this is correct: every supersession here is *partial* — a WD, a slice, a rejection row, a named verb,
a section. What is wrong is the README's "How to Read" (`docs/adr/README.md:10`), which offers only a
whole-document `Superseded` and therefore has no vocabulary for the case the corpus actually
practises. The discipline is otherwise good: ADR-7:362, ADR-2:385, ADR-1:430, ADR-16:395, ADR-54:141,
ADR-15:246 all carry correct in-place markers.

The genuinely overtaken:

- **ADR-12** — the whole packaging decision rests on per-plugin published gems and `git subtree
  split`. Per-plugin gemspecs were deleted 2026-05-27 (`9769f5fa`); ADR-31 retired the model; the
  design doc ADR-12 inherits from carries a "Superseded premise" banner. ADR-12 alone does not.
  Also: its "next slice is `rigor-dry-types`" — all five sequenced dry-rb plugins exist.
- **ADR-94** — the entire decision rests on the rbs 3.x floor, a premise **ADR-32 WD11 measured and
  refuted** in July (closing #229). The ADR still tells a reader the migration "remains deferred" on
  a dead basis.
- **ADR-32 WD2/WD10** — the magic-comment gate and `require_magic_comment: true`. ADR-93 flipped the
  default to `false` in v0.3.4 **and says so explicitly** (ADR-93:231-233); ADR-32 carries no marker
  on either.
- **ADR-1** — names `docs/types.md` as the binding type specification eleven times; that file became
  a 69-line quick guide on 2026-04-28 that itself redirects to `docs/type-specification/`. ADR-1:13
  instructs the reader to "treat `docs/types.md` as the binding text", inverting the hierarchy
  `AGENTS.md:138` sets. The same stale routing is in `docs/adr/README.md:139` and ADR-2:287/:337.
  (The precedence block was written the same day the redirect landed — it was never accurate.)
- **ADR-6 § 5** — points at a "future ADR-amendment" that shipped as ADR-54 WD3 in June.
- **ADR-21** Track 3 (premise retired by ADR-102; its own trigger fired into #143, which chose the
  native route), **ADR-33 WD5** (the "seven read-only tools" partition is closed against a 2026-05
  CLI), **ADR-34** (both dogfood open questions are unanswerable — one names a hook deleted in June),
  **ADR-55**, **ADR-62**, **ADR-63**, **ADR-66**, **ADR-82** (its "the actionability lever is largely
  spent" verdict was measured wrong by #522: 27 genuinely unmodeled nodes out of 26,505),
  **ADR-86** (rests on an attribution ADR-87 explicitly measured wrong), **ADR-102 WD6**,
  **ADR-105** (still says "merge as soon as gates pass"; the Draft discipline #814 forced into
  `AGENTS.md:81-87` after the #788 incident is not reflected), **ADR-0** ("Smart Initialization" —
  `rigor init` has never read `Gemfile.lock`).

## 4. Why this happened, and the cheapest thing that stops it

Three mechanisms, in order of yield:

1. **Two mutually ungated status sources.** `spec/docs/agent_index_spec.rb:150-193` gates the README
   row's length, ordering, contiguity and opening status word, and never looks at the ADR file's own
   `Status:` header. No spec in the repo parses that header at all — an ADR could lose it and stay
   green (ADR-60 is the only one of 111 written as a list item, `- Status: …`, and nothing noticed).
   **A single axis added to that existing spec — parse each ADR's header, compare its status word and
   its slice/WD claims to the README row, fail on disagreement — would have caught a large share of
   § 2a on the commit that introduced it.**
2. **`Proposed` is doing two jobs.** It marks both "we have not built this" and "we built it and
   never came back to the header" (ADR-102, ADR-103). Until those two are reclassified, the
   `Proposed` stratum cannot be used to find unbuilt work — which is exactly what makes § 1 hard.
3. **Long ADRs rot in the middle.** Findings cluster in Status headers and in the last section.
   ADR-16 is 1,246 lines and its stale slice table sits 80 lines above the section every auditor
   found. Expect the same in ADR-56 (870), ADR-22 (860), ADR-1 (849), ADR-20 (830).

One more, worth recording because it is invisible from inside the corpus: the 2026-07-11
status-fidelity audit passed the foundation stratum (ADR-0…8) with a clean bill **while ADR-1 was
already 2.5 months into pointing at a deleted spec and ADR-6 was already wrong about eviction**. A
status-only lens structurally cannot see architecture drift. If this audit is repeated, it should be
repeated on the axes used here.

## Where each finding went

Filed 2026-09-09, after the § 0 defects that were fixed directly.

| | Issues |
| --- | --- |
| § 0 live defects, fixed directly | [#906](https://github.com/rigortype/rigor/pull/906) (playground argv, `rigor help` verbs), [#908](https://github.com/rigortype/rigor/pull/908) (loader meta-gem branch, rigor-rbnacl activation), [#913](https://github.com/rigortype/rigor/pull/913) (the `plugins_isolation:` correction) |
| § 0 live defects, filed | #918 rigor-ffi `config_schema` · #919 rigor-unused-adjudicate · #920 `rigor init` rule list · #921 `:factory_index` · #922 `MergeResult#conflicts` · #923 `node_rule_diagnostics` · #924 ADR-88 opacity |
| § 1 buried work | #911 `plugins_isolation:` · #925 ADR-96 WD1+WD2 · #926 ADR-27 WD5 · #927 ADR-50 freeze obligations · #928 → #929 → #930 capability roles · #932 ADR-68 · #933 ADR-66 · #934 ADR-17 3b · #935 ADR-19 · #936 / #937 / #938 residue bundles |
| § 2, § 3, § 4 | #939 the status-header gate → #940 the reverse-drift sweep · #941 `type_specifier` · #942 `docs/types.md` · #943 partial supersession |

The `:factory_index` finding was sharpened while filing: the cause is that a **producer value** (ADR-60) and a **published fact** (ADR-9) are different channels with the same name — `rigor-factorybot` declares `producer :factory_index` and publishes only `:reachability_references`, while `rigor-rspec` reads the fact store. Two findings were dropped as refuted during filing, and the ADR-50 status observation was removed from #927 for the same reason.

## Suggested sequencing

- **Now, cheap, high yield** — the § 0 defects (four of them are one-line fixes), and the ADR-102 /
  ADR-103 status flip, which is the difference between the `Proposed` list being usable and not.
- **One pass, mechanical** — the `type_specifier` sweep (ADR-2, ADR-37, ADR-50's freeze table), the
  `docs/types.md` routing sweep (ADR-1, ADR-2, README:139), and the § 2a reverse-drift rows.
- **The gate** — the ADR-header axis in `spec/docs/agent_index_spec.rb` (§ 4.1). Doing this before
  the sweep means the sweep is verified rather than asserted.
- **Issues to open** — the nine in § 1, plus the smaller set listed after them. Several are v1.0.0
  obligations that today exist on no surface at all.

## Appendix — every surviving finding

`n` is how many independent agents reported it. Sorted by axis, then severity, then ADR.


### Untracked work (35)

| ADR | sev | n | finding |
| --- | --- | --- | --- |
| ADR-2 | high | 1 | The core capability-role catalog and structural-interface assignability — a settled ADR-2 working response backed by a normative MUST — have zero implementation and zero GitHub issue |
| ADR-7 | high | 1 | Merger conflicts are built and convertible but never collected: no production code reads `MergeResult#conflicts`, so the `:contribution_merge` diagnostic family is unreachable |
| ADR-17 | high | 1 | Slice 3b — `Cache::Descriptor::PreEvalEntry` and per-file pre-eval cache invalidation — never landed, yet the ADR, the README row and issue #129 all record slice 3 as complete |
| ADR-27 | high | 1 | The self-contained single binary (WD5) is "queued, uncommitted, with no milestone" and has no GitHub issue at all, while two other ADRs are gated behind it |
| ADR-50 | high | 1 | Every v1.0.0 freeze obligation ADR-50 defines is absent from the v1.0.0 milestone, the only surface ADR-98 lets "what the next cut carries" live on |
| ADR-68 | high | 1 | ADR-68's demand gate has fired on faraday and its de-risked three-walk implementation plan is invisible: no issue anywhere in the 372-issue corpus mentions it |
| ADR-96 | high | 2 | WD1 (`target_gems:` manifest field) and WD2 (the per-plugin gap advisory) are decided, unimplemented, and represented by no issue |
| ADR-96 | high | 1 | ADR-96's two "committed" slices — the `target_gems:` manifest field (WD1) and the plugin-gap advisory (WD2) — have zero implementation, zero issue, and the field would raise ArgumentError if a plugin author followed the ADR |
| ADR-96 | high | 1 | WD1 (`target_gems:` manifest field) and WD2 (the plugin-gap advisory) are recorded as "committed slices" but have zero implementation and no GitHub issue — and the copy-paste defect the ADR documents is still present verbatim |
| ADR-97 | high | 1 | No spec compares an ADR's own `Status:` header to its docs/adr/README.md row — the corpus runs two mutually ungated status sources |
| ADR-1 | medium | 1 | Capability-role requirement inference — a fully specified subsystem ADR-1 still lists as a wanted v1.1 surface — has zero implementation and no GitHub issue |
| ADR-3 | medium | 1 | The plugin-registered `(name, base, predicate)` refinement triple that OQ3's rationale table sells as Option C's plugin-authoring advantage has no hook and no issue |
| ADR-8 | medium | 2 | The queued lift of `def.return-type-mismatch` `:maybe` from silent to `:warning` is in no issue, and a code comment already narrates it as shipped |
| ADR-11 | medium | 1 | `dynamic.sorbet.unsupported` / `dynamic.sorbet.degraded` — the entire audit trail ADR-11 rests its lossy-boundary safety story on — were never built, are marked "deferred" only in code comments, and have no issue |
| ADR-19 | medium | 1 | ADR-19's own re-evaluation trigger ("LSP past ~2,000 lines") is met on the measure it states, and its recorded size premise is 7.6x stale, with no review and no issue |
| ADR-22 | medium | 1 | ADR-22 Slice 6 (surfacing baselined diagnostics differently in the LSP) is deferred with no issue, and the shipped language server has no baseline awareness at all |
| ADR-25 | medium | 2 | `BundleSigDiscovery`'s carry-over — auto-detecting the default `bundle install` (GEM_HOME) layout — is untracked, and the code confirms the gap is still live |
| ADR-27 | medium | 1 | WD5's single-binary spike is stated as wanted and queued, has zero representation anywhere outside the ADR, and is the sole gate on ADR-95's Homebrew decision |
| ADR-29 | medium | 1 | The three named follow-ups gating the shipped in-browser playground (WD8 persistent-`Runner` env, WD9 Web Worker offload, and the `type-of` hover dropped from the public page) have no GitHub issue |
| ADR-30 | medium | 1 | Slice 3's actual subject — ethon's option-catalog `define_method` setter farm — never shipped, and #141 closed as done, so the gap now has no tracker |
| ADR-36 | medium | 1 | The WD3 ceiling — emitting the sealed-parent fact / threading synthetic variant classes into `Environment#class_ordering` — is declared in scope by the ADR, still cited as the deferred ceiling by the binding internal spec, and has no issue |
| ADR-36 | medium | 1 | ADR-36 WD3 (`sealed`-parent fact + `is_a?` cross-variant exhaustive narrowing) is deferred, unimplemented, and has no issue — while ADR-47 names it as a dependency of its own open WD3b |
| ADR-46 | medium | 1 | "Extend the CI gate to the Mastodon + GitLab survey trees" is the one still-open item in ADR-46's staging list and has no issue |
| ADR-50 | medium | 1 | The dedicated bleeding-edge CHANGELOG section's own landing trigger fired at v0.3.0; five features later it does not exist, no issue tracks it, and ADR-105's fragment gate now forecloses it |
| ADR-50 | medium | 1 | WD7's dedicated bleeding-edge CHANGELOG section never shipped, four releases after the trigger it was gated on, and the ADR still records the trigger as unfired |
| ADR-56 | medium | 1 | WD2.9's explicitly-deferred `Difference` branch — the straight-line seam dropping a mutator's added element on a `non-empty-array[T]` receiver — has no GitHub issue |
| ADR-66 | medium | 1 | ADR-66's re-evaluation trigger (a) fired months ago and the design — recorded as the largest intractable protection hole — has no issue at all |
| ADR-73 | medium | 1 | The two remaining `rbs-setup` priority-softening cases were parked on `--deep`, which shipped without them; `describe` still recommends `rigor-rbs-setup` on bare `Gemfile.lock` presence and still ranks it ahead of CI |
| ADR-74 | medium | 1 | The `llms.txt` sync follow-up was never built and the divergence it was meant to prevent has happened: the gem's offline doc index omits manual chapters 18 and 19, which the gem does ship |
| ADR-82 | medium | 2 | WD4 (framework_dsl_boundary recording, the `enable_plugin` half of G2) is still deferred with no issue, leaving one of the three tractability categories unreachable on real apps |
| ADR-102 | medium | 1 | WD5 states the `--incremental` refusal "MUST be pinned by a spec" and no spec anywhere covers it |
| ADR-103 | medium | 1 | WD7's `--promote` (writing an `effects.envelopes` stanza from observed summaries) exists nowhere in the code, the CLI, the manual or the normative spec, and no issue tracks it |
| ADR-108 | medium | 2 | The WD4 "small follow-up" — teach `rigor explain` the `sig.skipped.*` ids — is real, still wanted, and has no issue |
| ADR-5 | low | 1 | ADR-5's three Open Questions claim to be "tracked alongside the related slices"; no issue holds any of them and the v0.1.0+ deferral marker is three minor versions stale |
| ADR-13 | low | 1 | WD4's `params_of[F]` / `return_of[F]` core operators are "queued as a follow-up" with no issue, while ADR-13's sibling follow-up got one (#127) |

### Obsolescence (28)

| ADR | sev | n | finding |
| --- | --- | --- | --- |
| ADR-1 | high | 3 | ADR-1 names `docs/types.md` as the binding type specification six times; that file is now a 69-line quick guide that itself points elsewhere |
| ADR-6 | high | 2 | ADR-6 still states the cache never evicts and has no size cap; LRU eviction with a 256 MB default cap shipped in ADR-54 WD3 and the stale claim has propagated into AGENTS.md |
| ADR-12 | high | 1 | ADR-12's whole packaging decision rests on per-plugin published gems + `git subtree split`, a premise retired 2026-06-02 by ADR-31; ADR-96 records the supersession but ADR-12 carries no marker |
| ADR-32 | high | 3 | WD2's magic-comment gate and WD10's `require_magic_comment: true` default were superseded by ADR-93 in July, but ADR-32's own text still states both as current |
| ADR-32 | high | 1 | ADR-93 supersedes ADR-32's WD2 magic-comment gate and WD10's default, and says so — but ADR-32 carries no marker on either |
| ADR-37 | high | 1 | ADR-80 renamed and then deleted ADR-37's `type_specifier` DSL verb, but ADR-37 (and ADR-2's migration instruction) still teach the dead spelling |
| ADR-94 | high | 1 | ADR-94's entire decision rests on the rbs 3.x floor, a premise ADR-32 WD11 measured and refuted in July; the ADR still tells a reader the migration "rides along at near-zero marginal cost" once the floor moves |
| ADR-0 | medium | 2 | ADR-0's "Smart Initialization" promise — `rigor init` analysing Gemfile.lock to auto-suggest and configure plugins — was quietly reassigned to the ADR-73 skill/doctor surface; `rigor init` writes a static template with an empty `plugins:` list |
| ADR-6 | medium | 1 | docs/internal-spec/cache.md asserts "ADR-6's store never evicts" 760 lines after documenting the 256 MB LRU default it ships with |
| ADR-12 | medium | 1 | ADR-12's packaging decision rests on the per-plugin-gem model that was retired in 2026-05-27; its subtree-split path, its `rigor-dry-rb` umbrella gate, and its "list individual gems in their `Gemfile`" instruction are all impossible today, with no supersession mark |
| ADR-12 | medium | 1 | ADR-12's sequencing and open questions rest on three premises that are all false: the next slice already shipped, the recommended dry-monads hook was deleted, and the Result/Maybe carrier it declares out of scope is now what the plugin returns |
| ADR-19 | medium | 1 | The LSP-size re-evaluation trigger has fired — 2,885 lines against a ~2,000 threshold — and the mandatory review the ADR schedules has never happened |
| ADR-21 | medium | 1 | ADR-21 Track 3's rubydex LSP provider rests on a premise ADR-102 retired, and its own trigger fired into an issue that chose the native route |
| ADR-33 | medium | 1 | ADR-33 WD5's "seven read-only tools" partition is closed against a 2026-05 CLI; ten read-only verbs have shipped since and appear in neither the tool table nor the exclusion list |
| ADR-34 | medium | 1 | Both slice-1-dogfood open questions (Rake task files, `bin/*` shebang scripts) are unanswerable as written: one names a plugin hook deleted in 2026-06, and both assume file kinds `rigor check` refuses to analyse |
| ADR-50 | medium | 1 | ADR-50's enumerated v1.0.0 frozen-contract table freezes a plugin DSL verb (`type_specifier`) that ADR-80 deleted in 0.3.0 |
| ADR-55 | medium | 1 | The `bot`-collapse soundness fix is recorded in terms of a predicate ADR-57 removed and a helper that never existed |
| ADR-62 | medium | 1 | ADR-62's table still lists the user-facing type-protection coverage report as Proposed/demand-gated, but ADR-63 shipped it the next day and productized the mutator into lib/ |
| ADR-63 | medium | 1 | The sole "remaining demand-gated" item names an ADR-46 mechanism that issue #134's investigation measured and refuted, while the whole-project Tier 2 speedup shipped by other means |
| ADR-66 | medium | 1 | ADR-66's demand gate names a trigger that was already satisfied four days before the ADR was written, and omits the prerequisite its same-day sibling identified |
| ADR-82 | medium | 1 | ADR-82's closing verdict — "the actionability lever is largely spent" and the residual `unsupported_syntax` is "the honest engine-gap floor" — was measured wrong and has been overtaken by shipped work |
| ADR-86 | medium | 1 | WD4's ladder rests on an attribution ADR-87 explicitly measured wrong, and its first rung was completed by ADR-87 by a different route — ADR-86 has never been revised and carries no forward pointer |
| ADR-102 | medium | 1 | WD6's stated premise — that a cross-file value constant "never resolves" — was falsified by #352 and #644, and WD6's own re-evaluation trigger ("reopens the moment #352 lands") has fired with nothing tracking it |
| ADR-105 | medium | 1 | ADR-105's sequential-landing rule still reads "merge as soon as gates pass" — the Draft discipline and the whose-PR restriction that #788 forced into AGENTS.md never reached it |
| ADR-1 | low | 2 | ADR-1's § "Pre-Plugin Inference Surface" still scopes the analyzer against a v1 / v1.1 release plan whose "not yet exposed" list has mostly shipped and whose feature-flag mechanism was never built |
| ADR-21 | low | 1 | Track 3's trigger has effectively fired and the tracked plan takes the opposite mechanism — a native Reflection symbol index, not the pre-committed rubydex provider |
| ADR-41 | low | 1 | The evaluation verdict rests on a recursion guard that widens to `Dynamic[top]`; ADR-55 replaced that on-hit result with a Kleene fixpoint summary, and ADR-41 never records the supersession |
| ADR-70 | low | 1 | ADR-70 routes whole-project fused affordability to ADR-46, a premise issue #134's investigation refuted and the fused path's deliberate sequentiality forecloses |

### Drift (174)

| ADR | sev | n | finding |
| --- | --- | --- | --- |
| ADR-2 | high | 2 | ADR-2's authority-tier rule ("an incompatible plugin return is a conflict diagnostic, not a contract override") has never been implemented; the plugin tier sits ABOVE RbsDispatch and wins silently |
| ADR-4 | high | 2 | ADR-4's status line claims capability-role inference is live, while the normative engine-surface spec says that half has "no implementation anywhere in lib/" |
| ADR-5 | high | 5 | ADR-5 calls the `non-empty-string` carrier "not yet implemented" and names `File.basename` as its target — the carrier shipped, and `basename` is the one path method the implementation records as unsound to refine |
| ADR-6 | high | 1 | ADR-6 still says the cache never evicts and has no size cap, but LRU eviction plus a 256 MB default cap have shipped and run at the end of every `rigor check` — and AGENTS.md repeats the stale claim citing ADR-6 |
| ADR-9 | high | 1 | The `:factory_index` cross-plugin channel the ADR names as "in active use" is never published — `rigor-rspec`'s `create(:factory)` let-binding always reads nil |
| ADR-13 | high | 2 | The TypeScript-utility-types translation table promises two `plugin.typescript-utility-types.*` diagnostic ids and a `Dynamic[top]` degradation the shipped plugin never implements |
| ADR-14 | high | 3 | ADR-14 still records slices 2–5 as "demand-driven"; all five landed on the day it was accepted |
| ADR-15 | high | 1 | The Ractor pool's recorded blocker set omits the rbs 4.x namespace-interning blocker that ADR-103 WD16 ruled unclearable by Rigor |
| ADR-15 | high | 1 | ADR-15 names one CRuby bug as the Ractor pool's blocker; the actually-fatal blocker is an upstream rbs 4.x namespace intern cache that the ADR never mentions |
| ADR-16 | high | 1 | § "Public-API drift surface" still lists three symbols and four diagnostic ids as landed; two were deleted by ADR-60 WD1, one class (`Rigor::Type::Method`) never existed, and none of the four ids exist |
| ADR-16 | high | 1 | Slice 7 claims `skills/rigor-plugin-author` Phase 2 splits into "Step 2A — Try the macro substrate first" / "Step 2B — Hand-rolled walker"; the user-facing skill contains no mention of the substrate at all |
| ADR-20 | high | 4 | ADR-20's status header and § "What remains open" list slices 2b, 4, 5 and 6 as unshipped; all four have landed (4 and 5 in v0.3.7) |
| ADR-24 | high | 1 | Status header still names subclass-aware gating as slice 4's "required next step" three months after it shipped, and the "Remaining" paragraph still lists a corpus gate the same header says already ran |
| ADR-25 | high | 1 | plugins/rigor-rbnacl ships sig/rbnacl.rbs and its README advertises it, but the manifest declares no `signature_paths:` — the RBS is never loaded |
| ADR-29 | high | 1 | `rigor playground` is dispatched with `@argv[1..]` after the verb was already shifted off, so a bare invocation raises and `--port=` is silently discarded |
| ADR-30 | high | 1 | `rigor-ffi`'s manifest declares no `config_schema`, so WD4's typedef exception list and WD6's explicit `ffx` target are both unreachable — the ADR's spelling is silently ignored, the real key names abort the run |
| ADR-30 | high | 1 | rigor-ffi's manifest declares no `config_schema`, so both `.rigor.yml` surfaces ADR-30 documents (WD4's typedef exception list, WD6's explicit `ffx` target override) are unreachable — one is inert, the other is a hard LoadError |
| ADR-30 | high | 1 | `rigor-ffi-plugin-author` is designed for external authors writing their own `rigor-<gem>` gem, but sits in `.claude/skills/` marked `internal: true`, so no external author can ever reach it |
| ADR-38 | high | 2 | Block-form (`before` / `let` / `subject`) additional initializers shipped ~6 weeks ago; the ADR and its index row still call them deferred in five places |
| ADR-50 | high | 1 | The WD1 compatibility document — the release's published stability contract — still describes the v0.2.0 line and tells users the bleeding-edge overlay is empty |
| ADR-62 | high | 1 | All three ADR-62 mutation-teeth follow-ups shipped 2026-09-03, but WD3 and the deferred table still say arity_extra is opt-in pending an unbuilt signature-arity guard |
| ADR-72 | high | 1 | WD2's "the overlay cannot manufacture a new diagnostic" is falsified — a partial overlay declaration closes a class and produces fresh false `call.undefined-method`s, which the engine now works around with a hand-maintained allow-list |
| ADR-88 | high | 1 | Two bundled plugins added after ADR-88 (rigor-dry-monads, rigor-ethon) declare no fact surface, so they are OPAQUE and silently force a full analysis on every --incremental recheck |
| ADR-88 | high | 1 | Two bundled plugins added after ADR-88 (rigor-dry-monads, rigor-ethon) declare no fact-surface channel, so any project using them is permanently OPAQUE — `--incremental` never reuses its snapshot and the mutation cache refuses to key |
| ADR-93 | high | 1 | ADR-93's default flip and auto-wire shipped in code and in the binding spec, but every user- and contributor-facing doc for rigor-rbs-inline still teaches the superseded opt-in model (magic comment mandatory, `require_magic_comment` default `true`, plugin must be listed) |
| ADR-100 | high | 3 | The transitive-`void` slice is shipped (`VoidTailSummary`) while both the ADR status header and the README row still call it deferred/queued |
| ADR-102 | high | 5 | ADR-102's Status header still reads "Nothing implemented" for `rigor unused`, which shipped in v0.3.4 and has been maintained through v0.3.8 |
| ADR-102 | high | 1 | `skills/rigor-unused-adjudicate` tells the agent to look for `0 from plugins`, a string `rigor unused` never prints — the check silently no-ops on exactly the case it exists to catch |
| ADR-103 | high | 3 | The ADR-103 index row says "nothing implemented; four items open at Proposed" while the effect system shipped as the v0.3.4 headline and has been extended in every release since |
| ADR-103 | high | 1 | ADR-103 reads `Proposed … nothing implemented` while the effect system it designs is shipped and is the single most-cited ADR in the binding spec corpus |
| ADR-1 | medium | 1 | ADR-1 specifies the Rigor-native suppression grammar as `# rigor:ignore[…]` plus an `ignore-start`/`ignore-end` block form; the shipped grammar is `# rigor:disable` / `# rigor:disable-file` and there is no block form |
| ADR-1 | medium | 1 | The capability-role catalog says each Rigor-specific role ships as an explicit RBS interface in bundled signatures; none of the three Rigor-specific interfaces exists anywhere in the tree, while the `conforms-to` checker that would consume them ships |
| ADR-2 | medium | 1 | ADR-2's failure-isolation policy ("a plugin exception should become a plugin diagnostic with provenance") is honoured only for `diagnostics_for_file`; every per-call runtime hook swallows the exception with no diagnostic, while citing ADR-2 as the authority for doing so |
| ADR-3 | medium | 1 | The binding internal spec says ADR-3's open questions 1 and 2 are unresolved and abstracts its contract around them; ADR-3 records both as settled Working Decisions and its status calls them live |
| ADR-4 | medium | 1 | ADR-4's Slice 7 reads as the one outstanding slice and names `Rigor::Type::RefinedNominal`, a class that never existed |
| ADR-4 | medium | 1 | Three anchors in an ADR headed "implemented and shipped" name symbols that never existed: `Environment::CacheLayer`, two `FallbackTracer` recorders, and `Type::RefinedNominal` |
| ADR-5 | medium | 1 | ADR-5 says the `non-empty-string` refinement carrier is "documented but not yet implemented" and that path methods stay at `Nominal[String]`; the carrier shipped in v0.0.4 and File.expand_path / File.dirname have been refined to `non-empty-string` since v0.1.x |
| ADR-6 | medium | 1 | ADR-6's on-disk artifacts are pinned two format bumps behind, and `schema_version.txt` no longer carries "a single integer" |
| ADR-7 | medium | 1 | ADR-7 records the node-scoped rule API as deferred; ADR-37 shipped `.node_rule` and migrated every bundled plugin off the flat hook |
| ADR-10 | medium | 1 | ADR-10's Open Questions still defers the per-receiver plugin veto that shipped in v0.1.4 as `manifest(owns_receivers:)`, and its Public-API drift surface omits both that field and the `dependencies.budget_overrun_strategy` config key |
| ADR-11 | medium | 1 | The `plugin.sorbet.*` "initial entries" table lists two diagnostic ids the shipped adapter never emits |
| ADR-11 | medium | 1 | ADR-11's "Plugin contract surface" section documents `Plugin::Base#flow_contribution_for` as the hook rigor-sorbet uses, but that hook was deleted in ADR-52 WD3 and a plugin defining it now fails to load |
| ADR-11 | medium | 1 | ADR-11's "Plugin contract surface" section describes rigor-sorbet through a hook deleted in 2026 and a `method_signatures` fact-store channel that never existed anywhere in the tree |
| ADR-12 | medium | 1 | ADR-12 still names `rigor-dry-types` as "the next slice" and leaves four sequencing rows unmarked, though dry-types, dry-validation, dry-schema and dry-monads have all shipped |
| ADR-14 | medium | 1 | Two shipped `sig.skipped.*` identifiers (#735, #744) are in neither ADR-14's reserved list nor the normative diagnostic registry, and the registry row still gates them on a `--write` milestone that has passed |
| ADR-16 | medium | 1 | ADR-16's Public-API drift surface and Substrate contract name five value classes / attrs and six diagnostic identifiers that exist nowhere in the codebase |
| ADR-16 | medium | 1 | ADR-16's Tier C precision posture promises a `macro.tier_c.unresolved-return` `:info` provenance marker that is emitted nowhere, and describes a Dynamic-only floor that slice 6b already replaced |
| ADR-16 | medium | 1 | ADR-16 still enumerates `Manifest#external_files` / `Macro::ExternalFile` as landed public surface and tells authors they may declare Tier D entries today — ADR-60 WD1 deleted the field, and declaring it now raises at plugin-definition time |
| ADR-18 | medium | 1 | The declared public-API addition `SyntheticMethod#return_type_source` never shipped, and the drift spec named as its gate does not cover the class at all |
| ADR-22 | medium | 1 | Carry-over still places both SKILLs in the contributor `.claude/skills/` tree and calls the external variant "queued for v0.2.0" — contradicting the ADR's own WD8 and its LANDED slices |
| ADR-22 | medium | 1 | Slice 3's "LANDED (v0.1.9)" file inventory names one skill file that was never created and one reference page under a name it never had |
| ADR-22 | medium | 1 | ADR-22's CLI surface says `rigor baseline prune` confirms interactively and takes `--force`; it writes unconditionally and `--force` is a usage error |
| ADR-22 | medium | 1 | `rigor help` lists 23 of the 25 dispatchable verbs — `baseline` (ADR-22) and `unused` (ADR-102) are absent, and no gate covers the help text |
| ADR-22 | medium | 1 | ADR-22 WD7's promised `--stats` baseline section was never built — only the stderr summary half of WD7 landed, in different wording |
| ADR-23 | medium | 1 | H1's suggested action still tells users to wire rigor-activesupport-core-ext via `signature_paths:`; the shipped hint says `plugins:` and ADR-72 now auto-applies the overlay |
| ADR-23 | medium | 2 | Slice 2 is marked LANDED with "H1 derives its selector set from the bundle's sig/", but the list is hard-coded and has already drifted from that sig |
| ADR-24 | medium | 1 | Slice-1 and slice-2 "As shipped" paragraphs still state the Bot-only adoption gate as current behaviour, contradicting the same ADR's WD3 note — and that stale text is the verbatim body of still-open issue #156 |
| ADR-26 | medium | 1 | Decision Parts 3 and 4 and implementation slices 3 and 4 name `flow_contribution_for` as the relation-typing mechanism, but that hook was deleted pre-1.0 and now raises ArgumentError at plugin load |
| ADR-26 | medium | 1 | ADR-26's Parts 3 and 4 — the whole plugin half of the AR relation-typing design — are specified in terms of `flow_contribution_for`, deleted 2026-06-11, while the ADR's status still reads "implemented" |
| ADR-27 | medium | 1 | WD2 still claims `mise use gem:rigortype` pins the Rigor version — measured false 2026-07-17; a plain `mise use` records `"latest"`, and only `--pin` pins |
| ADR-30 | medium | 1 | The whole plugin family shipped in v0.3.7 but the Status header, the index row, and the slicing table all still read as if nothing has been built |
| ADR-31 | medium | 2 | The "What ships in `rigortype`" supply-chain reference table has two wrong rows since ADR-73/ADR-74 — `examples/` is not packaged, and `docs/manual` + `docs/handbook` + `skills/` are |
| ADR-33 | medium | 1 | WD5's "seven read-only tools" plus an Excluded list naming only write-side verbs and `lsp` no longer partitions the CLI: six documented read-only verbs shipped after it, are exposed by no MCP tool, appear in neither list, and no issue records the gap |
| ADR-34 | medium | 1 | The binding diagnostic-policy spec and the shipped `rigor explain` catalog still describe `call.unresolved-toplevel` as same-file-only, while ADR-34 slice 2's cross-file `paths:`-wide toplevel-`def` index is what the rule actually consults |
| ADR-35 | medium | 2 | Issue #130 still lists WD9 tier-1 generic-instantiation-aware comparison as unstarted follow-on work, 14 months of ADR revisions after the ADR and the code record it as landed |
| ADR-37 | medium | 1 | Status header's "Not yet done" list is empty in reality: the `dynamic_return` generalisation and all three Phase 0c-0e author helpers shipped, and the header contradicts its own opening paragraph |
| ADR-37 | medium | 1 | ADR-37 still spells the narrowing hook `type_specifier`, a verb removed in 0.3.0 that now raises NoMethodError; no naming note points at `narrowing_facts` |
| ADR-37 | medium | 1 | `Plugin::Base#node_rule_diagnostics` — the method ADR-37 names as "the engine-owned walk" — has zero production call sites since ADR-52 WD4; its own doc comment still claims the runner calls it, and the node-rule DSL semantics are pinned only against this dead copy |
| ADR-38 | medium | 1 | ADR-38's block-form additional-initializer slice is recorded as deferred in both status sources three months after it shipped |
| ADR-39 | medium | 1 | The `.rigor.yml` `plugins_isolation:` key the ADR (and the normative internal-spec, and the shipped changelog) says selects the isolation strategy does not exist — only the env var does |
| ADR-39 | medium | 1 | The Status header still lists slice 5 (the isolation layer) as deferred and the decision table still names `Ruby::Box` the chosen isolation, but slice 5 landed with `process` as the default and `ruby_box` gated experimental |
| ADR-39 | medium | 1 | ADR-39 (and the normative internal spec) tell users to select the plugin-isolation strategy with `.rigor.yml`'s `plugins_isolation:`; it is not a Configuration key and nothing reads it — the setting is silently discarded |
| ADR-39 | medium | 1 | The `.rigor.yml` `plugins_isolation:` key does not exist — `exe/rigor` reads only the env var, and writing the documented key earns a config-audit "has no effect" warning while the strategy silently stays `process` |
| ADR-41 | medium | 1 | Status says "Nothing here is implemented yet" and the index row calls Layer 2 "queued", while the ADR's own body records Layer 1 landed, slices 2a/2b Done, and Layer 2 demand-deferred |
| ADR-41 | medium | 1 | CONTEXT.md's `budget` glossary entry sends readers to #123 (plugin test harnesses); the budgets issue is #158 |
| ADR-44 | medium | 1 | The "remaining lever" ADR-44 defers to — the ProjectScope regrouping of Scope's discovered_* fields — shipped a week later as ADR-53's Scope::DiscoveryIndex, and open issue #150 still lists it as unbuilt |
| ADR-45 | medium | 1 | "The no-change floor is the pre-passes, not zero" is false since ADR-87 WD4 — a warm hit is served without the pre-passes or the engine |
| ADR-46 | medium | 1 | The "Implementation trap (do not refactor this away)" forbids a refactor that landed three months ago and names an ivar that no longer exists |
| ADR-46 | medium | 1 | The Staging section's two "Remaining in this slice" lists and stage 4 still describe as unbuilt the disk cache, the `--incremental` flag, the `--verify-incremental` gate and symbol granularity — all landed, and all contradicted by the ADR's own status header |
| ADR-47 | medium | 1 | The `flow.unreachable-clause` FP envelope was rewritten under ADR-47 by #657/#751 (unknown class ordering must not collapse to Bot) and neither the ADR nor its index row records it — the standing "zero firings, zero false positives" evidence is now an incomplete account of the rule's field record |
| ADR-48 | medium | 2 | The index row still calls Struct slice 4 deferred, and the ADR's own Status header stops at slice 4, while slices 4 and 5 both shipped (v0.3.0 and later) |
| ADR-48 | medium | 1 | ADR-48's slice-4 row still calls bare-local block-form parity "a demand-gated remnant" 300 lines after the same ADR records it landed, and after its tracking issue closed |
| ADR-50 | medium | 2 | WD6's landed-mechanism paragraph says the perf stage runs `continue-on-error`; perf-bench has been a hard, job-failing gate since 2026-06-13, and three downstream docs repeat the stale "advisory" reading |
| ADR-50 | medium | 1 | The ADR and its published compatibility companion still pin "the v0.2.0 line" as the current trial, three minors after it closed, leaving WD7's graduation window naming a release that has shipped |
| ADR-50 | medium | 1 | WD6's "Mechanism (landed, advisory)" paragraph is now false — the perf stage is a hard gate that fails a release branch, and the OSS-sweep thresholds are calibrated |
| ADR-50 | medium | 1 | WD4's perf gate never measured an OSS corpus — it benchmarks Rigor's own `lib` — and its "mechanical no-regression" promise was met at v0.3.7 by blessing a +91.9% allocations regression into the baseline |
| ADR-51 | medium | 1 | The "Rejected / deferred" table still lists `teamcity` as demand-gated and Carry-over still lists JUnit XML as a follow-up — both shipped in the very cut this ADR records |
| ADR-55 | medium | 1 | WD1's second clamp and the bot-collapse soundness fix both rest on `adoptable_self_call_result?`, which ADR-57 removed one day after ADR-55 landed |
| ADR-57 | medium | 1 | The "future slices" list still queues singleton-ancestry resolution (`extend M` / `extend self` / inherited class methods) that shipped in v0.3.7 |
| ADR-58 | medium | 2 | The Status header and the index row both call WD1b "queued", but the ADR's own WD2 status re-adjudicated it to demand-gated earned conservatism |
| ADR-60 | medium | 1 | WD5 claims the shipped external-author SKILL gained the producer / watch: / producer_value guidance; that skill contains no occurrence of producer, cache_for or watch: at all |
| ADR-63 | medium | 2 | WD5's act-on-coverage skill is still labelled "proposed; not implemented" three months after it shipped as skills/rigor-protection-uplift/SKILL.md |
| ADR-64 | medium | 1 | The Decision, the deferred-alternatives table and the Consequences still demand-gate the non-nil channel that the Status header and check_rules.rb say already shipped |
| ADR-67 | medium | 1 | WD6b's guarded-rule list names `call.visibility-mismatch`, which is not a registered rule id |
| ADR-71 | medium | 1 | ADR-71's re-evaluation trigger (a) — "ADR-46 incremental analysis has landed" — has been satisfied for ~2 months, and its dependents index is already wired into the mutation substrate; the ADR still reads as gated on it |
| ADR-72 | medium | 1 | WD5's "no engine change" generalization promise is already broken by `CheckRules::GEM_OVERLAY_OPEN_RECEIVERS`, and the ADR carries no note although an open issue names the breakage |
| ADR-73 | medium | 1 | The "Broken-`sig/` blind spot (clear-win, queued)" open decision shipped in both halves — the empty-env banner as `rbs.coverage.environment-build-failed` and the `rigor-doctor` promotion inside `describe --deep` — but the ADR still reads "queued" |
| ADR-73 | medium | 1 | WD2's published decision tree routes a baselined project to `rigor-baseline-reduce`; the shipped tree deliberately does not, and the reversal is recorded only in a source comment |
| ADR-74 | medium | 1 | The packaged-link gate that guarantees every shipped page's links resolve for a gem-only reader skips the packaged `skills/` tree, and six links there resolve nowhere |
| ADR-75 | medium | 1 | The `dynamic_origin` cause-set table lists 5 hyphenated ids; the shipped public field has 6 underscored symbols, and the missing one is the dominant real-app cause |
| ADR-77 | medium | 1 | The shipped `rigor-doctor` SKILL never routes to the `rigor doctor` command ADR-77 built for it, and misses three of its seven checks |
| ADR-81 | medium | 2 | ADR-81 and ADR-73 record a "queued follow-up" that their own landing commit had already completed |
| ADR-81 | medium | 1 | WD1's "every non-entry skill carries the freshness directive" is false — rigor-unused-adjudicate ships without it, and nothing gates the invariant |
| ADR-82 | medium | 1 | WD1's provenance-propagation consumer is named as `ProtectionScanner#propagated_origin`; the shipped consumer is `Inference::OriginLookup` |
| ADR-82 | medium | 1 | Two ADR `Status:` headers are unparseable by the vocabulary the README gate enforces — ADR-82 declares no status word at all, ADR-60 is the sole list-item spelling |
| ADR-87 | medium | 1 | WD1's `cache.validation` vocabulary and WD2's cost model predate #190: the default is now `auto` (digest under CI), because a fresh CI checkout makes every stat-signature glob slot stale on every run |
| ADR-92 | medium | 1 | ADR-92's void carry-over still says `static.*` and `void_origins` do not exist; both shipped in ADR-100 and the ADR has no forward pointer to it |
| ADR-92 | medium | 1 | ADR-92 points at issue #163 as still open for the un-read internal-spec documents; #163 was closed COMPLETED and the line-by-line read of all three was done |
| ADR-92 | medium | 1 | ADR-92 WD2's `internal-type-api.md` marker covers three of the five unimplemented method sections — § Capability predicates and § Refinement projections are still stated as present-tense MUSTs |
| ADR-93 | medium | 1 | docs/adr/README.md's ADR-93 row still advertises WD5 as "slice queued" seven weeks after all three #194 slices shipped, and predates WD6 entirely |
| ADR-93 | medium | 1 | README says ADR-93 WD5's engine-anchored plugin resolution is a "slice queued", but both halves (anchored require and the `doctor` skew flag) are implemented |
| ADR-96 | medium | 1 | The Status header and README row call WD1-WD2 "committed" — the index's only use of that word — where every neighbour distinguishes landed from unimplemented |
| ADR-98 | medium | 1 | Three shipped releases still have OPEN milestones — one holding two issues that did not ship in it — on the surface README links as the public roadmap |
| ADR-99 | medium | 1 | The `.rigor.yml` template `rigor init` writes claims "the shipped rules are" and then lists 7 of the 31 in ALL_RULES, and 5 of the 8 family wildcards |
| ADR-100 | medium | 1 | An expired "as of this writing" marker in `special-types.md` still calls `static.*` a family with no implemented identifiers, contradicting `diagnostic-policy.md` and the file's own `void` section |
| ADR-103 | medium | 1 | ADR-103 WD7 spells the effect-snapshot surface as four flags (`--update`, `--check`, `--diff`, `--explain`); all four shipped as subcommand verbs and none is an accepted option |
| ADR-107 | medium | 1 | ADR-107 § Consequences still states inline `#:` / `# @rbs` annotations are "forbidden" in this tree — the exact rule its own 2026-09-09 amendment withdrew |
| ADR-110 | medium | 1 | § Consequences still says "WD5's measurement is unrun" and the Negative's size "unknown", while WD5 in the same file now carries the measurement and the number |
| ADR-2 | low | 1 | The Ractor Open Question tells plugin authors to migrate to `type_specifier`, a hook removed in 0.3.0 |
| ADR-2 | low | 1 | ADR-2 assigns the detailed normative product specification to `docs/types.md`, which is now an informational quick guide |
| ADR-3 | low | 1 | The normative `internal-type-api.md` section ADR-3 promised on the Difference carrier, the canonical-name registry, and the `String#size`/`String#empty?` projections was never written, though the slice shipped |
| ADR-4 | low | 1 | ADR-4's ADR-15 boundary section names `Environment::CacheLayer` as a landed Phase 2b half and routes Scope→Environment dispatch through it; the class does not exist |
| ADR-5 | low | 2 | ADR-5 quotes the engine as producing `int<0, 4>`, a notation ADR-109 retired from display |
| ADR-5 | low | 1 | ADR-5 spells the conformance directive `%a{rigor:v1:conforms-to: _Frobbable}` with a colon the grammar does not accept |
| ADR-6 | low | 1 | ADR-6 lists the long-running-daemon / LSP cache mode as deferred; the LSP ships a per-session read-only Store and editor mode auto-flips to it |
| ADR-9 | low | 1 | Slice 6's documentation deliverable names a file that was never created; the cross-plugin contract landed inside `plugin.md` |
| ADR-12 | low | 1 | ADR-12's sequencing still says "The next slice is `rigor-dry-types`" and its status carries no progress note, while four of the six sequenced dry-rb plugins have shipped |
| ADR-13 | low | 1 | The `plugin.<id>.type-node-shadow` `:info` diagnostic — the safety valve WD3/WD5 use to justify first-non-nil-wins over priority tiers — was never implemented |
| ADR-14 | low | 1 | Slice 1's named integration spec path does not exist and never did |
| ADR-15 | low | 1 | `Environment#reflection`'s doc comment claims the carrier is `Ractor.shareable?`, which WD6 and the readiness spec pin as false |
| ADR-16 | low | 1 | The Tier B and Tier C manifest examples use a nested `call_shape:` and a `sort_key:` field the value classes reject, and the 2026-06-13 naming note implies only two keywords drifted |
| ADR-17 | low | 1 | Issue #129 — the tracker ADR-17's Status names — still lists slice 4 as an open checkbox two months after it shipped |
| ADR-18 | low | 1 | ADR-18's "Public-API drift surface" lists two additions that never shipped: `SyntheticMethod#return_type_source` and an "exactly one of returns:/returns_from_arg:" validator |
| ADR-19 | low | 1 | ADR-19's Status header still carries no implementation note two months after the 2026-07-11 audit recommended one; only the README half of that fix was applied |
| ADR-20 | low | 1 | WD3's `hkt.budget-exhausted` `:info` diagnostic never existed; fuel exhaustion is a silent counter, and the binding spec says so |
| ADR-20 | low | 1 | The `dependencies.lightweight_hkt:` opt-in gate ADR-20 says every slice ships behind has never existed, and the published config schema rejects the key |
| ADR-22 | low | 2 | WD7's second commitment — a baseline section in `--stats` — was never implemented |
| ADR-22 | low | 1 | The WD1 baseline-file example uses the rule id `nullable-receiver`, which has never existed |
| ADR-22 | low | 1 | ADR-22's slice-3 inventory and § Carry-over place the two user-facing SKILLs under `.claude/skills/`, contradicting the ADR's own WD8 and the repo's two-tree rule |
| ADR-29 | low | 1 | WD6's closing paragraph and the slice-5 row still name completed work as the next step, contradicting the ADR's own "Shipped 2026-06-14/15" header |
| ADR-31 | low | 1 | The rollout section and WD4 point at surfaces that no longer exist: slice 5 targets the deleted `docs/ROADMAP.md`, and WD4 calls an external SKILL "queued for v0.2.0" that shipped in v0.1.9 |
| ADR-36 | low | 1 | The plugin inventory and `rigor-mangrove`'s own README still advertise the Enum surface as deferred, contradicting the same README 70 lines later |
| ADR-41 | low | 1 | The ADR-41 index row still lists Layer 1 doc hygiene as queued three months after it landed, and the ADR header says nothing is implemented |
| ADR-42 | low | 1 | ADR-42's central code fact — that `dynamic_return` gates on the receiver class only, never on the method name — was made false by ADR-52's `methods:` / `file_methods:` gates, so its canonical operator snippet hand-rolls a check the DSL now compiles into a registry name gate |
| ADR-45 | low | 1 | ADR-45 still says Rigor does not build a cross-file dependency graph and defers per-file caching, which ADR-46 shipped |
| ADR-48 | low | 1 | The fold-pipeline section routes Data folding through `ShapeDispatch::RECEIVER_HANDLERS` entries that were never built; the shipped code is a standalone `DataFolding` tier |
| ADR-50 | low | 1 | WD6 says `ci.yml` "now also triggers on `release/**`"; it deliberately does not, and the workflow that repeats the claim contradicts its own sibling |
| ADR-50 | low | 1 | WD4 specifies the perf gate over Mastodon / Redmine / GitLab subsets; the committed gate measures only Rigor's own `lib`, and no OSS corpus is measured for perf at all |
| ADR-51 | low | 1 | Status header and index row say "partially implemented" although every WD1–WD7 item, plus the WD6 templates/skill/manual, shipped in v0.1.18 |
| ADR-51 | low | 1 | Two code anchors name things that do not exist under that name: `Rigor::CLI::CiDetector` and `write_result` in `lib/rigor/cli.rb` |
| ADR-52 | low | 1 | WD1 and the rigor-sorbet migration record describe the compiled table and the DSL in terms of `type_specifier` / `type_specifiers`, a verb and reader removed in 0.3.0 by ADR-80 |
| ADR-52 | low | 1 | The dispatch-table design cites `flow_overridden?` as the live exemplar of the `Method#owner` trick; that predicate went with the hook ADR-52 itself removed |
| ADR-55 | low | 1 | The "memoized cross-call summaries" deferral row was overtaken: an arg-type-signature-keyed return memo shipped as the ADR-57 follow-up and was re-scoped by ADR-84 |
| ADR-55 | low | 1 | ADR-55 assigned two documentation updates on landing; the spec table was updated and the ADR-41 WD5 status flip it also named never happened |
| ADR-57 | low | 1 | Status header still stops at 2026-06-13 and omits WD3 (2026-07-10) — the exact touch-up the 2026-07-11 docs audit recommended, still unapplied |
| ADR-59 | low | 1 | WD4 claims the Pillar-2 retraction markers live in the ROADMAP, a file ADR-98 deleted in 2026-07 |
| ADR-60 | low | 1 | WD3's GlobEntry description (SHA-256 over content digests, one content re-digest per validate) was replaced by ADR-87 WD2's stat-tuple signature, with no forward pointer from ADR-60 |
| ADR-67 | low | 1 | ADR-67's body still states in the present tense that `parameter_inference:` + `--incremental` is a hard refusal, and the Status header never records the lift the README row does |
| ADR-67 | low | 1 | ADR-67 still advertises WD2 as "the cheap first step" that "may proceed independently and earlier", contradicting its own measured verdict that WD2 is blocked on a missing carrier and does not pay |
| ADR-69 | low | 1 | ADR-69's title and index row name an "operator seam" the ADR neither added nor documents; the second seam it actually shipped is the site selector, and the operator seam predates it by three days |
| ADR-73 | low | 1 | ADR-73's field-trial follow-up still lists the broken-`sig/` blind spot as a "clear-win, queued" item after both halves shipped |
| ADR-74 | low | 1 | The ADR credits a `waza check` spec gate for holding skill `description:` frontmatter inside the agentskills.io 1024-character cap; no such gate exists in the repo |
| ADR-75 | low | 1 | The Consequences bullet puts the origin side-table at the `FallbackTracer` choke point, which WD1 of the same ADR explicitly rejects |
| ADR-79 | low | 1 | ADR-79 anchors the rbs version range to `rigor.gemspec:50`, a file that has not existed since the gem was renamed to `rigortype` |
| ADR-82 | low | 1 | The Consequences bullet still flags a stale `bench/baseline.json` as an open follow-up; it has been recalibrated three times since |
| ADR-84 | low | 1 | ADR-84 WD7 says it removed a `--budget-trace` column, but no such CLI flag has ever existed — the surface is the `RIGOR_BUDGET_TRACE` env var |
| ADR-85 | low | 1 | WD3's deref-site inventory ("Three sites", "all other consumers read table structure") missed a fourth resolve site added the day after the ADR landed |
| ADR-90 | low | 1 | ADR-90's Status header and index row account only for WD1-WD3; WD4 (setting the bundle root before any plugin code runs) shipped in the same commit |
| ADR-97 | low | 1 | `rigor-adr-author` § 4c — the conforming-author surface ADR-97 WD4 relies on — still sends a new premise entry to `CLAUDE.md`, which carries no ADR list |
| ADR-98 | low | 1 | WD1 prescribes assigning issues to the `v0.3.0` / `v1.0.0` Milestones, but live release planning runs on `v0.3.x` / `v0.4.x`; every milestone including three shipped releases is still open, and two live issues sit parked in the shipped v0.3.6 milestone |
| ADR-99 | low | 1 | The "Warn on unknown top-level keys" row is still marked Deferred and blocked on ADR-99, but #166 closed and the warning shipped the same day the ADR landed |
| ADR-107 | low | 1 | ADR-107's § Gates "State" column and its Carry-over line still present landed work as pending, and the Carry-over cites a section title the note does not have |
| ADR-109 | low | 1 | WD2 names a resolver entry point `Resolver#try_range_head_builder` that has never existed under that name |
| ADR-110 | low | 1 | The closing paragraph calls #837 and #839 "two open issues"; both were closed as COMPLETED before the ADR's last edit |
