# Explore-subagent prompt template for corpus sweeps

Fill the `{…}` slots and pass the whole block as the Explore subagent's
prompt. Keep the adjudication and output-format sections verbatim — they are
what makes the result citable.

```
Search the repository at /Users/megurine/repo/ruby/rigor for any evaluation,
comparison, measurement, or decision concerning {TOPIC}, so the findings can
be cited with file:line accuracy.

Search these locations thoroughly:
- docs/notes/ (survey/research notes; docs/notes/README.md is the index)
- docs/adr/ (architecture decision records; docs/adr/README.md is the index)
- docs/design/
- docs/CHANGELOG-0.1.x.md and CHANGELOG.md  ← do not skip; per-feature
  landing narratives often hold comparative evidence indexed nowhere else
- docs/handbook/, docs/manual/, docs/type-specification/, docs/internal-spec/
- README.md, AGENTS.md, CLAUDE.md

Search for these terms (case-insensitive, ripgrep): {TERMS — include name
variants, English AND Japanese vocabulary, and adjacent tool names}.

For EACH distinct hit that is a genuine EVALUATION, MEASUREMENT, or DECISION
(not a passing mention or a bibliography URL), report:
1. The exact repo-relative file path and line number(s).
2. A short verbatim quote (or tight paraphrase) of what it claims —
   especially any comparative claim or number.
3. Its source class:
   (a) first-party — Rigor ran/measured/decided it;
   (b) external — docs/notes/deep-research/, quoted third-party material,
       references/ submodules;
   (c) mere mention / bibliography entry.
4. Which tool/theme it bears on.

Distinguish genuine evaluations from mere mentions. Organize findings by
tool and by theme ({THEMES — e.g. setup cost, maintenance/staleness, false
positives, runtime dependency, metaprogramming handling}). Explicitly list
what you did NOT find (e.g. "no numeric head-to-head comparison exists").

Do NOT edit any files — this is read-only research. Return a structured
report with file:line on every claim.
```

After the subagent returns: verify every quote you intend to surface against
the raw file bytes (`grep -n "<fragment>" <file> | cat -v`) before citing it
— echoed output can silently mangle proper nouns.
