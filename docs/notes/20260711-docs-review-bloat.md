# Docs review — L3 簡 bloat detector (INVERTED)

Lens: flag **fat only** (duplication, non-goal violations, prose-that-wants-a-table,
within-chapter redundancy). Never flags thin prose; never recommends adding material.
Primary criterion: the README-declared split — **type model → handbook, operation →
manual** — so the highest-value finding is content that appears in BOTH corpora.

Scope read: all `docs/manual/*.md` + `docs/handbook/*.md` (paired-chapter deep read;
operations-only manual chapters 09–13 and handbook carrier chapters 02–06 confirmed to
have no cross-corpus twin).

## Findings — manual ↔ handbook overlap (lead)

| Location(s) | Why it's fat (criterion) | Severity | Proposed cut / owning side |
| --- | --- | --- | --- |
| **Manual `04-diagnostics.md` ↔ Handbook `08-understanding-errors.md`** — the whole operational apparatus is specified twice. Rule catalogue: manual:37–58 (`\| Rule \| Fires when \| Evidence \|`) vs handbook:67–132 (per-family `\| Rule \| Fires when \| Default severity \|`). Severity profiles: manual:88–92 vs handbook:143–147 (near-verbatim three-row table). `severity_overrides:` + family-precedence: manual:94–104 vs handbook:155–186. Suppression (in-source / file-scope / project-wide): manual:182–209 vs handbook:188–236. `evidence_tier` / `documentation_url`: manual:63–80,125–126 vs handbook:37–58. | #1 manual↔handbook overlap: the same rule IDs, severity mechanics, and suppression *syntax* are the operational reference → manual, restated in full in the handbook. The manual's own header (04:6–8) says "for the *reasoning* see handbook 8" — but handbook 8 is not just reasoning, it re-specifies every operational table. | ERROR | **Manual owns** the rule-ID catalogue, the severity-profile table, `severity_overrides:` mechanics, and the three suppression forms. **Handbook cuts** the duplicated profile table, the `severity_overrides:` YAML mechanics, the file-scope/project-wide suppression syntax, and the `evidence_tier` field spec — replace with a one-line cross-link to `manual/04`. Handbook **keeps** what is genuinely type-model reasoning: "Anatomy of a diagnostic" (08:8–34), "Why a diagnostic might NOT fire" (08:281–317), "Why a diagnostic IS firing" (08:319–339), and the adoption workflow (08:341–360). |
| **Handbook `08-understanding-errors.md`:238–279 "Baseline diffing for CI"** ↔ **Manual `06-baseline.md` (whole file)**. The handbook section teaches `rigor diff`, the `rigor check --format=json > baseline.json` workflow, and the managed `.rigor-baseline.yml` / `baseline:` key — all operational. | Handbook non-goal violation + manual↔handbook overlap: baselines are pure "how to operate" → manual owns them (`06-baseline.md` covers exactly this). A type-model chapter should not carry a CI baseline workflow. | ERROR | **Cut** 08:238–279 from the handbook down to a one-sentence pointer to `manual/06-baseline.md`. **Manual `06` owns** baselines. |
| **Manual `16-rbs-extended-annotations.md`:37–46 ↔ Handbook `07-rbs-and-extended.md`:107–113** — the per-method directive grammar table appears in both. And **Manual `16`:116–137 ↔ Handbook `07`:140–162** — the `conforms-to` semantics are near-verbatim in both ("Multiple `conforms-to` directives … combine like an intersection of interfaces. The directive is purely additive…"). | manual↔handbook overlap: the normative directive *grammar* and `conforms-to` *semantics* are reference material → manual (and the spec). The handbook legitimately teaches with worked examples, but should not also carry the full grammar table + semantic prose. | MISLEADING | **Manual `16` owns** the directive grammar table and the `conforms-to` semantic paragraph (both cross-declare to `type-specification/rbs-extended.md` as normative). **Handbook `07` keeps** its worked examples (assertion gate, predicate, param override) but replaces the standalone grammar table + duplicated `conforms-to` prose with a cross-link. Lower severity than the 04/08 pair because the two are framed differently (reference vs walkthrough) and already cross-declare. |
| **Handbook `09-plugins.md` (245 lines) vs its own charter.** The handbook README:271–272 states "It does **not** cover plugin authoring — that is the job of `examples/`. Chapter 9 is a one-page pointer." Chapter 9 instead specifies the full five-surface plugin *contract* (09:61–106), the macro-expansion substrate with its Tier A/B/C manifest-declaration table (09:108–198: `block_as_methods:`, `trait_registries:`, `heredoc_templates:`), and the substrate-vs-walker decision matrix. | Handbook non-goal violation: this is plugin-**authoring** reference (manifest field names, contract surfaces) that the README assigns to `examples/`. Also overlaps Manual `07-plugins.md` on the `plugins/` vs `examples/` distinction (09:8–14 vs 07:59–65). | ERROR | **Cut** the plugin-contract surface list (09:61–106) and the macro-substrate tier tables (09:108–198) down to a pointer to `examples/README.md`. **Keep** the decision guidance ("When you reach for a plugin", "Should you write one?"). Authoring detail is owned by `examples/`; activation is owned by `manual/07`. |

