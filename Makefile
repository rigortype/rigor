.PHONY: setup install init-git-config init-submodules pull-submodules doctor-submodules test test-binpacker test-ractor-pool lint check check-plugins check-incremental check-mutation-cache docs-check verify verify-changed verify-quick verify-parallel check-json extract-builtin-catalogs catalog-diff steep-install steep-check steep cache-clean

REFERENCE_SUBMODULES := \
	references/rbs \
	references/ruby

setup: install init-git-config init-submodules

install:
	bundle install

init-git-config:
	@# Local-only safety defaults for this clone. Idempotent.
	@# Why: submodule.recurse=true on a parent operation amplifies any submodule
	@# breakage into a parent-side fatal. We disable recursion and instead drive
	@# submodule updates explicitly via `make init-submodules` / `make pull-submodules`.
	git config submodule.recurse false
	git config fetch.recurseSubmodules on-demand
	git config status.submoduleSummary true
	git config diff.submodule log
	git config push.recurseSubmodules check
	@echo "Local git submodule-safety config applied."

init-submodules:
	git submodule update --init --filter=blob:none references/rbs
	git submodule update --init --filter=blob:none references/ruby

pull-submodules: init-submodules
	git submodule update --remote --merge $(REFERENCE_SUBMODULES)

doctor-submodules:
	@bin/doctor-submodules

test:
	bundle exec rspec

# ADR-15 Phase 4b — runs `spec/rigor/analysis/runner_pool_spec.rb`
# as its own rspec process (excluded from the default suite via
# `spec/spec_helper.rb`). Since the fork-backend default (86ed9129)
# the file spawns no Ractors unless RIGOR_POOL_BACKEND=ractor is
# exported; the separate process is kept so that override can never
# destabilise the main suite (historical Bus Error via RBS
# C-extension state after Ractor cleanup). Part of `verify` and CI —
# a deterministic failure here once rotted unnoticed for three weeks
# because nothing ran this target automatically.
test-ractor-pool:
	RIGOR_INCLUDE_RACTOR_POOL=1 bundle exec rspec spec/rigor/analysis/runner_pool_spec.rb

# Plugin integration tests are excluded from the default suite because they modify global state (Test Pollution).
# Specifically, rigor-ffi re-opens Rigor::Plugin::Base to define DSL macros.
# Running them in a separate RSpec process avoids flaky failures in public_api_drift_spec.rb.
#
# The run also carries the ADR-128 WD4 plugin-boundary gate (RIGOR_PLUGIN_BOUNDARY, spec/support/plugin_boundary.rb): a
# TracePoint that fails the run when a bundled plugin calls past the plugin-facing interfaces. It roughly doubles the
# run. spec/integration/examples/ is excluded from the default suite the same way, because the gate covers examples/
# as well as plugins/. CI splits the run across jobs: PLUGIN_SHARD=I/N runs one deterministic slice of the files
# (tool/plugin_integration_shard.rb); unset, it runs them all.
#
# RIGOR_PLUGIN_BOUNDARY_REQUIRE_CALLS=1 makes the gate also fail a run that recorded no plugin->engine call. It is set
# here, for the whole run and each CI shard, because a run that recorded nothing would otherwise pass for want of
# anything to judge; the shard counts (25, 42, 58 calls) say a full run always records some, and that holds for CI's
# 3-way split. A much finer PLUGIN_SHARD can isolate an engine-silent spec, which then fails. A narrow run of one spec
# file, run through rspec directly, leaves the variable unset: an engine-silent plugin spec legitimately records no call.
PLUGIN_SHARD ?=
test-integration-plugins:
	@files="$$(bundle exec ruby tool/plugin_integration_shard.rb $(PLUGIN_SHARD))" || exit 1; \
	[ -n "$$files" ] || { echo "tool/plugin_integration_shard.rb listed no spec files for PLUGIN_SHARD='$(PLUGIN_SHARD)'" >&2; exit 1; }; \
	RIGOR_PLUGIN_BOUNDARY=1 RIGOR_PLUGIN_BOUNDARY_REQUIRE_CALLS=1 RIGOR_INCLUDE_INTEGRATION_PLUGINS=1 bundle exec rspec $$files

