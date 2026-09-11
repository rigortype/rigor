# rigor-survey OSS corpus — v0.3.9 pre-cut crash check

Status: research note, no design commitments. Taken 2026-09-12 against **Rigor 0.3.9** (the
`release/0.3.9` checkout, `exe/rigor` run from the tree). Corpus: the 34 projects under
`/Users/megurine/repo/ruby/rigor-survey` — the OSS targets the analyzer is gated on (Mastodon,
Redmine, GitLab FOSS) plus the wider library set.

## Question

A green `make verify` says nothing about the analyzer meeting a real codebase for the first time.
This is a pre-cut smoke pass over the whole survey corpus: does 0.3.9 **crash** anywhere — an
`internal analyzer error`, a fatal abort, an RBS environment build failure, a plugin exception, or
an exit status outside the two an ordinary run uses?

## Method

Every project was analysed with `exe/rigor` from the `release/0.3.9` tree, inside the Nix Flake with
`BUNDLE_GEMFILE=<rigor>/Gemfile`, so the bundled plugins load from the checkout.

- **Battery 1 — `check`**: `check --no-baseline --no-ci-detect`, twice per project — cold
  (`--clear-cache`) then warm (cache read). `--no-baseline` keeps any stale baseline bucket from
  silencing a crash row. 34 projects × 2 = **68 runs**.
- **Battery 2 — the other analysis commands**: `triage --format json`, `coverage`, `unused`,
  `sig-gen --print`, `doctor`, `plugins`, and `annotate` on a representative file. 34 × 7 =
  **238 runs**.

Crash signals scanned out of both streams: `internal analyzer error`, `rigor: analysis aborted`,
`SystemStackError` / `NoMemoryError`, `rbs.coverage.{environment,definition,hkt}-failed`, a plugin
`runtime-error`, a `lib/rigor/*:in` backtrace frame, and any exit status outside `{0, 1}` (a fatal
run is 70; a killed one is 124/128+).

## Result: no crash in 306 runs

Both batteries are empty of every signal above. `check` exited 0/1 on all 68 passes; the seven
Battery-2 commands stayed inside their expected set on all 238; cold and warm agree.

The projection numbers worth recording (the four largest targets):

| target | files | cold | warm | cold peak RSS |
| --- | --: | --: | --: | --: |
| GitLab (`app`+`lib`) | 11,344 | 487.9 s | 1 s (cache hit) | 6.9 GB |
| rails (component `lib`s) | 1,445 | 17.7 s | <1 s | 910 MB |
| Mastodon (`app`+`lib`) | 1,325 | 15.5 s | 1 s | 802 MB |
| Redmine (`app`+`lib`) | 347 | 11.6 s | <1 s | 425 MB |

GitLab's cold and warm `check` outputs are byte-identical, and the warm pass is a one-second ADR-87
WD4 run-cache hit — the cache served the same diagnostic set it wrote, not a manufactured one.
GitLab's cold run fell from 2321 s (the July measurement, then-`app`+`lib`) to 488 s here; the
target file count is the same 11,344.

## Non-crash non-zero exits

`rigor coverage` is a documented non-zero-on-parse-error command, and five targets exit 1 through it:
`jbuilder` and `redmine` on their Rails-generator ERB templates (`templates/*.rb`, ERB parsed as
Ruby — the pre-existing corpus artifact recorded in
[the OSS library survey](20260519-oss-library-survey.md)), and the three bulk exercise repos
(`Algorithms-and-Data-Structures-in-Ruby`, `Data-Structures-and-Algorithms-in-Ruby`, `Ruby`) whose
teaching snippets include genuinely invalid Ruby. Parse errors in the target, not crashes.

## An environment trap, not a Rigor finding

Battery 2's first attempt ran every project under a single `nix develop` shell. Partway through, a
Nix store GC removed the dev-shell closure; command lookup fell through to a host Homebrew Ruby
4.0.6, and 49 runs died at `require` time on a native-extension ABI mismatch (`linked to
incompatible ... libruby-4.0.5`). Re-running each project in its own fresh `nix develop`, behind a
preflight that refuses a `ruby` outside `/nix/store`, cleared all of it. Battery 1 had already
finished before the GC and was unaffected — none of its outputs carries a backtrace frame. A
host-ruby ABI mismatch is not a Rigor result; it is why the harness now pins the interpreter.

## Coverage boundary

Swept: `check` (cold + warm) and the seven Battery-2 commands. Not swept: `--incremental` /
`--verify-incremental` and editor mode, `effects`, `type-of` / `type-scan` / `trace`, `sig-gen
--write`, `diff` / `baseline`, `init`, and the `lsp` / `mcp` stdio servers. "No crash" is a
statement about the swept surface on these 34 targets, not a proof about the analyzer.

## Reproducing

The drivers and raw output live outside the tree, under
`/Users/megurine/repo/ruby/rigor-survey/_reports/crashcheck-0.3.9/`: `driver.sh` + `extract.rb`
(Battery 1), and `driver2.sh` / `driver2b.sh` / `one_project.sh` / `extract2.rb` (Battery 2), with
per-run stdout / stderr / exit status under `run/` and `run2/`.