## Findings — within-handbook redundancy

| Location(s) | Why it's fat (criterion) | Severity | Proposed cut |
| --- | --- | --- | --- |
| **Handbook `07-rbs-and-extended.md`:346–412 "Coming from PHPStan? The `@phpstan-assert` family"** ↔ **Handbook `appendix-phpstan.md`:72–84 "The `@phpstan-assert` family"**. The same `@phpstan-assert*` → `%a{rigor:v1:…}` mapping table and the same "assertNotNull" worked example appear in both. | Within-handbook redundancy (criterion 4): the handbook has a dedicated *"Coming from PHPStan"* appendix that exists precisely to own this comparison. Chapter 7 embedding a full PHPStan section with its own mapping table duplicates the appendix. | FRICTION | **Cut** 07:346–412 to a one-line cross-link to `appendix-phpstan.md`. The appendix owns cross-tool comparison. |

## Findings — borderline / low-severity

| Location(s) | Why | Severity | Proposed action |
| --- | --- | --- | --- |
| **Handbook `01-getting-started.md`:15–67 "Installing Rigor" ↔ Manual `01-installation.md`.** Same "Rigor is a tool, not a library / Do not add it to your `Gemfile`" framing, the same AI-agent install prompt, and the `mise use ruby@4.0` / `mise use gem:rigortype` commands appear in both. Handbook `01`:283–299 also echoes the `rigor init` YAML that Manual `03-configuration.md` owns. | A short getting-started orientation recap is explicitly allowed by the guardrails, and handbook `01` cross-links to manual `01`/`03` for the full detail. But the duplication is more than a recap — full framing + prompt + config YAML. | nitpick | Acceptable as intentional recap. If trimming: shorten the handbook install section to the two `mise` commands + the "tool not a library" one-liner + link; drop the full `rigor init` YAML echo (01:283–299) in favour of the existing link to `manual/03`. Do **not** cut the "no annotations" stance or escape-hatch list — those are type-model content the handbook rightly owns. |

## Not flagged (guardrail check — density is correct here)

- **Manual `15-type-protection-coverage.md`, `17-driving-improvement.md`** — dense operational reference with no handbook twin. Doing the manual's job; the tier tables and flag lists are correct reference density, not bloat.
- **Manual `05-inspecting-types.md`** — cleanly scoped; the handbook only carries the short `assert_type` *snippet convention* (README:213–233), a legitimate orientation note, not a duplicate of this reference.
- **Manual `02` CLI reference, `03` config, `06` baseline, `11` CI** — reference tables; exhaustive by design.
- **Handbook appendices (Go / Rust / TypeScript / …)** — cross-language mapping is the handbook's declared job; no manual overlap.

## Verdict

The docs are **lean where the split is respected and fat exactly at the two corpus
seams that share a subject: diagnostics and plugins.** The dominant defect is a single
ERROR-class duplication — Manual 04 and Handbook 08 each independently specify the full
rule catalogue, severity profiles, `severity_overrides:` mechanics, and every
suppression form, plus a CI-baseline workflow the handbook has no business carrying.
Fold the *reference* (catalogue, severity mechanics, suppression syntax, baselines) onto
the manual and leave the handbook the *reasoning* (anatomy, why-it-fires-or-doesn't,
adoption workflow), and the largest fat pocket collapses. Handbook chapter 9's drift from
its own "one-page pointer" charter into full plugin-contract reference is the second
structural cut. Everything else is minor: a directive-grammar table shared between
Manual 16 and Handbook 7, a PHPStan section duplicated inside the handbook, and a
getting-started install recap that is a touch longer than a recap needs to be. No
load-bearing reference material is at risk from any proposed cut — every one either moves
a fact to its declared owner or replaces a duplicate with a cross-link. Overall the corpus
is well-disciplined; it just needs the diagnostics and plugins seams tightened.
