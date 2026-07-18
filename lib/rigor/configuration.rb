# frozen_string_literal: true

require "yaml"

require_relative "bleeding_edge"
require_relative "ci_detector"
require_relative "configuration/dependencies"
require_relative "configuration/severity_profile"

module Rigor
  class Configuration # rubocop:disable Metrics/ClassLength
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

    DEFAULTS = {
      "target_ruby" => "4.0",
      "paths" => ["lib"],
      "exclude" => [],
      "plugins" => [],
      "disable" => [],
      "libraries" => [],
      "signature_paths" => nil,
      # ADR-17 — project-side monkey-patch pre-evaluation. Empty by default; users opt in by listing explicit
      # files that the analyzer walks before per-file inference so patched-method declarations are visible
      # across the project (e.g. `lib/core_ext/string_extensions.rb`). Slice 1 plumbing only — listed files
      # are validated at config-load time (`pre-eval.file-not-found` on a missing path), but the dispatcher
      # tier consuming the registry lands in slice 2.
      "pre_eval" => [],
      # ADR-22 — baseline file path. nil (default) means no baseline is loaded; the `false` literal is
      # treated as the explicit-disable form for `.rigor.yml`-side override of an upstream `.rigor.dist.yml`
      # `baseline:` declaration. The presence of `.rigor-baseline.yml` on disk alone does NOT activate
      # filtering — the path must be named here (WD2 (b) of ADR-22).
      "baseline" => nil,
      "fold_platform_specific_paths" => false,
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
      # or `{ all: true, except: [ids] }` (adopt all but the named). The overlay is empty today, so every
      # form is currently a no-op; it becomes live when the first discipline is queued for a major.
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
        # Rigor walks `<bundle_path>/ruby/*/gems/*/sig/` and adds each gem-shipped sig directory to
        # `signature_paths:`. With O7's failure-memo in place, conflicts (a vendored sig already declares the
        # same constant) degrade gracefully to "no RBS env" with a single-line warning naming the offending
        # file, rather than hanging.
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
        # `RbsLoader`'s `signature_paths:`. Sources of type `stdlib` are skipped because rigor's bundled
        # `DEFAULT_LIBRARIES` already covers that surface.
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

    # Top-level keys whose values are file/directory paths that MUST be resolved relative to the config
    # file's directory. `exclude:` is intentionally NOT in this list — its entries are glob patterns
    # (`**/vendor/**`), not paths.
    PATH_KEYS = %w[paths signature_paths pre_eval].freeze
    private_constant :PATH_KEYS

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

    # Top-level keys the loaded config carried that this implementation does not own — neither a
    # {DEFAULTS} key, nor `includes:`, nor a reserved namespace. Recorded rather than acted on: an
    # unknown key stays as inert at run time as it has always been, and {ConfigAudit} turns the record
    # into a warning. Empty for every conforming config.
    #
    # This exists because `#initialize` fetches each key it owns and never enumerates the rest, so by
    # the time anything holds a Configuration the unknown keys are gone. The audit reads a
    # Configuration, so without this the class of mistake it exists to catch — a value that silently
    # resolves to nothing — was structurally invisible to it for whole keys.
    attr_reader :unknown_keys

    attr_reader :target_ruby, :paths, :exclude_patterns, :plugins, :cache_path, :cache_max_bytes,
                :cache_validation, :disabled_rules,
                :libraries, :signature_paths, :fold_platform_specific_paths,
                :plugins_io_network, :plugins_io_allowed_paths,
                :plugins_io_allowed_url_hosts,
                :severity_profile, :severity_overrides,
                :bleeding_edge, :bleeding_edge_severity_overrides,
                :dependencies, :parallel_workers,
                :bundler_bundle_path, :bundler_auto_detect, :bundler_lockfile,
                :rbs_collection_lockfile, :rbs_collection_auto_detect,
                :pre_eval, :baseline_path

    # Loads a configuration file.
    #
    # `path == nil` triggers auto-discovery against {DISCOVERY_ORDER}. The first present file in that list is
    # loaded; if none exist the built-in {DEFAULTS} are used.
    #
    # When a path is supplied (whether by auto-discovery or by the caller) the YAML body is processed for
    # `includes:` recursively, and every relative path inside path-bearing keys (`paths:`,
    # `signature_paths:`, `plugins_io.allowed_paths:`, `includes:`) is resolved against THAT file's
    # directory. The resolution is per-file: an included file's relative paths resolve against the included
    # file's directory, not the top-level file. Path resolution mirrors
    # [PHPStan](https://phpstan.org/config-reference#paths).
    def self.load(path = nil)
      resolved = path || discover
      return new(DEFAULTS) if resolved.nil? || !File.exist?(resolved)

      data = load_with_includes(resolved)
      new(DEFAULTS.merge(data))
    end

    # Returns the path to the config file Rigor would load under auto-discovery, or `nil` when neither
    # candidate exists. Public so the CLI / spec drift checks can introspect the resolved file.
    def self.discover
      DISCOVERY_ORDER.find { |candidate| File.exist?(candidate) }
    end

    # Reads `path` (which MUST exist) plus every file listed in its `includes:` chain, merging them under the
    # order: included files first (in declaration order), then the current file's own keys override.
    # Relative paths inside each file are resolved against that file's directory. Public so the CLI can run
    # the include-aware load before applying `--treat-all-as-inline-rbs`'s plugin injection (see
    # {CLI::CheckCommand#load_check_configuration}).
    def self.load_with_includes(path, visited: Set.new)
      absolute = File.expand_path(path)
      raise ArgumentError, "circular include: #{absolute}" if visited.include?(absolute)

      raw = YAML.safe_load_file(absolute, aliases: false) || {}
      raise ArgumentError, "config file must be a YAML mapping: #{absolute}" unless raw.is_a?(Hash)

      base_dir = File.dirname(absolute)
      includes = Array(raw.delete("includes") || [])
      data = resolve_paths_in(raw, base_dir)
      next_visited = visited + [absolute]
      merge_includes(data, includes, base_dir, next_visited)
    end

    def self.merge_includes(data, includes, base_dir, visited)
      return data if includes.empty?

      accumulated = {}
      includes.each do |inc|
        inc_path = File.expand_path(inc.to_s, base_dir)
        unless File.exist?(inc_path)
          raise ArgumentError, "include not found: #{inc.inspect} (referenced from #{base_dir})"
        end

        accumulated = deep_merge(accumulated, load_with_includes(inc_path, visited: visited))
      end
      deep_merge(accumulated, data)
    end

    # Per-file path resolution. Each path-bearing key listed in {PATH_KEYS} plus the nested
    # `plugins_io.allowed_paths:` entries get their relative paths expanded against the config file's
    # directory. `cache.path:` is intentionally left as-is so end-user messages (e.g. `--cache-stats` output)
    # keep the project-relative form the user wrote.
    def self.resolve_paths_in(data, base_dir)
      return data unless data.is_a?(Hash)

      out = data.dup
      PATH_KEYS.each { |key| resolve_path_key!(out, key, base_dir) }
      resolve_plugins_io_paths!(out, base_dir)
      out
    end

    def self.resolve_path_key!(out, key, base_dir)
      return unless out.key?(key) && !out[key].nil?

      out[key] = Array(out[key]).map { |p| File.expand_path(p.to_s, base_dir) }
    end

    def self.resolve_plugins_io_paths!(out, base_dir)
      plugins_io = out["plugins_io"]
      return unless plugins_io.is_a?(Hash) && plugins_io["allowed_paths"]

      duped = plugins_io.dup
      duped["allowed_paths"] = Array(plugins_io["allowed_paths"]).map { |p| File.expand_path(p.to_s, base_dir) }
      out["plugins_io"] = duped
    end

    def self.deep_merge(left, right)
      return right unless left.is_a?(Hash) && right.is_a?(Hash)

      merged = left.dup
      right.each do |key, value|
        merged[key] = merge_value(key, merged, value)
      end
      merged
    end

    # Most keys are right-wins (override) or recursively merged hashes. ADR-10 § "config-conflict
    # diagnostic" carves out `dependencies.source_inference[]`: the per-gem merge across `includes:` chains
    # needs union behaviour with mode-conflict detection. The Hash itself still merges deeply; only the
    # inner array gets concatenated so {Dependencies.from_h} sees every contributor's entries and can dedupe
    # them.
    def self.merge_value(key, merged, value)
      if key == "dependencies" && merged[key].is_a?(Hash) && value.is_a?(Hash)
        merge_dependencies_hash(merged[key], value)
      elsif merged.key?(key) && merged[key].is_a?(Hash) && value.is_a?(Hash)
        deep_merge(merged[key], value)
      else
        value
      end
    end

    def self.merge_dependencies_hash(left, right)
      out = deep_merge(left, right)
      left_si = Array(left["source_inference"])
      right_si = Array(right["source_inference"])
      both_empty = left_si.empty? && right_si.empty?
      out["source_inference"] = left_si + right_si unless both_empty # rigor:disable flow.always-truthy-condition
      out
    end
    private_class_method :merge_includes, :resolve_paths_in, :deep_merge,
                         :merge_value, :merge_dependencies_hash

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def initialize(data = DEFAULTS)
      # Record before the per-key fetches below discard the evidence. Top level only, deliberately —
      # see {ConfigAudit.unknown_key_warnings} for why a nested check cannot key on DEFAULTS.
      @unknown_keys = (data.keys.map(&:to_s) - KNOWN_KEYS).sort.freeze

      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))
      plugins_io = DEFAULTS.fetch("plugins_io").merge(data.fetch("plugins_io", {}))

      @target_ruby = coerce_target_ruby(data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")))
      @paths = Array(data.fetch("paths", DEFAULTS.fetch("paths"))).map(&:to_s).freeze
      user_excludes = Array(data.fetch("exclude", DEFAULTS.fetch("exclude"))).map(&:to_s)
      @exclude_patterns = (BUILTIN_EXCLUDES + user_excludes).uniq.freeze
      @plugins = Array(data.fetch("plugins", DEFAULTS.fetch("plugins"))).map do |entry|
        coerce_plugin_entry(entry)
      end.freeze
      @disabled_rules = Array(data.fetch("disable", DEFAULTS.fetch("disable"))).map(&:to_s).freeze
      @libraries = Array(data.fetch("libraries", DEFAULTS.fetch("libraries"))).map(&:to_s).freeze
      sig_paths = data.fetch("signature_paths", DEFAULTS.fetch("signature_paths"))
      @signature_paths = sig_paths.nil? ? nil : Array(sig_paths).map(&:to_s).freeze
      @pre_eval = expand_pre_eval_entries(
        Array(data.fetch("pre_eval", DEFAULTS.fetch("pre_eval"))).map(&:to_s)
      )
      @baseline_path = coerce_baseline_path(data.fetch("baseline", DEFAULTS.fetch("baseline")))
      @fold_platform_specific_paths = data.fetch(
        "fold_platform_specific_paths", DEFAULTS.fetch("fold_platform_specific_paths")
      ) == true
      @cache_path = cache.fetch("path").to_s
      raw_max = cache.fetch("max_bytes")
      @cache_max_bytes = raw_max.nil? ? nil : Integer(raw_max)
      @cache_validation = coerce_cache_validation(cache.fetch("validation", "auto"))
      @plugins_io_network = coerce_network_policy(plugins_io.fetch("network"))
      @plugins_io_allowed_paths = Array(plugins_io.fetch("allowed_paths")).map(&:to_s).freeze
      @plugins_io_allowed_url_hosts = Array(plugins_io.fetch("allowed_url_hosts")).map(&:to_s).freeze
      @severity_profile = coerce_severity_profile(
        data.fetch("severity_profile", DEFAULTS.fetch("severity_profile"))
      )
      @severity_overrides = coerce_severity_overrides(
        data.fetch("severity_overrides", DEFAULTS.fetch("severity_overrides"))
      )
      @bleeding_edge = coerce_bleeding_edge(
        data.fetch("bleeding_edge", DEFAULTS.fetch("bleeding_edge"))
      )
      @bleeding_edge_severity_overrides = BleedingEdge.severity_overrides_for(@bleeding_edge)
      @dependencies = Dependencies.from_h(
        data.fetch("dependencies", DEFAULTS.fetch("dependencies"))
      )
      parallel = DEFAULTS.fetch("parallel").merge(data.fetch("parallel", {}))
      @parallel_workers = coerce_parallel_workers(parallel.fetch("workers"))
      bundler = DEFAULTS.fetch("bundler").merge(data.fetch("bundler", {}))
      bp = bundler.fetch("bundle_path")
      @bundler_bundle_path = bp.nil? ? nil : bp.to_s.dup.freeze
      @bundler_auto_detect = bundler.fetch("auto_detect") == true
      lf = bundler.fetch("lockfile")
      @bundler_lockfile = lf.nil? ? nil : lf.to_s.dup.freeze
      rbs_collection = DEFAULTS.fetch("rbs_collection").merge(data.fetch("rbs_collection", {}))
      rclf = rbs_collection.fetch("lockfile")
      @rbs_collection_lockfile = rclf.nil? ? nil : rclf.to_s.dup.freeze
      @rbs_collection_auto_detect = rbs_collection.fetch("auto_detect") == true
      # Ractor migration Phase 2a: deep-freeze the Configuration so it is `Ractor.shareable?`. Every ivar
      # above is now either a frozen value (Symbol / nil / Boolean) or an explicitly frozen collection /
      # value object; freezing `self` makes the whole carrier safe to send across Ractor boundaries (and
      # catches accidental post-init mutation in any caller). See `docs/design/20260514-ractor-migration.md`.
      freeze
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Resolves the `cache.validation` tri-state to the boolean the run installs via
    # {Cache::FileDigest.with_run}'s `strict:`. Explicit `"digest"` / `"stat"` win outright; the `"auto"`
    # default is strict exactly when {CiDetector} recognises a CI provider (#190) — deliberately NOT stored at
    # construction so the resolution honours the environment of the run, not of `Configuration.load`, and the
    # frozen carrier stays env-independent. `RIGOR_STRICT_VALIDATION=1` is enforced separately inside
    # {Cache::FileDigest.strict_validation?} and wins over all three values.
    def cache_validation_strict?(env = ENV)
      case cache_validation
      when "digest" then true
      when "stat" then false
      else !CiDetector.detect(env).nil?
      end
    end

    def to_h # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      {
        "target_ruby" => target_ruby,
        "paths" => paths,
        "exclude" => exclude_patterns - BUILTIN_EXCLUDES,
        "plugins" => plugins,
        "disable" => disabled_rules,
        "libraries" => libraries,
        "signature_paths" => signature_paths,
        "pre_eval" => pre_eval,
        "fold_platform_specific_paths" => fold_platform_specific_paths,
        "cache" => {
          "path" => cache_path,
          "max_bytes" => cache_max_bytes,
          "validation" => cache_validation
        },
        "plugins_io" => {
          "network" => plugins_io_network.to_s,
          "allowed_paths" => plugins_io_allowed_paths,
          "allowed_url_hosts" => plugins_io_allowed_url_hosts
        },
        "severity_profile" => severity_profile.to_s,
        "severity_overrides" => severity_overrides.to_h { |k, v| [k, v.to_s] },
        "bleeding_edge" => bleeding_edge_to_h,
        "dependencies" => dependencies.to_h,
        "parallel" => {
          "workers" => parallel_workers
        },
        "bundler" => {
          "bundle_path" => bundler_bundle_path,
          "auto_detect" => bundler_auto_detect,
          "lockfile" => bundler_lockfile
        },
        "rbs_collection" => {
          "lockfile" => rbs_collection_lockfile,
          "auto_detect" => rbs_collection_auto_detect
        }
      }
    end

    # ADR-50 § WD2 — returns a sibling Configuration whose bleeding-edge selection (and the derived
    # `bleeding_edge_severity_overrides` the two {SeverityProfile.resolve} sites consult) is replaced by
    # `value`, leaving every other field shared with the receiver. `value` takes the same forms as the
    # `bleeding_edge:` config key — `false` / `true` / a feature-id Array / `{ "all" => true, "except" =>
    # [...] }` — and is normalised through the same {#coerce_bleeding_edge} path, so an unknown id stays
    # inert.
    #
    # The CLI's `--bleeding-edge[=ids]` / `--no-bleeding-edge` flag uses this to override the configured
    # selection for a single run (the same CLI-over-config precedence `--workers` and `--no-cache` follow).
    # It is a frozen `dup` with the two bleeding-edge ivars re-set: `dup` returns an unfrozen shallow copy
    # (every other ivar is the receiver's deeply-frozen value, safe to share read-only), the two replacements
    # are themselves deeply frozen, and the re-`freeze` keeps the result `Ractor.shareable?` for the worker
    # path.
    def with_bleeding_edge(value)
      selector = coerce_bleeding_edge(value)
      copy = dup
      copy.instance_variable_set(:@bleeding_edge, selector)
      copy.instance_variable_set(:@bleeding_edge_severity_overrides,
                                 BleedingEdge.severity_overrides_for(selector))
      copy.freeze
    end

    private

    # ADR-17 slice 4 — `pre_eval:` glob expansion. Each entry is accepted as either a literal path (slice 1
    # contract) OR a `File.fnmatch?`-shaped glob pattern (`lib/core_ext/**/*.rb`). Glob meta characters (`*`,
    # `?`, `[`) trigger `Dir.glob` expansion; the resulting file list is folded into the `pre_eval:` set with
    # `uniq`. Literal entries that don't exist on disk continue to surface as `pre-eval.file-not-found`
    # `:error` (slice 1 behaviour); glob entries that match nothing degrade silently to "no contribution from
    # this entry" so a templated `**` pattern in a fresh project doesn't generate an error per match-less
    # pattern.
    def expand_pre_eval_entries(entries)
      entries.flat_map do |entry|
        glob_pattern?(entry) ? Dir.glob(entry, sort: true) : [entry]
      end.uniq.freeze
    end

    def glob_pattern?(path)
      path.include?("*") || path.include?("?") || path.include?("[")
    end

    # Accepts either `"rigor-foo"` (gem-name shorthand) or `{ "gem" => "rigor-foo", "id" => "foo", "config" =>
    # {...} }` (full form). Returns the canonical hash form so the loader works against a single shape.
    def coerce_plugin_entry(entry)
      case entry
      when String
        entry.dup.freeze
      when Hash
        entry.to_h { |k, v| [k.to_s, v] }.freeze
      else
        raise ArgumentError,
              "plugin configuration entry must be a String or Hash, got #{entry.inspect}"
      end
    end

    # `target_ruby` is passed to `Prism.parse_file(path, version:)` at the analyser's three parse sites
    # (`Analysis::Runner`, `CLI::TypeOfCommand`, `CLI::TypeScanCommand`) so projects that target an older
    # Ruby get parse errors for syntax their target doesn't support. Format validation here is loose —
    # accepts any `<major>.<minor>` or `<major>.<minor>.<patch>` form, plus the literal `"latest"`. Prism
    # itself enforces the supported set and raises `ArgumentError` for versions it does not recognise (e.g.
    # `"1.0"`); the parse-time error message names the version, so the user can correct the setting.
    TARGET_RUBY_FORMAT = /\A(?:\d+\.\d+(?:\.\d+)?|latest)\z/
    private_constant :TARGET_RUBY_FORMAT

    def coerce_target_ruby(value)
      s = value.to_s
      unless s.match?(TARGET_RUBY_FORMAT)
        raise ArgumentError,
              "target_ruby must be a version (e.g. \"3.4\", \"4.0\", \"3.4.0\") or \"latest\", got #{value.inspect}"
      end

      s.dup.freeze
    end

    # YAML scalar may arrive as a String or already as a Symbol; coerce to the canonical Symbol shape so the
    # downstream `TrustPolicy` constructor stays strict.
    #
    # The accepted set is duplicated from {Rigor::Plugin::TrustPolicy::VALID_NETWORK_POLICIES} so
    # `Configuration` does not require the plugin namespace at load time (Configuration is loaded before
    # Plugin in `lib/rigor.rb`); the two stay in lockstep via spec.
    VALID_NETWORK_POLICIES = %i[disabled allowlist].freeze
    private_constant :VALID_NETWORK_POLICIES

    # ADR-15 Phase 4c — accepts a non-negative Integer (or a string-shaped one from YAML files that miss type
    # annotations). Negative / non-integer values raise so typos / bad YAML fail loudly rather than silently
    # disabling parallelism.
    def coerce_parallel_workers(value)
      integer = Integer(value)
      raise ArgumentError, "parallel.workers must be >= 0, got #{value.inspect}" if integer.negative?

      integer
    rescue TypeError, ArgumentError => e
      raise ArgumentError, "parallel.workers must be a non-negative Integer, got #{value.inspect} (#{e.message})"
    end

    # ADR-22 WD2 (b) — `baseline: <path>` activates the file; `baseline: false` is the explicit-disable form
    # (useful in `.rigor.yml` to override an upstream `.rigor.dist.yml` that names a baseline). `nil`
    # (default / absent key) is also "no baseline".
    def coerce_baseline_path(value)
      return nil if value.nil? || value == false

      value.to_s
    end

    # ADR-87 WD1 — `cache.validation` is `"auto"` (default), `"stat"`, or `"digest"`. An unrecognised value
    # fails soft to the default rather than aborting a check over a typo — the strict `"digest"` behaviour is
    # the safe fallback either way, and the always-available `RIGOR_STRICT_VALIDATION=1` env escape hatch does
    # not depend on this value being valid.
    VALID_CACHE_VALIDATIONS = %w[auto stat digest].freeze
    private_constant :VALID_CACHE_VALIDATIONS

    def coerce_cache_validation(value)
      str = value.to_s
      VALID_CACHE_VALIDATIONS.include?(str) ? str : "auto"
    end

    def coerce_network_policy(value)
      sym = value.to_sym
      unless VALID_NETWORK_POLICIES.include?(sym)
        raise ArgumentError,
              "plugins_io.network must be one of #{VALID_NETWORK_POLICIES.inspect}, got #{value.inspect}"
      end

      sym
    end

    # ADR-8 § "Severity profile" — accepts the canonical Symbol form or its String spelling; rejects unknown
    # profile names so typos fail loudly.
    def coerce_severity_profile(value)
      sym = value.to_sym
      unless SeverityProfile::VALID_PROFILES.include?(sym)
        raise ArgumentError,
              "severity_profile must be one of " \
              "#{SeverityProfile::VALID_PROFILES.inspect}, got #{value.inspect}"
      end

      sym
    end

    # ADR-8 § "Severity profile" — `severity_overrides:` is a `{ rule => severity }` map. Keys are canonical
    # rule ids (`call.undefined-method`) or family wildcards (`call`). Values are
    # {SeverityProfile::VALID_SEVERITIES} symbols (`:error` / `:warning` / `:info` / `:off`). Unknown
    # severities raise; unknown rule ids are silently kept (the override is inert until the rule lands).
    def coerce_severity_overrides(value)
      raise ArgumentError, "severity_overrides must be a Hash, got #{value.inspect}" unless value.is_a?(Hash)

      value.to_h do |k, v|
        # YAML 1.1 parses bare `off`/`on`/`no`/`yes`/`true`/`false` as booleans, so a user who wrote `off` (a
        # valid severity) without quotes hands us `false`. Catch the non-Symbol / non-String case before
        # `to_sym` blows up with a backtrace.
        unless v.is_a?(String) || v.is_a?(Symbol)
          hint = v == false ? %( — did you mean the string "off"?) : ""
          raise ArgumentError,
                "severity_overrides[#{k.inspect}] is #{v.inspect}, a YAML boolean#{hint} " \
                "Bare off/on/no/yes/true/false are parsed as booleans; quote the severity " \
                "(e.g. \"off\")."
        end

        sym = v.to_sym
        unless SeverityProfile::VALID_SEVERITIES.include?(sym)
          raise ArgumentError,
                "severity_overrides[#{k.inspect}] must be one of " \
                "#{SeverityProfile::VALID_SEVERITIES.inspect}, got #{v.inspect}"
        end

        [k.to_s, sym]
      end.freeze
    end

    # ADR-50 § WD2 — normalizes the `bleeding_edge:` selector to a canonical `{ "mode" => … }` hash
    # (interpreted by {Rigor::BleedingEdge}). Validates *shape* only; membership against the overlay is
    # intentionally NOT checked here (an unknown id stays inert, like an unknown `severity_overrides:` rule).
    # Deep-frozen so the Configuration stays `Ractor.shareable?`.
    def coerce_bleeding_edge(value)
      case value
      when nil, false then { "mode" => "none" }
      when true then { "mode" => "all" }
      when Array then { "mode" => "list", "ids" => freeze_ids(value) }
      when Hash then coerce_bleeding_edge_hash(value)
      else
        raise ArgumentError,
              "bleeding_edge must be true, false, a list of feature ids, " \
              "or { all: true, except: [...] }, got #{value.inspect}"
      end.freeze
    end

    def coerce_bleeding_edge_hash(value)
      hash = value.to_h { |k, v| [k.to_s, v] }
      if hash.fetch("all", false) == true
        { "mode" => "all", "except" => freeze_ids(Array(hash["except"])) }
      else
        { "mode" => "none" }
      end
    end

    # Feature ids reach `coerce_bleeding_edge` from YAML, a `to_h` round-trip, or the CLI's
    # `--bleeding-edge=a,b` (all runtime-created, non-frozen Strings). Each id String is frozen so the
    # normalized selector — and thus the whole Configuration — stays deeply frozen and `Ractor.shareable?`
    # for the worker path (the same invariant `#initialize`'s final `freeze` upholds for every other field).
    def freeze_ids(ids)
      ids.map { |id| id.to_s.dup.freeze }.freeze
    end

    # Renders the normalized selector back into the user-facing `bleeding_edge:` form for `#to_h`
    # round-trips.
    def bleeding_edge_to_h
      case bleeding_edge["mode"]
      when "all"
        except = bleeding_edge["except"] || []
        except.empty? || { "all" => true, "except" => except }
      when "list" then bleeding_edge["ids"] || []
      else false
      end
    end
  end
end
