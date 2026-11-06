# gem_rbs_collection audit — running `rigor check` and `sig-gen --diff` over 196 signature dirs

Status: field report, no design commitments. Taken with rigor 0.4.7 (mise install) on 2026-11-06
against a working checkout of `ruby/gem_rbs_collection`. The question: can Rigor add a second,
inference-based verification layer on top of the collection's existing `rbs validate` +
`steep check` + `check-untyped-call` pipeline — and what does it actually catch?

## Method

For each `gems/<name>/<version>` directory containing `_test/` (196 total):

- `rigor check` on the test scripts with `.rigor.yml` =
  `paths: ["."], signature_paths: [".."]` — the collection RBS is loaded directly,
  no `rbs collection` resolution. Gems with a `manifest.yaml` / gemspec dependency
  (e.g. sinatra → rack) need that dependency's collection dir added to
  `signature_paths` manually.
- `rigor sig-gen --diff --format=json` against the installed gem's `lib/` —
  the implementation as oracle for the hand-written RBS.

Harness: `bin/rigor_audit` (single dir) and `bin/rigor_audit_all` (batch, JSONL out,
resumable) in the gem_rbs_collection checkout. Aggregate data in `tmp/rigor_audit.jsonl`
(gitignored).

## `rigor check` results

130/196 clean, 42 errors across 19 gems, 198 warnings.

The errors split three ways — and only one class is Rigor's own problem:

1. **Rigor false positive — `def self.new:` ignored** (email_address/0.2, 14 errors).
   RBS declares `def self.new: (...) -> Address`; Rigor resolves `.new` through
   `initialize`/default-construction instead and types the receiver as the outer class.
   Minimal repro confirmed. Filed as <https://github.com/rigortype/rigor/issues/2884>.
   This is a load-bearing RBS idiom — a signature that overrides `new` to return a
   different class is exactly how factories are typed in the collection.

2. **Real RBS bug, Rigor correct** (retryable/3.0, 4 errors). The `options` record
   type declared all ten keys as *required* (`contexts:`, `ensure:`, … — no `?`
   key markers, only nilable value types). `Retryable.retryable({ sleep: 3.2 })`
   genuinely omits nine required keys. Steep accepted the call because the
   failing sites are *positional Hash arguments* against a closed record, not
   because its keyword path is lenient (the keywords were already `?sleep:`).
   Rigor's check is right per RBS record semantics. The collection fix is not
   "make every key optional on the same alias": `options` is also the return of
   `#to_hash` / `#merge`, which always emit all ten keys. Split into
   `option_overrides` (input, optional keys, non-nil values) and `options`
   (output, required keys, non-nil values). Nilable values (`sleep?`) were a
   separate inaccuracy — `Kernel.sleep(nil)` raises; present keys are never nil.
   ruby/gem_rbs_collection#1126.

3. **Intentional errors** (protobuf/3.10.3, 4 errors): `___error___` is the
   marker the steep side uses for expected-failure assertions. A CI gate would
   baseline these.

Warnings are dominated by `call.unresolved-toplevel` on DSL/instance_eval blocks
(actionpack 56, simplecov 18, moneta, slack-notifier) — expected, `--fail-on=error`
is the right gate. One `rbs.coverage.definition-build-failed` class matters:
abbrev/0.1's collection RBS **collides with Rigor's bundled stdlib RBS**
(`DuplicatedMethodDefinitionError`) — packaging a default-gem signature in the
collection has an interaction no other tool surfaces.

## `sig-gen --diff` results (189 gems)

| classification | total | reading |
| --- | ---: | --- |
| `new_method` | 27,316 | public methods missing from collection RBS (stripe/20.0: 9,613) |
| `tighter_return` | 2,736 | provably-tighter returns than declared (activerecord/8.1: 374, mail/2.8: 107) |
| `skipped` | 97,211 | mostly `sig.skipped.untyped-return` — ADR-5 declines to propose `untyped` |

`tighter_return` is the actionable stream: near-zero-noise tightening candidates,
human-reviewed then applied one PR at a time. `new_method` is a coverage metric,
not a gate — the collection intentionally types the main API first. `bot` proposals
surface on abstract methods that always raise and need review, not blind application.

## What this says about Rigor

- The second inference engine earns its keep: it caught a real spec-level RBS bug
  (retryable required keys) that steep's own check had been green on for years.
- Two friction points for this exact use-case: `def self.new:` (#2884) and
  bundled-stdlib collision for default gems packaged in the collection.
- `signature_paths` composition per `_test` dir is workable but wants dependency
  expansion (read `manifest.yaml` / the gemspec) to scale beyond hand-picked gems.
- `--fail-on=error` + a small baseline is sufficient for a collection CI lane;
  warning-level DSL noise is expected and stays visible, not blocking.

## Follow-ups

- Filed: rigortype/rigor#2884 (`def self.new:` return type ignored).
- Fix PR in gem_rbs_collection: retryable/3.0 split `option_overrides` / `options`
  (ruby/gem_rbs_collection#1126).
- If adopted: extend `bin/rigor_audit_all` to resolve dependency RBS via
  `rbs_collection.yaml`-equivalent resolution, and rank gems by `new_method`
  coverage for reviewer prioritisation.
