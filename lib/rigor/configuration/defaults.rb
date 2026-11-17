# frozen_string_literal: true

require_relative "dependencies"

module Rigor
  class Configuration
    # `Configuration`'s defaults and the constants that describe its keys, kept apart from the class that reads
    # them. The class reaches each one as `Configuration::NAME`: `configuration.rb` binds every public constant
    # here to the same object under that name, so `Configuration::DEFAULTS` stays the one defaults table for
    # {Configuration}, {Configuration::Coercion} and {Configuration::Loader} alike.
    module Defaults
      # File-discovery order for `Configuration.load(nil)`.
      #
      # The first file present is loaded; the others are NOT implicitly merged. To extend a base config
      # explicitly the winning file MUST list the base via `includes:`.
      #
      # `.rigor.yml` is a developer-local override (typically gitignored); `.rigor.dist.yml` is the project
      # default (committed to the repo). When both are present the developer's local override wins outright —
      # there is no implicit auto-merge.
      DISCOVERY_ORDER = %w[.rigor.yml .rigor.dist.yml].freeze
      # Back-compat alias. Keep here so external callers that read `Configuration::DEFAULT_PATH` for help text /
      # fixture paths still work; the discovery list is the canonical source.
      DEFAULT_PATH = DISCOVERY_ORDER.first

      # ADR-103 WD7 — where `rigor effects update` writes when `effects.snapshot.path:` is unset. Public
      # because the schema pins its own `default` against it.
      DEFAULT_EFFECTS_SNAPSHOT_PATH = ".rigor-effects.yml"

      # Built-in exclusion patterns appended to `exclude:` so vendored dependencies, Bundler artefacts, and
      # JavaScript node_modules are never analysed by accident when a directory glob expands. Users cannot
      # disable these defaults; the trade-off is that analysing any of these paths is essentially never what
      # the user wants (they're build outputs / external dependencies, not source).
      #
      # We deliberately keep this list narrow. `tmp/` and similar directories vary across project layouts
      # (Rails has `tmp/`, libraries usually don't); user-supplied `exclude:` entries in `.rigor.yml` cover the
      # project-specific cases.
      BUILTIN_EXCLUDES = %w[
        **/vendor/bundle/**
        **/.bundle/**
        **/node_modules/**
      ].freeze

      # The conventional test roots `test_paths: nil` auto-detects, in this order.
      CONVENTIONAL_TEST_PATHS = %w[spec test].freeze

      DEFAULTS = {
        "target_ruby" => "4.0",
        "paths" => ["lib"],
        "exclude" => [],
        "plugins" => [],
        "disable" => [],
        "libraries" => [],
        "signature_paths" => nil,
        # Issue #2517 — a core signature directory loaded IN PLACE OF the `rbs` gem's `core/` (a provider such as
        # rbs-shifter writes one for an older CRuby). `nil` (the default) loads the gem's core. Unlike
        # `signature_paths:`, which only adds, this replaces: the default core is not loaded beside it.
        "core_root" => nil,
        # The project's test roots: the directories (or files) holding its tests. `nil` (the default) auto-detects
        # whichever of `spec/` and `test/` exist, the same way `signature_paths: nil` auto-detects `sig/`; `[]`
        # declares that the project has none. `rigor sig-gen --params=observed` harvests call-site observations
        # from them when no `--observe=PATH` is given. See {#resolved_test_paths}.
        "test_paths" => nil,
        # ADR-112 WD4 — `rigor sig-gen` settings. `inline_declared:` decides what happens to a method the inline
        # reader (`rigor-rbs-inline`) already declares from `# @rbs` / `#:`. `write` (the default) copies the
        # inline declaration into `sig/`, so the generated signature is the complete contract a gem ships;
        # `skip` leaves every member that reader declares out of `sig/`, for a project whose Steep reads the
        # same annotations (`inline: true` beside `signature "sig"`), where the copy would be a second
        # declaration of one method (`DuplicatedMethodDefinition`). See {#sig_gen_inline_declared}.
        "sig_gen" => {
          "inline_declared" => "write"
        },
        # ADR-17 — project-side monkey-patch pre-evaluation. Empty by default; users opt in by listing explicit
        # files (or globs) that the analyzer walks before per-file inference so patched-method declarations are
        # visible across the project (e.g. `lib/core_ext/string_extensions.rb`). A missing literal path surfaces
        # as `pre-eval.file-not-found`.
        "pre_eval" => [],
        # ADR-22 — baseline file path. nil (default) means no baseline is loaded; the `false` literal is
        # treated as the explicit-disable form for `.rigor.yml`-side override of an upstream `.rigor.dist.yml`
        # `baseline:` declaration. The presence of `.rigor-baseline.yml` on disk alone does NOT activate
        # filtering — the path must be named here (WD2 (b) of ADR-22).
        "baseline" => nil,
        "fold_platform_specific_paths" => false,
        # ADR-67 WD6a — opt-in call-site parameter type inference on the `check` walk. When `true`, `rigor
        # check` runs the {Inference::ParameterInferenceCollector} as a one-round pre-pass into the discovery
        # seed, so an undeclared `def` / `initialize` / setter parameter is typed to the union of its resolved
        # call-site argument types (precision-additive only — the in-body negative rules decline on the inferred
        # lower bound, WD6b). `false` (the default, resolved off by every severity profile) keeps the table empty
        # and the run byte-identical to today. Composes with `--incremental` (the WD6c mutual exclusion is
        # lifted): the incremental session recomputes the table each run and diffs it against its snapshot,
        # re-checking any callee whose seeds moved.
        "parameter_inference" => false,
        # ADR-103 WD13 — the effect-labels opt-in, and the ONLY thing that turns effect collection on
        # besides running `rigor effects`. **Presence is the switch**: `effects: {}` — or the bare key, which
        # YAML parses as nil — enables collection with every sub-key at its default, because an annotation in
        # a project's RBS must never create a project-wide cost cliff (that case earns a `:info` residual
        # instead, #384).
        #
        # The default is `false` rather than `nil` precisely because presence is the switch and
        # `Configuration.load` merges these DEFAULTS UNDER the loaded file: a `nil` default would be
        # indistinguishable from a user's bare `effects:` key and would turn collection on for every project
        # in existence. `false` is also the explicit-disable form a `.rigor.yml` uses to override an upstream
        # `.rigor.dist.yml`'s `effects:` block — the same shape `baseline:` uses.
        #
        # The sub-keys are declared in `schemas/rigor-config.schema.json`. `check` (#383,
        # {#effects_check?}), `snapshot.{path,reach,gate}`, `tolerated` (#381) and the policy trio
        # `labels` / `attribution` / `envelopes` (#385, {#coerce_effects_policy}) are read; `views` lands
        # with the slice that implements it (#390). Reserving a sub-key's shape before a reader exists is
        # the same discipline the schema applies to a sibling implementation's namespace (ADR-99).
        "effects" => false,
        "cache" => {
          "path" => ".rigor/cache",
          # LRU eviction cap in bytes (ADR-54 WD3). The least-recently-used entries are removed at the end of a
          # run when the total exceeds this limit. The 256 MB default exists to reap orphans — entries whose
          # content key nothing references any more (an rbs gem bump, a signature change) and that no run
          # would otherwise ever delete; a full active per-project set is ~2 MB, so the cap never touches live
          # entries. Set explicitly to `null` to disable eviction (pre-WD3 behaviour: the cache grows until
          # `--clear-cache`).
          "max_bytes" => 268_435_456,
          # ADR-87 WD1 — file-freshness validation strategy. `"stat"` validates a recorded file
          # dependency by stat-ing it first and re-hashing only when the `(size, mtime_ns, ctime_ns, inode)`
          # tuple moved (or the racy window fires), so an unchanged monorepo hashes ~0 bytes on a warm run.
          # `"digest"` restores the pre-ADR-87 behaviour of SHA-256'ing every recorded file on every run — the
          # per-run escape hatch is the `RIGOR_STRICT_VALIDATION=1` env var, which wins over this setting.
          # `"auto"` (default, #190) resolves per environment: `"digest"` when {CiDetector} recognises a CI
          # provider — a fresh checkout regenerates every stat tuple, so the stat tier can never short-circuit
          # there and stat-signature glob slots would recompute on every run — and `"stat"` everywhere else.
          # A self-hosted runner with a persistent workspace opts back into the stat floor with an explicit
          # `"stat"` (or `RIGOR_CI_DETECT=0`).
          "validation" => "auto"
        },
        # ADR-39 slice 5 / #911 — the plugin-isolation strategy for target-library invocation. `nil` (the
        # default) names nothing, leaving the choice to `RIGOR_PLUGIN_ISOLATION` and then to
        # `Plugin::Isolation::DEFAULT`. The environment variable WINS over this key: it is the
        # one-invocation operator override (`RIGOR_PLUGIN_ISOLATION=none rigor check` on a platform where
        # the fork worker misbehaves), and an override a committed file can veto is not an override.
        # Only `none` and `process` are selectable here — `ruby_box` needs `RUBY_BOX=1` set before Ruby
        # boots, which is what `exe/rigor` re-execs for, and the launcher deliberately does not parse YAML
        # before that re-exec (ADR-87 / ADR-104 boot-slim), so naming it here raises instead of silently
        # resolving to a different strategy.
        "plugins_isolation" => nil,
        "plugins_io" => {
          "network" => "disabled",
          "allowed_paths" => [],
          "allowed_url_hosts" => []
        },
        "severity_profile" => "balanced",
        "severity_overrides" => {},
        # ADR-50 § WD2 — bleeding-edge overlay opt-in. Selects which of the *next major's* queued changes
        # ({Rigor::BleedingEdge}) this project adopts early. Orthogonal to `severity_profile:`. Accepts `false`
        # (default — adopt none), `true` (adopt the whole overlay), a list of feature ids (adopt only those),
        # or `{ all: true, except: [ids] }` (adopt all but the named). A queued change is either a severity
        # promotion (composed by {SeverityProfile.resolve}) or a behaviour switch (read at its call site
        # through {#bleeding_edge_active?}); `bleeding_edge:` selects both kinds the same way.
        "bleeding_edge" => false,
        "dependencies" => {
          "source_inference" => [],
          "budget_per_gem" => Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM
        },
        "parallel" => {
          # ADR-15 Phase 4c — when greater than zero, `rigor check` dispatches per-file analysis across N
          # Ractor workers built around {Rigor::Analysis::WorkerSession}. `0` (default) keeps the sequential
          # coordinator path bit-for-bit unchanged. The CLI's `--workers=N` flag and the `RIGOR_RACTOR_WORKERS`
          # env var both override this setting; precedence is CLI > env > config > 0.
          "workers" => 0
        },
        "bundler" => {
          # Open item O4 — target-project Bundler awareness. When `bundle_path:` is set (or auto-detected),
          # Rigor walks `<bundle_path>/ruby/*/gems/*/sig/` (RubyGems-sourced gems) and
          # `<bundle_path>/ruby/*/bundler/gems/*/sig/` (`git:`-sourced gems) and adds each gem-shipped sig
          # directory to `signature_paths:`. A `path:`-sourced gem is not under either — Bundler uses the
          # `path:` directory in place rather than copying it into the bundle root — so add its `sig/` directly
          # via `signature_paths:` instead. With O7's failure-memo in place, conflicts (a vendored sig already
          # declares the same constant) degrade gracefully to "no RBS env" with a single-line warning naming
          # the offending file, rather than hanging.
          #
          # `bundle_path:` (String, optional): explicit path to the bundler install root (e.g.,
          # "vendor/bundle" or an absolute path). Resolved relative to the project root (`paths:`'s base) when
          # relative.
          #
          # `auto_detect:` (Boolean, default true): when no explicit `bundle_path:` is set, try
          # `.bundle/config`'s `BUNDLE_PATH:` first; fall back to `vendor/bundle/` under the project root if it
          # exists. When neither is found, no extra sigs are added — the analyzer sees only rigor's vendored
          # RBS and the user's `signature_paths:`.
          #
          # O4 Layer 3 keys:
          #
          # `lockfile:` (String, optional): explicit path to a `Gemfile.lock`. Resolved relative to the
          # project root when relative. When set (or auto-detected via the `auto_detect:` flag below) Rigor
          # parses the lockfile and uses it to FILTER the bundle-discovered `sig/` directories: only gems whose
          # `(name, version, platform)` matches a lockfile entry are admitted to `signature_paths:`. Stale or
          # out-of-band gems sitting in the bundle install tree are silently dropped.
          #
          # `auto_detect:` (Boolean, also gates the lockfile search): when true and `lockfile:` is nil, look
          # for `<project_root>/Gemfile.lock`.
          "bundle_path" => nil,
          "auto_detect" => true,
          "lockfile" => nil
        },
        "rbs_collection" => {
          # Open item O4 Layer 3 slice 2 — `rbs collection install` awareness. When the target project has been
          # set up with `rbs collection install`, the resulting `rbs_collection.lock.yaml` carries the resolved
          # (gem, version, source) triples and `.gem_rbs_collection/` holds the downloaded `.rbs` files. Rigor
          # parses the lockfile and auto-feeds each gem's `<collection_root>/<name>/<version>/` directory into
          # `RbsLoader`'s `signature_paths:`. Sources of type `stdlib` install no directory; issue #2946 — they
          # load as RBS libraries, appended to `DEFAULT_LIBRARIES + libraries:`, as the `rbs` CLI loads them.
          #
          # `lockfile:` (String, optional): explicit path to `rbs_collection.lock.yaml`. Resolved relative to
          # the project root when relative.
          #
          # `auto_detect:` (Boolean, default true): when no explicit `lockfile:` is set, look for
          # `<project_root>/rbs_collection.lock.yaml`.
          "lockfile" => nil,
          "auto_detect" => true
        }
      }.freeze
      Ractor.make_shareable(DEFAULTS)

      # The isolation strategies a `.rigor.yml` may name (ADR-39 slice 5 / #911). `ruby_box` is
      # deliberately absent: it is a boot-time decision the config file is read too late to make.
      CONFIGURABLE_PLUGIN_ISOLATIONS = %w[none process].freeze

      # Top-level keys this implementation DECLARES but never reads — see `docs/internal-spec/config.md`
      # § "Reserved namespaces" and ADR-99.
      #
      # A sibling implementation (`rigor-rs`, which vendors our schema rather than keeping its own)
      # groups keys for concepts we do not have under its own namespace, so one `.rigor.yml` feeds both.
      # Such a key answers to the SCHEMA TIER ONLY: it is type-checked where it is written, and here it
      # is never read, never validated, never coerced, and never an error however invalid its value.
      #
      # That is already the emergent behaviour — `#initialize` fetches each key it owns and never
      # enumerates the rest — so this constant does not gate the runtime. It exists to make the
      # reservation FINDABLE by the next person adding config validation (#166 is exactly that), and to
      # give the schema-parity spec something to key on: a reserved namespace is by definition absent
      # from DEFAULTS, so the DEFAULTS-driven schema gate can never see it.
      RESERVED_NAMESPACES = %w[rigor_rs].freeze

      # Every top-level key a conforming `.rigor.yml` may carry: the keys this implementation owns, plus
      # `includes:`, plus the namespaces reserved for another implementation. Anything else is recorded in
      # {#unknown_keys} and warned about by {ConfigAudit}, and is also the did-you-mean dictionary for a
      # near-miss.
      #
      # `includes:` is a load-time directive — {load_with_includes} `delete`s it while merging, so it never
      # reaches `#initialize` and could not be seen as unknown regardless. It is listed because a user
      # legitimately writes it, so a typo like `include:` must be able to suggest it.
      KNOWN_KEYS = (DEFAULTS.keys + %w[includes] + RESERVED_NAMESPACES).freeze
    end
  end
end