# Spec suite via `binpacker`, distributing files across worker
# processes using LPT scheduling driven by measured per-file
# runtimes (tmp/binpacker.timings). On a cold start (no timings
# file) binpacker falls back to filesize weighting automatically.
# The ci profile additionally enables work stealing (dynamic
# rebalancing between workers) to absorb shared-runner noise.
# Worker count comes from `workers: auto` in binpacker.yml (CPU
# count); override it via the config profile.
#
# BINPACKER_FLAGS threads per-invocation arguments through without
# turning this target into a second CLI. CI's sharded matrix uses it for
# `--shard K/N --report …`; a local run leaves it empty and gets the
# whole suite.
BINPACKER_FLAGS ?=

# `mkdir -p tmp`: binpacker's timing writer mkpaths its own directory, but
# `Report#write` is a bare `File.write`, so `--report tmp/…` raises ENOENT when
# `tmp/` does not exist — and `tmp/` is gitignored, so it does not on a fresh
# checkout. In CI the directory existed only as a side effect of the timing
# cache restoring into it; the first real cache miss since sharding landed
# (bumping the key to v2) took the whole matrix down with every spec passing.
test-binpacker:
	@mkdir -p tmp
	bundle exec binpacker run $(BINPACKER_FLAGS)

lint:
	bundle exec rubocop lib/ spec/ plugins/ examples/ apps/

# `--no-cache`: the self-check is a verification gate and must never trust
# a cached result. The ADR-45 record-and-validate run cache serves an
# unchanged tree's previous result; the fingerprint excludes engine code
# (only `Rigor::VERSION`), so an engine edit at the same version could be
# masked by a stale hit. The gate always re-runs the analysis fresh.
#
# `--fail-on=warning` (issue #812): `rigor check`'s own exit code is
# `:error`-only, so a `:warning` (e.g. `def.return-type-mismatch`, #810)
# used to pass this gate and CI silently. Raising the bar here — rather
# than in `Result#success?` — keeps ordinary users' exit-code contract
# unchanged and makes only THIS self-check as strict as AGENTS.md claims.
check:
	bundle exec exe/rigor check --no-cache --no-ci-detect --fail-on=warning lib

# Self-check the bundled plugin / example LIB trees against the
# `Plugin::Base` contract. ADR-43 ancestor resolution makes a plugin's
# inherited contract calls (`manifest.…`, `io_boundary.…`) resolve, so
# `rigor check` warns on contract misuse here — this target is what
# turns that into a gate. Lib dirs only (the `demo/` trees deliberately
# exercise un-modelled framework DSLs and are not a clean target). MUST
# stay clean for the same reason `check` does: fix the cause, never
# disable the rule. `--fail-on=warning` for the same reason as `check`
# above (issue #812).
check-plugins:
	bundle exec exe/rigor check --no-cache --no-ci-detect --fail-on=warning plugins/*/lib examples/*/lib

# ADR-46 incremental-analysis acceptance gate. `--verify-incremental`
# runs a baseline analysis, re-analyzes a subset of files and serves the
# rest from the per-file cache, and asserts the merged diagnostics are
# byte-identical to a full `--no-cache` run. A mismatch means the
# incremental machinery would serve a stale — manufactured — diagnostic,
# the soundness failure the gate exists to catch. Deliberately NOT in
# `verify`: it runs ~3 analyses per target (baseline + subset + full), too
# slow for the local fast path. CI runs it (cold variant).
#
# `.rigor.gates.yml` keeps `parameter_inference:` off here: with it on the gate takes ~1.8x as long
# (#3324), and the incremental parameter-table path is covered on fixtures by
# `spec/rigor/analysis/incremental_session_spec.rb`.
check-incremental:
	bundle exec exe/rigor check --config .rigor.gates.yml --verify-incremental --no-stats lib
	bundle exec exe/rigor check --config .rigor.gates.yml --verify-incremental --no-stats plugins/*/lib examples/*/lib

# Issue #134 slice 3 — the same obligation for the per-file MUTATION-result
# cache: a warm `rigor coverage --protection --mutation --format json` run must
# be byte-identical to the cold one over a corpus, and must actually have served
# it from cache (the gate refuses a vacuous pass). Deliberately NOT in `verify`,
# for the same reason `check-incremental` is not: three whole measurement passes
# plus a snapshot warm-up. CI runs it on the cold self-check variant.
#
# The corpus is a bounded subtree with `--limit` rather than all of `lib`: the
# gate is about warm==cold, and a 350-file measurement would cost minutes per
# arm without making the equality any harder to violate. It writes an ADR-46
# snapshot for those roots, replacing any whole-project one in `.rigor/cache`.
check-mutation-cache:
	bundle exec ruby tool/mutation_cache_gate.rb --limit 5 lib/rigor/protection lib/rigor/cache

