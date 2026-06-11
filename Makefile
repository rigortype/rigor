.PHONY: setup install init-git-config init-submodules pull-submodules doctor-submodules test test-parallel test-ractor-pool lint check check-plugins check-incremental docs-check verify verify-parallel check-json extract-builtin-catalogs catalog-diff steep-install steep-check steep cache-clean

REFERENCE_SUBMODULES := \
	references/rbs \
	references/rbs-inline-wiki \
	references/phpstan \
	references/python-typing \
	references/ruby \
	references/TypeScript-Website \
	references/typeprof \
	references/sorbet \
	references/tapioca \
	references/hanakai-rb \
	references/ex_doc \
	references/elixir-lang.github.com

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
	git submodule update --init --filter=blob:none references/rbs-inline-wiki
	@if [ ! -e references/phpstan/.git ]; then \
		url="$$(git config -f .gitmodules submodule.references/phpstan.url)"; \
		sha="$$(git rev-parse HEAD:references/phpstan)"; \
		echo "Initializing references/phpstan sparsely (website)"; \
		git clone --no-checkout --filter=blob:none "$$url" references/phpstan; \
		git -C references/phpstan fetch origin "$$sha"; \
		git -C references/phpstan sparse-checkout init --cone; \
		git -C references/phpstan sparse-checkout set website; \
		git -C references/phpstan checkout --detach "$$sha"; \
		git submodule absorbgitdirs references/phpstan; \
	else \
		git submodule update --init --filter=blob:none references/phpstan; \
	fi
	git submodule update --init --filter=blob:none references/python-typing
	git submodule update --init --filter=blob:none references/ruby
	git submodule update --init --filter=blob:none references/typeprof
	git submodule update --init --filter=blob:none references/sorbet
	git submodule update --init --filter=blob:none references/tapioca
	git submodule update --init --filter=blob:none references/hanakai-rb
	git submodule update --init --filter=blob:none references/ex_doc
	git submodule update --init --filter=blob:none references/elixir-lang.github.com
	@if [ ! -e references/TypeScript-Website/.git ]; then \
		url="$$(git config -f .gitmodules submodule.references/TypeScript-Website.url)"; \
		sha="$$(git rev-parse HEAD:references/TypeScript-Website)"; \
		echo "Initializing references/TypeScript-Website sparsely (packages/documentation/copy/en)"; \
		git clone --no-checkout --filter=blob:none "$$url" references/TypeScript-Website; \
		git -C references/TypeScript-Website fetch origin "$$sha"; \
		git -C references/TypeScript-Website sparse-checkout init --cone; \
		git -C references/TypeScript-Website sparse-checkout set packages/documentation/copy/en; \
		git -C references/TypeScript-Website checkout --detach "$$sha"; \
		git submodule absorbgitdirs references/TypeScript-Website; \
	else \
		git submodule update --init --filter=blob:none references/TypeScript-Website; \
	fi

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

# Spec suite via `parallel_tests`, splitting files across
# multiple worker processes. `PARALLEL_TEST_PROCESSORS=N`
# pins the worker count; default is the CPU count.
test-parallel:
	bundle exec rake spec_parallel

lint:
	bundle exec rubocop lib/ spec/ plugins/ examples/

# `--no-cache`: the self-check is a verification gate and must never trust
# a cached result. The ADR-45 record-and-validate run cache serves an
# unchanged tree's previous result; the fingerprint excludes engine code
# (only `Rigor::VERSION`), so an engine edit at the same version could be
# masked by a stale hit. The gate always re-runs the analysis fresh.
check:
	bundle exec exe/rigor check --no-cache --no-ci-detect lib

# Self-check the bundled plugin / example LIB trees against the
# `Plugin::Base` contract. ADR-43 ancestor resolution makes a plugin's
# inherited contract calls (`manifest.…`, `io_boundary.…`) resolve, so
# `rigor check` warns on contract misuse here — this target is what
# turns that into a gate. Lib dirs only (the `demo/` trees deliberately
# exercise un-modelled framework DSLs and are not a clean target). MUST
# stay clean for the same reason `check` does: fix the cause, never
# disable the rule.
check-plugins:
	bundle exec exe/rigor check --no-cache --no-ci-detect plugins/*/lib examples/*/lib

# ADR-46 incremental-analysis acceptance gate. `--verify-incremental`
# runs a baseline analysis, re-analyzes a subset of files and serves the
# rest from the per-file cache, and asserts the merged diagnostics are
# byte-identical to a full `--no-cache` run. A mismatch means the
# incremental machinery would serve a stale — manufactured — diagnostic,
# the soundness failure the gate exists to catch. Deliberately NOT in
# `verify`: it runs ~3 analyses per target (baseline + subset + full), too
# slow for the local fast path. CI runs it (cold variant).
check-incremental:
	bundle exec exe/rigor check --verify-incremental --no-stats lib
	bundle exec exe/rigor check --verify-incremental --no-stats plugins/*/lib examples/*/lib

# Verify that docs/handbook/ executable snippets are accurate and that
# docs/handbook/ + docs/manual/ relative links and doc↔code references are
# consistent.  Runs spec/docs/ in isolation so failures are attributed
# clearly.  Already included in the `test`/`test-parallel` suite; this
# target is the named gate for a focused docs-only run.
docs-check:
	bundle exec rspec spec/docs/

check-json:
	bundle exec exe/rigor check --format=json lib

# Report type-precision coverage for `lib/`.
# Exits non-zero when precision ratio drops below 43 % (the calibrated
# baseline measured against Rigor's own source on 2026-05-26).
# Use `rigor coverage lib/` without --threshold for a non-gating report.
coverage:
	bundle exec exe/rigor coverage --threshold 0.43 lib

# ADR-50 WD4 perf-regression gate. Runs `rigor check --no-cache` over `lib`
# in-process, measures wall / allocations / peak-RSS, and gates against
# bench/baseline.json within bench/thresholds.yml. The committed baseline
# ships uncalibrated, so the first run writes a suggested baseline
# (bench/baseline.updated.json, gitignored) and passes — commit a
# CI-measured baseline to activate. Deliberately NOT in `verify` (a full
# analysis under measurement is slow); the release gate runs it (advisory).
# Named `bench-perf` (not `bench`) so the target does not collide with the
# `bench/` data directory — keeping the file's no-`.PHONY` convention and
# its `check-*` / `test-*` hyphenated-target family.
bench-perf:
	bundle exec ruby scripts/bench.rb --target lib

# `verify` chains the spec suite, the gated pool-runner spec (its
# own rspec process — see `test-ractor-pool`), rubocop, `rigor check
# lib`, and the plugin-tree contract check. The spec phase runs in
# parallel by default (3-4× faster on multi-core hosts than the
# sequential rspec invocation). `lint` is already process-parallel
# via rubocop's built-in worker pool; `check` / `check-plugins` are
# short rigor invocations.
#
# Total wall time on a 12-core laptop: ~60s (vs ~200s for the
# sequential variant below). Use `verify-sequential` when chasing
# parallel-only flakes — the worker isolation hides certain
# ordering bugs that surface only in a single-process run.
verify: test-parallel test-ractor-pool lint check check-plugins

# Sequential variant. Identical phases as `verify` but `test`
# runs single-process. Slower but bit-for-bit reproducible
# without inter-worker scheduling effects.
verify-sequential: test test-ractor-pool lint check check-plugins

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
