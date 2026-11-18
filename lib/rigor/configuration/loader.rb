# frozen_string_literal: true

require "yaml"

require_relative "../config_path"
require_relative "../configuration_error"
require_relative "defaults"

module Rigor
  class Configuration
    # The class-level loader behind `Configuration.load`: file discovery, `includes:` resolution, the per-file path
    # resolution and the YAML read. `Configuration` keeps `load`, `discover`, `load_with_includes`,
    # `autowire_default_plugins`, `rbs_inline_plugin_entry?` and `rbs_inline_library_resolvable?` as one-line
    # delegates to the methods of the same name here; the rest are this module's own.
    #
    # It calls back into `Configuration` for exactly four things: `Configuration.new` and the two `with_*` siblings
    # {load} chains on the result, and `Configuration.rbs_inline_library_resolvable?`, which the auto-wire gate asks
    # through `Configuration` so a spec that stubs the probe there reaches it.
    module Loader
      # Top-level keys whose values are file/directory paths that MUST be resolved relative to the config
      # file's directory. `exclude:` is intentionally NOT in this list — its entries are glob patterns
      # (`**/vendor/**`), not paths.
      PATH_KEYS = %w[paths signature_paths test_paths pre_eval].freeze
      private_constant :PATH_KEYS

      # The single-path sibling of {PATH_KEYS}: resolved the same way, but kept a String rather than wrapped in an
      # Array.
      SCALAR_PATH_KEYS = %w[core_root].freeze
      private_constant :SCALAR_PATH_KEYS

      # ADR-93 WD2 — the one bundled plugin default-wired without a `plugins:` entry. `rigor-rbs-inline` is the
      # gem; `rbs-inline` is its manifest id (the loader raises on a duplicate id, so both forms count as
      # "already listed").
      AUTOWIRED_RBS_INLINE_GEM = "rigor-rbs-inline"
      AUTOWIRED_RBS_INLINE_ID = "rbs-inline"

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
        loaded = resolved && File.exist?(resolved) ? resolved : nil
        if loaded.nil?
          data = Defaults::DEFAULTS
          effects_key_present = false
          target_ruby_key_present = false
        else
          # ADR-103 WD15 — captured from the RAW, pre-`DEFAULTS.merge` file (+ its `includes:` chain) because
          # `DEFAULTS` itself carries an `"effects" => false` entry: once merged, "the file never wrote
          # `effects:`" and "the file wrote `effects: false`" collapse to the same value and become
          # indistinguishable to {Configuration#initialize}. This is the only place that distinction still exists.
          raw = load_with_includes(loaded)
          effects_key_present = raw.key?("effects")
          target_ruby_key_present = raw.key?("target_ruby")
          data = Defaults::DEFAULTS.merge(raw)
        end
        Configuration.new(autowire_default_plugins(data), effects_key_present, target_ruby_key_present || false)
                     .with_exclude_base(loaded && File.dirname(loaded))
                     .with_config_path(loaded)
      end

      # ADR-93 WD2 — default-wire the bundled `rigor-rbs-inline` plugin, in WD1's annotation-gated,
      # magic-comment-free mode, when the upstream `rbs-inline` library is resolvable and the user has not
      # already listed the plugin. Runs from {load} only — the real-project route — never from a bare
      # {Configuration.new}, so the suite's unit constructions do not auto-wire. The gate is presence-based
      # (ADR-72's shape): an annotation-free project pays only a comment scan and contributes nothing, so
      # wiring it on cannot regress the run. This partially reverses the ADR-27/ADR-31 auto-load deferral for
      # this one bundled plugin (the executed code is already vendored, not arbitrary third-party plugin code).
      # Opt out with a `plugins:` entry disabling it (`enabled: false`), or per-file `# rbs_inline: disabled`.
      def self.autowire_default_plugins(data)
        entries = Array(data["plugins"])
        return data if entries.any? { |entry| rbs_inline_plugin_entry?(entry) }
        return data unless Configuration.rbs_inline_library_resolvable?

        merged = data.dup
        merged["plugins"] = entries + [{
          "gem" => AUTOWIRED_RBS_INLINE_GEM,
          "id" => AUTOWIRED_RBS_INLINE_ID,
          "config" => { "require_magic_comment" => false }
        }]
        merged
      end

      # True when a `plugins:` entry (String or Hash, string- or symbol-keyed) already references the
      # `rigor-rbs-inline` plugin by gem name or by manifest id. Single-homed here so the CLI's
      # `--treat-all-as-inline-rbs` injection and the WD2 auto-wire gate agree on what "already listed" means.
      def self.rbs_inline_plugin_entry?(entry)
        case entry
        when String
          entry == AUTOWIRED_RBS_INLINE_GEM
        when Hash
          string_keyed = entry.to_h { |k, v| [k.to_s, v] }
          string_keyed["gem"] == AUTOWIRED_RBS_INLINE_GEM || string_keyed["id"] == AUTOWIRED_RBS_INLINE_ID
        else
          false
        end
      end

      # A probe with no load side effect: it does not `require` the library, only asks whether RubyGems can
      # resolve the name. `Gem::Specification.find_by_name` raises `Gem::MissingSpecError` (a `Gem::LoadError`)
      # when the gem is absent — the standalone `gem install rigortype` case, WD3's residual. ADR-90's
      # project-bundle fallback resolves the same name at the plugin's own `require` time.
      def self.rbs_inline_library_resolvable?
        Gem::Specification.find_by_name("rbs-inline")
        true
      rescue Gem::LoadError
        false
      end

      # Returns the path to the config file Rigor would load under auto-discovery, or `nil` when neither
      # candidate exists. Public so the CLI / spec drift checks can introspect the resolved file.
      def self.discover
        Defaults::DISCOVERY_ORDER.find { |candidate| File.exist?(candidate) }
      end

      # Reads `path` (which MUST exist) plus every file listed in its `includes:` chain, merging them under the
      # order: included files first (in declaration order), then the current file's own keys override.
      # Relative paths inside each file are resolved against that file's directory. Public so the CLI can run
      # the include-aware load before applying `--treat-all-as-inline-rbs`'s plugin injection (see
      # {CLI::CheckCommand#load_check_configuration}).
      def self.load_with_includes(path, visited: Set.new)
        absolute = File.absolute_path(path)
        raise ConfigurationError, "circular include: #{absolute}" if visited.include?(absolute)

        raw = read_yaml(absolute)
        raise ConfigurationError, "config file must be a YAML mapping: #{absolute}" unless raw.is_a?(Hash)

        base_dir = File.dirname(absolute)
        includes = Array(raw.delete("includes") || [])
        data = resolve_paths_in(raw, base_dir)
        next_visited = visited + [absolute]
        merge_includes(data, includes, base_dir, next_visited)
      end

      # #433's sibling: a typo in the file the user is about to be told to fix is a configuration mistake
      # like any other, and escaped as a `Psych::SyntaxError` backtrace naming a file inside Ruby's stdlib.
      # Psych's own `#message` embeds the path in a parenthesised prefix that reads badly after `rigor: `,
      # so the position is re-rendered in the `path:line:column` form the rest of Rigor's output uses.
      def self.read_yaml(absolute)
        YAML.safe_load_file(absolute, aliases: false) || {}
      rescue Psych::SyntaxError => e
        detail = [e.problem, e.context].compact.join(" ")
        raise ConfigurationError, "#{absolute}:#{e.line}:#{e.column}: not valid YAML: #{detail}"
      end

      def self.merge_includes(data, includes, base_dir, visited)
        return data if includes.empty?

        accumulated = {}
        includes.each do |inc|
          inc_path = ConfigPath.absolute(inc.to_s, base_dir)
          unless File.exist?(inc_path)
            raise ConfigurationError, "include not found: #{inc.inspect} (referenced from #{base_dir})"
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
        SCALAR_PATH_KEYS.each { |key| resolve_scalar_path_key!(out, key, base_dir) }
        resolve_plugins_io_paths!(out, base_dir)
        out
      end

      def self.resolve_path_key!(out, key, base_dir)
        return unless out.key?(key) && !out[key].nil?

        out[key] = Array(out[key]).map { |p| ConfigPath.absolute(p.to_s, base_dir) }
      end

      def self.resolve_scalar_path_key!(out, key, base_dir)
        return unless out.key?(key) && out[key].is_a?(String)

        out[key] = ConfigPath.absolute(out[key], base_dir)
      end

      def self.resolve_plugins_io_paths!(out, base_dir)
        plugins_io = out["plugins_io"]
        return unless plugins_io.is_a?(Hash) && plugins_io["allowed_paths"]

        duped = plugins_io.dup
        duped["allowed_paths"] = Array(plugins_io["allowed_paths"]).map { |p| ConfigPath.absolute(p.to_s, base_dir) }
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
        out["source_inference"] = left_si + right_si unless both_empty
        out
      end

      private_class_method :merge_includes, :resolve_paths_in, :deep_merge,
                           :merge_value, :merge_dependencies_hash
    end
  end
end