# Verify that docs/handbook/ executable snippets are accurate and that
# docs/handbook/ + docs/manual/ relative links and doc↔code references are
# consistent.  Runs spec/docs/ in isolation so failures are attributed
# clearly.  Already included in the `test` / `test-binpacker` suite; this
# target is the named gate for a focused docs-only run.
docs-check:
	bundle exec rspec spec/docs/

check-json:
	bundle exec exe/rigor check --format=json lib

# The self-typing ratchet (#3315): one `rigor coverage --format json lib` scan,
# run in-process by tool/coverage_ratchet.rb, holds two figures to the pins in
# tool/coverage_ratchet.yml — the precision ratio and the share of call sites
# whose result is Dynamic. It is one-sided: a figure WORSE than its pin by more
# than the slack fails (declare what the change left untyped in sig/, or move
# the pin through an approval-queue gate-row entry); a figure BETTER than its
# pin by more than the slack passes with a notice that prints the tighter pin
# lines. `make coverage-tighten` writes every gain into the pins file and never
# loosens one; a typing batch's PR runs it, and so does release prep. The tool
# refuses a run under another config, a summary without the call-site fields,
# a scan under the floors, and a move past `max_step` either way.
#
# This replaced a one-sided `--threshold 0.58`, calibrated in 2026-08 with ~2
# points of slack against release-to-release drift; the #3290–#3319 series
# moved the ratio by 0.12 points, so it could not have caught a real loss.
#
# `.rigor.gates.yml` is the self-check configuration with `parameter_inference:`
# off: the key would triple the run (#3324: 101 s -> 307 s), and the pins are
# measured without it, so the ratchet does not see a regression in parameter
# inference itself. docs/agents/measurement.md § "The self-typing ratchet" says
# how to read and refresh the pins.
#
# Use `rigor coverage lib/` for a non-gating report.
coverage:
	bundle exec ruby tool/coverage_ratchet.rb --config .rigor.gates.yml lib

coverage-tighten:
	bundle exec ruby tool/coverage_ratchet.rb --config .rigor.gates.yml --tighten lib

# ADR-50 WD4 perf-regression gate. Runs this checkout's `rigor check
# --no-cache` in-process over `lib` of the frozen corpus bench/baseline.json
# names (the previous release's tag, `git archive`d to a scratch directory;
# #1507), measures wall / allocations / peak-RSS, and gates against
# bench/baseline.json within bench/thresholds.yml. Every run writes a
# suggested baseline (bench/baseline.updated.json, gitignored); a
# recalibration commits a Linux CI run's copy of it (bench/README.md). An
# uncalibrated baseline passes, once its corpus tag resolves. Deliberately
# NOT in `verify` (a full analysis under measurement is slow); the release
# gate runs it.
# Named `bench-perf` (not `bench`) so the target does not collide with the
# `bench/` data directory — keeping the file's no-`.PHONY` convention and
# its `check-*` / `test-*` hyphenated-target family.
#
# Still ONE command, but no longer one analysis: since #987 the script reps
# each target `--reps` times (default 2), every rep in a fresh child process,
# and gates on the LOWER of the reps for the noisy `wall_s` / `peak_rss_kb`
# axes. Budget roughly N× the old runtime. `BENCH_ARGS` appends to the
# invocation, so `make bench-perf BENCH_ARGS="--reps 1"` restores the old
# cost for a quick local look (and the old single-sample noise with it).
# The release gate runs the target bare, i.e. at the committed default.
BENCH_ARGS ?=
bench-perf:
	bundle exec ruby tool/bench.rb --target lib $(BENCH_ARGS)

