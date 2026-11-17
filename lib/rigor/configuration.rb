# frozen_string_literal: true

require_relative "bleeding_edge"
require_relative "ci_detector"
require_relative "configuration/coercion"
require_relative "configuration/defaults"
require_relative "configuration/dependencies"
require_relative "configuration/loader"
require_relative "configuration/severity_profile"
require_relative "configuration_error"

module Rigor
  class Configuration # rubocop:disable Metrics/ClassLength
    # The constants that describe the keys live in {Defaults}; each is the same object here, so
    # `Configuration::DEFAULTS` and the rest keep resolving for every reader.
    DISCOVERY_ORDER = Defaults::DISCOVERY_ORDER
    DEFAULT_PATH = Defaults::DEFAULT_PATH
    DEFAULT_EFFECTS_SNAPSHOT_PATH = Defaults::DEFAULT_EFFECTS_SNAPSHOT_PATH
    BUILTIN_EXCLUDES = Defaults::BUILTIN_EXCLUDES
    CONVENTIONAL_TEST_PATHS = Defaults::CONVENTIONAL_TEST_PATHS
    DEFAULTS = Defaults::DEFAULTS
    CONFIGURABLE_PLUGIN_ISOLATIONS = Defaults::CONFIGURABLE_PLUGIN_ISOLATIONS
    RESERVED_NAMESPACES = Defaults::RESERVED_NAMESPACES
    KNOWN_KEYS = Defaults::KNOWN_KEYS
    # The `rigor-rbs-inline` auto-wiring names belong to {Loader}, which reads them.
    AUTOWIRED_RBS_INLINE_GEM = Loader::AUTOWIRED_RBS_INLINE_GEM
    AUTOWIRED_RBS_INLINE_ID = Loader::AUTOWIRED_RBS_INLINE_ID

    # ADR-103 WD15 — the {BleedingEdge::FEATURES} id that, when adopted, makes a loaded file with no
    # `effects:` key behave as `effects: {}`. See {#coerce_effects}.
    EFFECTS_ON_BY_DEFAULT_FEATURE_ID = "effects-on-by-default"
    private_constant :EFFECTS_ON_BY_DEFAULT_FEATURE_ID

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
                :libraries, :signature_paths, :core_root, :test_paths, :fold_platform_specific_paths,
                :parameter_inference,
                :plugins_isolation,
                :plugins_io_network, :plugins_io_allowed_paths,
                :plugins_io_allowed_url_hosts,
                :severity_profile, :severity_overrides,
                :bleeding_edge, :bleeding_edge_severity_overrides,
                :dependencies, :parallel_workers,
                :bundler_bundle_path, :bundler_auto_detect, :bundler_lockfile,
                :rbs_collection_lockfile, :rbs_collection_auto_detect,
                :pre_eval, :baseline_path, :effects, :sig_gen_inline_declared,
                :effects_snapshot_path, :effects_snapshot_reach, :effects_snapshot_gate, :effects_tolerated,
                :effects_labels, :effects_attribution, :effects_envelopes

    # ADR-47 WD5 amendment (#1692) — whether `.rigor.yml` (or its `includes:` chain) set `target_ruby:` itself.
    # The default `"4.0"` is a parse version, not something the user said about the Ruby the project runs on.
    def target_ruby_explicit?
      @target_ruby_explicit
    end

    # ADR-47 WD5 amendment (#1692) — `target_ruby` read as a user statement about the runtime: the configured
    # version when the user set it explicitly, nil when it is the default or `"latest"`. `"latest"` names the
    # newest syntax this Prism build parses, which moves with a Rigor upgrade, so it states no runtime. Only the
    # Ruby-deprecation rules read this; `Inference::VersionGuard` keeps the analyzer's own `RUBY_VERSION`.
    def stated_runtime_ruby
      return nil unless target_ruby_explicit?
      return nil if target_ruby == "latest"

      target_ruby
    end

    # ADR-103 WD13 — whether effect collection runs. True exactly when the loaded configuration carried an
    # `effects:` block, whatever its body; `rigor effects` enables it for its own run by loading an
    # implicit `effects: {}` instead of by consulting anything else. Nothing else — no annotation, no
    # plugin, no severity profile — can turn collection on.
    def effects_enabled?
      !@effects.nil?
    end

    # ADR-103 WD14 / #383 — whether author-declared effect envelopes (`%a{pure}`,
    # `%a{rigor:v1:effect …}`) are checked against the collected summaries, surfacing
    # `effect.envelope-exceeded`. Defaults to **true when the `effects:` block is present**: the block is
    # the opt-in, and a project that asked for effects asked for its own declarations to hold. An explicit
    # `check: false` disables the diagnostic and leaves collection — and therefore `rigor effects` and the
    # snapshot — untouched. Always false without the block, so an annotation alone changes nothing.
    def effects_check?
      @effects_check
    end

    # The test roots a run uses: the declared `test_paths:` as written (already resolved against the
    # config file's directory by {.load}), or — when the key is unset — whichever of
    # {CONVENTIONAL_TEST_PATHS} is a directory under a root, as absolute paths. The roots, unless `root` names
    # one, are the directory of the config file in use, the one `paths:` and a declared `test_paths:` resolve
    # against, and then the working directory, read only when the first holds neither. Auto-detecting against
    # the working directory alone found nothing for a run from a subdirectory, or for the MCP server started
    # elsewhere, though both name the config file (#2078); a config file kept in a subdirectory
    # (`--config=config/rigor.yml`) still finds the project's `spec/` from the project root.
    def resolved_test_paths(root: nil)
      return test_paths unless test_paths.nil?

      roots = root ? [root] : [exclude_base, Dir.pwd].uniq
      roots.each do |dir|
        found = CONVENTIONAL_TEST_PATHS.map { |test_dir| File.absolute_path(test_dir, dir) }
                                       .select { File.directory?(it) }
        return found unless found.empty?
      end
      []
    end

    # #1576 — the directory relative `exclude:` patterns are matched against: the directory of the config file in
    # use (the base `paths:` resolve against), or the working directory when no config file is used.
    def exclude_base
      @base_dir || Dir.pwd
    end

    # Issue #2742 — the path config-anchored diagnostics are positioned at: the loaded config file's path
    # relative to the working directory (the project-root convention {Analysis::Baseline} uses), or
    # `.rigor.yml` when no file was loaded. A `--config=config/rigor.yml` run names `config/rigor.yml`.
    def config_display_path
      return DEFAULT_PATH if @config_path.nil?

      Pathname.new(@config_path).relative_path_from(Pathname.new(Dir.pwd)).to_s
    rescue ArgumentError
      @config_path
    end

    # The loader is {Loader}. Each of these keeps its place on `Configuration`, where the CLI, the language server
    # and the specs call it.
    def self.load(path = nil)
      Loader.load(path)
    end

    def self.autowire_default_plugins(data)
      Loader.autowire_default_plugins(data)
    end

    def self.rbs_inline_plugin_entry?(entry)
      Loader.rbs_inline_plugin_entry?(entry)
    end

    def self.rbs_inline_library_resolvable?
      Loader.rbs_inline_library_resolvable?
    end

    def self.discover
      Loader.discover
    end

    def self.load_with_includes(path, visited: Set.new)
      Loader.load_with_includes(path, visited: visited)
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    #
    # @param effects_key_present — ADR-103 WD15 — whether the file this `data` came from carried an
    #   `effects:` key at all, independent of its value. Defaults to `data.key?("effects")`, which is the
    #   right answer for a caller that passes a raw (non-`DEFAULTS`-merged) hash directly — the common shape
    #   in specs — but is always `true` once `data` has been through `DEFAULTS.merge`, because `DEFAULTS`
    #   itself carries the key; {.load} therefore computes this from the pre-merge file and passes it
    #   explicitly. See {#coerce_effects}. **Positional, deliberately not a keyword**: a bare (unbraced)
    #   `"key" => value` hash literal — this class's usual call shape, all over the spec suite — is coerced
    #   into keyword arguments by Ruby whenever the method declares ANY keyword parameter, which would break
    #   every `Configuration.new("some_key" => value)` call site with an "unknown keyword" `ArgumentError`.
    # @param target_ruby_key_present — ADR-47 WD5 amendment (#1692) — whether the file set `target_ruby:` itself,
    #   captured before `DEFAULTS.merge` for the same reason as `effects_key_present` and positional for the same
    #   reason. See {#stated_runtime_ruby}. The default reads the key off `data`, which is right only for a hash that
    #   has not been through `DEFAULTS.merge` (DEFAULTS carries the key); a caller that merges passes it explicitly.
    #   The bare `Configuration.new` is not explicit.
    def initialize(data = DEFAULTS, effects_key_present = data.key?("effects"),
                   target_ruby_key_present = data.key?("target_ruby") && !data.equal?(DEFAULTS))
      # Record before the per-key fetches below discard the evidence. Top level only, deliberately —
      # see {ConfigAudit.unknown_key_warnings} for why a nested check cannot key on DEFAULTS.
      @unknown_keys = (data.keys.map(&:to_s) - KNOWN_KEYS).sort.freeze

      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))
      plugins_io = DEFAULTS.fetch("plugins_io").merge(data.fetch("plugins_io", {}))

      @target_ruby = Coercion.coerce_target_ruby(data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")))
      @target_ruby_explicit = target_ruby_key_present ? true : false
      @paths = Array(data.fetch("paths", DEFAULTS.fetch("paths"))).map(&:to_s).freeze
      user_excludes = Array(data.fetch("exclude", DEFAULTS.fetch("exclude"))).map(&:to_s)
      @exclude_patterns = (BUILTIN_EXCLUDES + user_excludes).uniq.freeze
      @plugins = Array(data.fetch("plugins", DEFAULTS.fetch("plugins"))).map do |entry|
        Coercion.coerce_plugin_entry(entry)
      end.freeze
      @disabled_rules = Array(data.fetch("disable", DEFAULTS.fetch("disable"))).map(&:to_s).freeze
      @libraries = Array(data.fetch("libraries", DEFAULTS.fetch("libraries"))).map(&:to_s).freeze
      sig_paths = data.fetch("signature_paths", DEFAULTS.fetch("signature_paths"))
      @signature_paths = sig_paths.nil? ? nil : Array(sig_paths).map(&:to_s).freeze
      @core_root = Coercion.coerce_core_root(data.fetch("core_root", DEFAULTS.fetch("core_root")))
      test_paths = data.fetch("test_paths", DEFAULTS.fetch("test_paths"))
      @test_paths = test_paths.nil? ? nil : Array(test_paths).map(&:to_s).freeze
      @sig_gen_inline_declared = Coercion.coerce_sig_gen_inline_declared(data.fetch("sig_gen", nil))
      @pre_eval = Coercion.expand_pre_eval_entries(
        Array(data.fetch("pre_eval", DEFAULTS.fetch("pre_eval"))).map(&:to_s)
      )
      @baseline_path = Coercion.coerce_baseline_path(data.fetch("baseline", DEFAULTS.fetch("baseline")))
      @fold_platform_specific_paths = data.fetch(
        "fold_platform_specific_paths", DEFAULTS.fetch("fold_platform_specific_paths")
      )
      # ADR-67 WD6a — resolve to a strict Boolean so a truthy non-`true` value (e.g. a stray String) does not
      # silently enable the gate; only the literal `true` activates the check-walk collector pre-pass.
      @parameter_inference = data.fetch("parameter_inference", DEFAULTS.fetch("parameter_inference")) == true
      # ADR-103 WD13 — presence, not truthiness: `effects:` written with no body parses as nil and still
      # means "on", so the key's presence in the loaded data is what {#effects_enabled?} reads. The raw
      # input is kept so {#with_bleeding_edge} re-derives the effects block from the same source.
      @effects_key_present = effects_key_present
      @effects_written = Ractor.make_shareable(data.fetch("effects", false))
      derive_bleeding_edge(data.fetch("bleeding_edge", DEFAULTS.fetch("bleeding_edge")))
      derive_effects
      @cache_path = cache.fetch("path").to_s
      raw_max = cache.fetch("max_bytes")
      @cache_max_bytes = raw_max.nil? ? nil : Integer(raw_max)
      @cache_validation = Coercion.coerce_cache_validation(cache.fetch("validation", "auto"))
      @plugins_isolation = Coercion.coerce_plugins_isolation(
        data.fetch("plugins_isolation", DEFAULTS.fetch("plugins_isolation"))
      )
      @plugins_io_network = Coercion.coerce_network_policy(plugins_io.fetch("network"))
      @plugins_io_allowed_paths = Array(plugins_io.fetch("allowed_paths")).map(&:to_s).freeze
      @plugins_io_allowed_url_hosts = Array(plugins_io.fetch("allowed_url_hosts")).map(&:to_s).freeze
      @severity_profile = Coercion.coerce_severity_profile(
        data.fetch("severity_profile", DEFAULTS.fetch("severity_profile"))
      )
      @severity_overrides = Coercion.coerce_severity_overrides(
        data.fetch("severity_overrides", DEFAULTS.fetch("severity_overrides"))
      )
      @dependencies = Dependencies.from_h(
        data.fetch("dependencies", DEFAULTS.fetch("dependencies"))
      )
      parallel = DEFAULTS.fetch("parallel").merge(data.fetch("parallel", {}))
      @parallel_workers = Coercion.coerce_parallel_workers(parallel.fetch("workers"))
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
        # Issue #2742 — the loaded file's display path is part of the resolved configuration: two files
        # with identical bodies still anchor their config diagnostics differently, so the run-cache and
        # incremental fingerprints must tell them apart.
        "config_path" => config_display_path,
        # A stated `target_ruby` turns on the deprecation rules a defaulted one leaves off (#1692), so the run cache
        # key and the incremental fingerprint must tell the two apart even where the value matches.
        "target_ruby_explicit" => target_ruby_explicit?,
        "paths" => paths,
        "exclude" => exclude_patterns - BUILTIN_EXCLUDES,
        "plugins" => plugins,
        "disable" => disabled_rules,
        "libraries" => libraries,
        "signature_paths" => signature_paths,
        "core_root" => core_root,
        # `test_paths:` is deliberately absent, as `effects:` is: `to_h` feeds the run cache key and the
        # incremental-snapshot fingerprint, and the test roots change no diagnostic, so editing them must not
        # invalidate either. `sig_gen:` is absent for the same reason: only `rigor sig-gen` reads it.
        "pre_eval" => pre_eval,
        "fold_platform_specific_paths" => fold_platform_specific_paths,
        "parameter_inference" => parameter_inference,
        "cache" => {
          "path" => cache_path,
          "max_bytes" => cache_max_bytes,
          "validation" => cache_validation
        },
        "plugins_isolation" => plugins_isolation,
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

    # ADR-50 § WD2 — whether the bleeding-edge feature `id` is in force for this run.
    #
    # This is how a **behaviour** feature reaches its call site: a severity feature composes itself into
    # `bleeding_edge_severity_overrides` and needs no engine code, but a queued change to a measurement, an
    # algorithm, or a default has to be asked about where it happens. Answering from `Configuration` keeps
    # the selection logic in one place and puts nothing but the id — already ADR-50 WD1 contract vocabulary
    # — into engine code.
    #
    # Two deliberate asymmetries with the `bleeding_edge:` config key:
    #
    # - An id in {BleedingEdge::GRADUATED} answers `true` unconditionally. Graduation (§ WD7) turns a
    #   feature on for everyone, so a gate that outlives it keeps the graduated behaviour rather than
    #   silently reverting, and the call-site cleanup can land whenever it is convenient.
    # - An id that is in neither {BleedingEdge::FEATURES} nor {BleedingEdge::GRADUATED} **raises**. An
    #   unknown id in a *config file* stays inert on purpose (it may come from a newer gem — see
    #   {Coercion.coerce_bleeding_edge}), but an id here is written by a Rigor contributor against the registry in
    #   the same checkout: a typo is a bug, and reading it as `false` would ship the feature permanently off
    #   with no signal.
    #
    # @param id — a feature id from {BleedingEdge::FEATURES} or {BleedingEdge::GRADUATED}.
    # @raise ArgumentError — if `id` names no known feature.
    def bleeding_edge_active?(id)
      return true if BleedingEdge.graduated?(id)
      unless BleedingEdge.known_id?(id)
        raise ArgumentError,
              "unknown bleeding-edge feature id #{id.inspect}; known ids: " \
              "#{(BleedingEdge.feature_ids + BleedingEdge::GRADUATED).inspect}"
      end

      @bleeding_edge_active_ids.include?(id)
    end

    # ADR-50 § WD2 — returns a sibling Configuration whose bleeding-edge selection (and the derived
    # `bleeding_edge_severity_overrides` the two {SeverityProfile.resolve} sites consult) is replaced by
    # `value`, leaving every other field shared with the receiver. `value` takes the same forms as the
    # `bleeding_edge:` config key — `false` / `true` / a feature-id Array / `{ "all" => true, "except" =>
    # [...] }` — and is normalised through the same {Coercion.coerce_bleeding_edge} path, so an unknown id stays
    # inert.
    #
    # The CLI's `--bleeding-edge[=ids]` / `--no-bleeding-edge` flag uses this to override the configured
    # selection for a single run (the same CLI-over-config precedence `--workers` and `--no-cache` follow).
    # It is a frozen `dup` with the bleeding-edge ivars re-set: `dup` returns an unfrozen shallow copy
    # (every other ivar is the receiver's deeply-frozen value, safe to share read-only), the replacements
    # are themselves deeply frozen, and the re-`freeze` keeps the result `Ractor.shareable?` for the worker
    # path. **Every ivar `#initialize` derives from the bleeding-edge selector has to be re-derived here** — it
    # calls the same {#derive_bleeding_edge} and {#derive_effects} that `#initialize` does, so the selector,
    # the severity map, the active-id set and the `effects:` default (ADR-103 WD15's "effects-on-by-default")
    # all follow the new value, and a derived ivar added to `#initialize` is picked up without a second edit.
    def with_bleeding_edge(value)
      copy = dup
      copy.send(:derive_bleeding_edge, value)
      copy.send(:derive_effects)
      copy.freeze
    end

    # #1576 — a sibling Configuration whose relative `exclude:` patterns match against `dir` (nil: the working
    # directory). {Configuration.load} sets it to the loaded config file's directory.
    def with_exclude_base(dir)
      copy = dup
      copy.instance_variable_set(:@base_dir, dir && File.absolute_path(dir).freeze)
      copy.freeze
    end

    # Issue #2742 — a sibling Configuration recording which file {Configuration.load} read, so the
    # diagnostics anchored at "the configuration" name it ({#config_display_path}). `path` is the resolved
    # config path; nil — no file loaded, or a bare {Configuration.new} — keeps the `.rigor.yml` default.
    # Same frozen `dup` shape as {#with_exclude_base}.
    def with_config_path(path)
      copy = dup
      copy.instance_variable_set(:@config_path, path && File.absolute_path(path).freeze)
      copy.freeze
    end

    # #1777 — a sibling Configuration with only `baseline:` unset, every other field (including the
    # explicitness of `target_ruby`) shared with the receiver. `rigor baseline generate` analyses with
    # this so the generating run sees exactly the configuration `rigor check` will, minus the filter it
    # is about to replace; rebuilding from a key list let each unlisted key revert to its default.
    #
    # Same frozen `dup` shape as {#with_bleeding_edge}. `@baseline_path` is the only ivar
    # `#initialize` derives from the `baseline:` key.
    def without_baseline
      return self if baseline_path.nil?

      copy = dup
      copy.instance_variable_set(:@baseline_path, nil)
      copy.freeze
    end

    # ADR-103 WD14 — the ad-hoc opt-in `rigor effects` uses when the project's configuration carries no
    # `effects:` block: a sibling Configuration with an implicit empty block, every other field shared.
    # A configuration that already enables effects is returned unchanged, so a project's own settings
    # always win over the implicit ones.
    #
    # Same `dup` + re-`freeze` shape as {#with_bleeding_edge}: every other ivar is the receiver's deeply
    # frozen value, safe to share read-only, and the result stays `Ractor.shareable?` for the worker path.
    # The implicit block is recorded as a written empty one, so a later {#with_bleeding_edge} re-derives
    # it instead of falling back to the absent-key default and dropping it.
    def with_effects_enabled
      return self if effects_enabled?

      copy = dup
      copy.instance_variable_set(:@effects_key_present, true)
      copy.instance_variable_set(:@effects_written, {}.freeze)
      copy.send(:derive_effects)
      copy.freeze
    end

    private

    # ADR-50 § WD2 / ADR-103 WD15 — derives the bleeding-edge selector and the two ivars the
    # {#bleeding_edge_active?} predicate and the severity resolution read. `#initialize` and
    # {#with_bleeding_edge} both call this, so there is one derivation to keep in step.
    def derive_bleeding_edge(value)
      @bleeding_edge = Coercion.coerce_bleeding_edge(value)
      @bleeding_edge_severity_overrides = BleedingEdge.severity_overrides_for(@bleeding_edge)
      @bleeding_edge_active_ids = BleedingEdge.active_ids_for(@bleeding_edge)
    end

    # ADR-103 WD13 / WD15 — derives the `effects:` block and its snapshot and policy ivars from the raw
    # `effects:` input the instance kept (`@effects_written`, `@effects_key_present`). The effects-on-by-default
    # default reads the active-id set, so {#derive_bleeding_edge} must run first.
    def derive_effects
      @effects = coerce_effects(@effects_written, effects_key_present: @effects_key_present)
      coerce_effects_snapshot(@effects)
      coerce_effects_policy(@effects)
    end

    # ADR-103 WD13 — the `effects:` block, or nil when the key is absent or explicitly `false`. A
    # present-but-empty key (`effects:` alone, which YAML parses as nil) and `effects: {}` are the same
    # thing: collection on, every sub-key defaulted. A non-Hash body is normalised to `{}` rather than
    # rejected here: tier 1 (the schema) is where the body's shape is answered, and each sub-key reader
    # below validates its own value.
    #
    # ADR-103 WD15 — a loaded file that carries no `effects:` key AT ALL (`effects_key_present == false`,
    # so `value` can only be the `false` DEFAULTS fallback here, never a user's own explicit `false`) behaves
    # as `effects: {}` when the "effects-on-by-default" bleeding-edge feature is adopted. An explicit
    # `effects: false` — `effects_key_present == true` — always stays off regardless of the feature, and a
    # written block always wins outright: the feature can only fill an *absence*.
    def coerce_effects(value, effects_key_present:)
      return {}.freeze if value == false && !effects_key_present && effects_forced_on_by_bleeding_edge?
      return nil if value == false

      (value.is_a?(Hash) ? value : {}).freeze
    end

    # ADR-103 WD15 — guarded by {BleedingEdge.known_id?} rather than calling {#bleeding_edge_active?}
    # directly: that predicate RAISES for an id neither queued nor graduated, which is correct for a
    # contributor's typo against the registry in this same checkout, but a spec that stubs
    # `BleedingEdge::FEATURES` down to an unrelated single feature (a common pattern for isolating the
    # selector plumbing — see `spec/rigor/configuration_spec.rb`) must not have Configuration construction
    # explode merely because the id this internal default-application reads is not the one under test.
    def effects_forced_on_by_bleeding_edge?
      BleedingEdge.known_id?(EFFECTS_ON_BY_DEFAULT_FEATURE_ID) &&
        bleeding_edge_active?(EFFECTS_ON_BY_DEFAULT_FEATURE_ID)
    end

    # ADR-103 WD7 / WD14 — the snapshot keys and the minimal `tolerated:` policy list (#381).
    #
    # Every key resolves to its default when `effects:` is absent, so a consumer reads one uniform surface
    # and never has to ask whether the block was there. The values are read by `rigor effects update` /
    # `check` / `diff` / `explain` and by nothing on `rigor check`'s path.
    #
    # Validation is **tier 2** (`ArgumentError`, the run stops), because each of these is a value the
    # snapshot commands cannot proceed on: an unknown `gate:` would silently pick a semantics, an unknown
    # preset name would silently match no file, and a malformed label would silently tolerate nothing.
    # A label that is well-formed but unknown to the *registry* is deliberately NOT rejected here — that is
    # `effect.unknown-label`'s job (#384), and it fails open.
    def coerce_effects_snapshot(effects)
      @effects_check = Coercion.coerce_effects_check?(effects)
      snapshot = effects&.fetch("snapshot", nil)
      snapshot = {} unless snapshot.is_a?(Hash)
      @effects_snapshot_path = (snapshot.fetch("path", nil) || DEFAULT_EFFECTS_SNAPSHOT_PATH).to_s.freeze
      @effects_snapshot_reach = Coercion.coerce_effects_reach(snapshot.fetch("reach", nil))
      @effects_snapshot_gate = Coercion.coerce_effects_gate(snapshot.fetch("gate", nil))
      @effects_tolerated = Coercion.coerce_effects_tolerated(effects&.fetch("tolerated", nil))
    end

    # ADR-103 WD5 / WD6 / #385 — the three policy keys: the project's own vocabulary (`labels:`), its
    # attribution table for code Rigor does not analyse (`attribution:`), and its envelopes by convention
    # (`envelopes:`).
    #
    # Validation is **tier 2** for shape and tier 2 only. A label whose SPELLING is malformed, an entry
    # naming neither `match:` nor `namespace:` (or both), and an attribution key that is not a method key
    # each stop the run, because none of them has a reading the loader could pick. A label that is
    # well-formed but unknown to the *registry* is deliberately fine here: it fails open (⊤ for an
    # envelope, an unregistered meaning for an attribution) and surfaces as `effect.unknown-label`.
    def coerce_effects_policy(effects)
      @effects_labels = Coercion.coerce_effects_labels(effects&.fetch("labels", nil))
      @effects_attribution = Coercion.coerce_effects_attribution(effects&.fetch("attribution", nil))
      @effects_envelopes = Coercion.coerce_effects_envelopes(effects&.fetch("envelopes", nil))
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
