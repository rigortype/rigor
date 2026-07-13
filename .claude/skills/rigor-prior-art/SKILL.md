---
name: rigor-prior-art
description: >-
  Search Rigor's own research corpus — docs/adr, docs/notes, docs/design,
  CHANGELOG.md + docs/CHANGELOG-0.1.x.md, handbook/manual — for prior
  evaluations, surveys, measurements, comparisons, and decisions, and report
  them with citation-grade file:line evidence. Use whenever the user asks
  "have we evaluated / measured / compared X before?", "過去に調査・評価した
  ことある?", "既存のノート/ADRから探して", "what do our docs say about X",
  or needs primary-source backing for a talk, blog post, ADR, or README claim
  — especially comparisons against other tools (Steep, Sorbet, TypeProf,
  rbs_rails, Tapioca, PHPStan, …). Also use before publishing any comparative
  claim about Rigor, to check what the corpus actually supports. NOT for a
  single fact in a file you already know (just rg/Read it directly).
---

# rigor-prior-art — corpus archaeology with citation-grade output

The rigor repository accumulates evidence across 80+ ADRs, 100+ research
notes, two CHANGELOGs, a handbook, and a manual. Answering "what do we
already know about X?" is a recurring task whose cost is dominated by two
things this skill freezes: **knowing where each kind of evidence lives**, and
**the discipline that keeps citations accurate**. The stakes are asymmetric —
a published overclaim ("Steep misses X", "we measured Y") gets challenged by
experts and costs credibility, so a finding you cannot pin to a file and line
is not a finding.

## When NOT to use this

A single fact in a file you already know → just `Read`/`rg` it directly.
This skill is for **topic-level sweeps** ("everything the corpus says about
X") and for **claims that need verified citations** before they leave the
repo (talks, comparisons, READMEs).

## Corpus map — where evidence lives

| Location | What lives there | When to look |
| --- | --- | --- |
| `CLAUDE.md` ADR bullet list | One dense paragraph per ADR, *including outcomes and numbers*. | **First stop.** Often answers the question without opening a single file. |
| `docs/adr/README.md` | Canonical ADR index (title + implementation status). | Confirming an ADR's current status. |
| `docs/notes/README.md` | Categorized note index: library surveys / coverage audits / regression sweeps / teeth / outside-research reviews / perf / meta. | Shortlisting notes by category. |
| `docs/adr/*.md` | Full decisions: criteria, rejected alternatives, gate results. | The "why" behind a behaviour; what was *rejected* and why. |
| `docs/notes/*.md` | What was observed, when, against which Rigor version. | Measurements, sweeps, adjudications. |
| `docs/CHANGELOG-0.1.x.md` + `CHANGELOG.md` | Per-feature landing narratives with spec/corpus evidence. | **Comparative evidence often lives ONLY here** — e.g. the `rbs_rails` coverage comparison and the ~20-methods-per-column contrast are in the 0.1.x archive, indexed nowhere else. Always include both files in a sweep. |
| `docs/design/*.md` | Design plans that preceded ADRs. | Pre-decision context, roadmaps. |
| `docs/handbook/`, `docs/manual/` | User-facing claims. | What Rigor *promises publicly* — the bar a new claim must clear. |
| `docs/notes/deep-research/` | **External** LLM deep-research reports stored for reference. | Community/competitor landscape only — never a first-party claim (register rules in [its README](../../../docs/notes/deep-research/README.md)). |
| `references/` submodules | Vendored upstream source (read-only). | Verifying a claim about *another* tool's code. |
| `git log -S"term"` | When a claim or feature landed. | Dating evidence; finding the landing commit. |

## Source taxonomy — classify every hit

1. **First-party evaluation** — Rigor ran / measured / compared something
   (a note's sweep table, a CHANGELOG gate result, an ADR's corpus numbers).
   Only this class supports "Rigor's docs say…" / "we measured…".
2. **External material** — `docs/notes/deep-research/`, quoted blog posts,
   `references/` submodules. Report as "surveyed community knowledge", never
   as Rigor's own claim. Deep-research reports carry citation markers
   (`[5]`) that look authoritative but their references can be synthetic,
   and they are known to contain factual errors about Rigor itself (e.g.
   attributing the rigor-rs Rust port's internals — ruby-prism, bumpalo — to
   Rigor proper).
3. **Mere mention / bibliography URL** — a name-drop or a citation-list
   entry. Not evidence; exclude or mark as such.

Labelling the class is what lets the user decide what register a claim can
carry downstream — do not collapse the three into one list.

## Method

1. **Indexes first.** Skim the `CLAUDE.md` ADR bullets and the two READMEs
   for the topic. This is cheap and frequently sufficient to shortlist 2–5
   candidate documents — or to answer outright.
2. **Expand terms before searching.** Name variants (`rbs_rails` /
   `rbs-rails`), English *and* Japanese vocabulary (型定義 / 生成 /
   メンテナンス / 陳腐化 …), tool aliases, and the *adjacent* tools a
   comparison would name (searching for `rbs_rails` should also sweep
   `Tapioca`, `gem_rbs_collection`, `orthoses`).
3. **Sweep.** For a broad multi-tool/multi-theme sweep, or when the main
   conversation's context is worth protecting, fill in
   [references/explore-prompt-template.md](references/explore-prompt-template.md)
   and hand it to one Explore subagent — the template encodes the location
   list, adjudication criteria, and output format, so don't rewrite it from
   scratch. For a narrow single-topic lookup, run the same sweep yourself
   with `rg` over the template's location list — a subagent round-trip adds
   minutes of latency that a focused inline sweep doesn't need.
4. **Verify before citing.** For every quote that will appear in your
   report, re-read the raw bytes: `grep -n "<fragment>" <file> | cat -v`.
   Subagent echoes can silently mangle proper nouns; a citation you did not
   verify against the file is a liability, not evidence.
5. **Report per the output contract** below.

## Output contract

- **Per finding:** `file:line` (repo-relative, clickable), a verbatim quote
  or tight paraphrase, its source class, and the tool/theme it bears on.
- **Organize by tool or theme**, not by file — the user is answering a
  question, not auditing a directory.
- **State what was NOT found.** Absence is a result: "no side-by-side
  numeric Rigor-vs-Steep run exists in the corpus" prevents the exact
  overclaim the search was meant to protect against.
- **Time-stamp caveat where it matters.** Notes are non-normative snapshots
  ("what was true when written, against the Rigor version named inside") —
  when a finding names a file, flag, or method, note whether it still exists
  if the user is about to rely on it.

## Pitfalls

- **Archived CHANGELOGs are the evidence trove.** Landing narratives hold
  the densest per-feature comparative evidence, and an archived changelog
  drops out of casual view (current instance: `docs/CHANGELOG-0.1.x.md`;
  each future `CHANGELOG-0.x` archive joins it). A sweep that skips them
  misses decisive material.
- **ADR supersedes note.** An ADR's status line is updated in place; the
  note that spawned it is frozen. For "what is true now" prefer the ADR
  status; for "what was measured then" cite the note.
- **rigor ≠ rigor-rs.** The Rust port makes opposite design choices
  (vendored RBS, single binary). External material conflates them.
- **"Evaluated" ≠ "mentioned".** A tool appearing in a comparison table
  someone imported is not Rigor having evaluated it — that is what the
  taxonomy is for.