# ADR-103 WD13 / #409 effect-collection cost budget. Interleaved A/B of
# `rigor check` with and without `effects:` over an external corpus target,
# reporting median wall / peak-RSS deltas against the ~5% bound. Advisory,
# and like `bench-perf` deliberately NOT in `verify`. The authoritative host
# is Linux CI (peak RSS reads from /proc, and a laptop shares its cores with
# a browser) — `.github/workflows/oss-sweep.yml` runs it against the pinned
# Mastodon. Locally: make effect-budget TARGET=~/repo/ruby/rigor-survey/redmine \
#   BASE_CONFIG=/tmp/redmine-base.yml
effect-budget:
	bundle exec ruby tool/effect_budget.rb --target $(TARGET) --base-config $(BASE_CONFIG)

# `verify` chains the spec suite, the gated pool-runner spec (its
# own rspec process — see `test-ractor-pool`), rubocop, `rigor check
# lib`, and the plugin-tree contract check. The spec phase runs via
# binpacker (LPT scheduling, `workers: auto`) — 3-4× faster on
# multi-core hosts than the sequential rspec invocation. `lint` is
# already process-parallel via rubocop's built-in worker pool;
# `check` / `check-plugins` are short rigor invocations.
#
# Total wall time on a 4-worker laptop: ~60s (vs ~200s for the
# sequential variant below). Use `verify-sequential` when chasing
# parallel-only flakes — the worker isolation hides certain
# ordering bugs that surface only in a single-process run.
verify: test-binpacker test-ractor-pool test-integration-plugins lint check check-plugins

# Sequential variant. Identical phases as `verify` but `test`
# runs single-process. Slower but bit-for-bit reproducible
# without inter-worker scheduling effects.
verify-sequential: test test-ractor-pool test-integration-plugins lint check check-plugins

# The local pre-push gate: `git diff --check`, RuboCop, the affected specs,
# `spec/docs/` and `rigor check` — each over only what the branch changed since
# its merge base with origin/master (override with VERIFY_BASE=<ref>). 20-40s
# for a small branch, where `verify` runs the whole suite and contends for the
# host with every parallel session running it. It cannot see a regression in an untouched file, so the
# full gate stays the PR's full CI run (at gh pr ready); see bin/verify-changed.
verify-changed:
	@bin/verify-changed

# The edit-loop tier of verify-changed: the directly selected specs only, in
# seconds. It skips the drift specs, pins, spec/docs/ and the self-check, so it
# is not the pre-push gate; run `make verify-changed` before pushing.
verify-quick:
	@bin/verify-changed --quick

# Backward-compatible alias for the previous `verify-parallel`
# target name. Identical to `verify` now that parallel is the
# default.
verify-parallel: verify

extract-builtin-catalogs:
	bundle exec ruby tool/extract_builtin_catalog.rb

# Compares two snapshots of a catalog YAML and prints the
# surface-level diff (added / removed / purity-changed /
# cfunc-renamed / arity-changed entries). Override BEFORE / AFTER
# to point at any two YAML files; the defaults assume the operator
# has stashed a baseline copy at /tmp/before.yml.
#
#   make catalog-diff BEFORE=/tmp/before.yml AFTER=data/builtins/ruby_core/time.yml
catalog-diff:
	@bundle exec ruby tool/catalog_diff.rb $(BEFORE) $(AFTER)

# Steep is installed under tool/steep/ as a separate Bundler so its
# dependency tree (rbs, prism, ...) cannot bleed into Rigor's own
# Gemfile.lock. Always invoke through BUNDLE_GEMFILE so bundler picks
# up tool/steep/.bundle/config (BUNDLE_PATH=vendor/bundle) instead of
# the root config.
STEEP_BUNDLE := BUNDLE_GEMFILE=tool/steep/Gemfile bundle

steep-install:
	$(STEEP_BUNDLE) install

steep-check:
	$(STEEP_BUNDLE) exec steep check

# Pass-through wrapper: `make steep ARGS="check --severity-level=error"`.
steep:
	$(STEEP_BUNDLE) exec steep $(ARGS)

# `.rigor/cache` grows monotonically by design (ADR-6 "no eviction").
# Each unique (configs, dependencies, files, gems, plugins)
# descriptor produces its own slot, so a long-lived clone with
# config churn can accumulate 100+ MiB of stale slices. `cache-clean`
# is the manual GC button. Use `bundle exec exe/rigor check
# --cache-stats lib` to inventory the per-slot footprint first.
cache-clean:
	rm -rf .rigor/cache
