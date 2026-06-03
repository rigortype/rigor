# Dead code / coverage sweep — 2026-06-03

## Motivation

Internal-optimisation theme for the next version. First step: verify
the codebase has no unexercised dead code by running a line-coverage
sweep and inspecting every file below 80%.

## Method

Added `COVERAGE=1` instrumentation to `spec/spec_helper.rb` using
Ruby's built-in `Coverage` module (no extra gem; native extensions
already in the Flake). Running `COVERAGE=1 bundle exec rspec` inside
the Nix shell produces `coverage_report.txt` sorted by ascending
coverage ratio.

Full suite: **5 376 examples, 0 failures** at the time of the sweep.

## Files below 80% and their verdicts

| File | Coverage | Verdict |
|---|---|---|
| `rigor/mcp/loop.rb` | 38.1% | **Test gap** — no spec existed |
| `rigor/plugin/box.rb` | 52.9% | **Environment-gated** (`RUBY_BOX=1`, ADR-39) |
| `rigor/testing.rb` | 66.7% | **Test gap** — `Rigor.dump_type` / `assert_type` convenience aliases uncovered |
| `rigor/cli.rb` | 72.5% | Subcommand paths exercised via integration; residual gaps are I/O error branches |
| `rigor/inference/precision_scanner.rb` | 74.2% | **Test gap** — `FileResult` helpers and Union/Intersection/Difference classification branches |
| `rigor/plugin/isolation.rb` | 75.0% | **Environment-gated** (`ruby_box` strategy needs `RUBY_BOX=1`); `fork`-based paths covered by existing spec |
| `rigor/plugin/io_boundary.rb` | 77.2% | **Intentional boundary** — `DefaultHttpClient` uses real `Net::HTTP`; tests inject a fake client |
| `rigor/mcp/server.rb` | 77.6% | **Test gap** — `rigor_triage` and `rigor_coverage` tool calls untested |
| `rigor/language_server/server.rb` | 79.3% | LSP paths exercised via runner; residual = error-path branches |

## Dead code found

**None.**

Every low-coverage file had an identifiable, non-dead reason:
environment-gated feature flag, intentional I/O boundary, or a test
that simply had not been written yet.

## Tests added (commit 9fae4cba)

| New / updated spec | What it covers |
|---|---|
| `spec/rigor/mcp/loop_spec.rb` *(new)* | Normal dispatch, JSON-parse-error recovery, blank-line skip, notification (nil → no write), multi-request sequence |
| `spec/rigor/testing_spec.rb` *(new)* | `Rigor::Testing.dump_type` / `assert_type`, and the `Rigor.dump_type` / `Rigor.assert_type` delegate aliases |
| `spec/rigor/inference/precision_scanner_spec.rb` *(extended)* | `FileResult` ratio helpers (edge cases incl. zero-total), `dynamic_count`, Union/Intersection classification |
| `spec/rigor/mcp/server_spec.rb` *(extended)* | `rigor_triage` round-trip, `rigor_coverage` round-trip, `--top=` and `--params=` argv threading |

Suite after: **5 402 examples, 0 failures**.
