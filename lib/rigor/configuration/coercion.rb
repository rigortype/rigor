# frozen_string_literal: true

require_relative "../configuration_error"
require_relative "../effects/entry_points"
require_relative "../effects/label"
require_relative "../effects/method_key"
require_relative "../rooted_glob"
require_relative "defaults"
require_relative "severity_profile"

module Rigor
  class Configuration
    # The validators and normalisers `Configuration#initialize` runs over each key of a loaded file. Each is a
    # function of its arguments: it returns the coerced value or raises {ConfigurationError}, and reads no
    # `Configuration` state, so the methods are `module_function` entries called as `Coercion.coerce_x(value)`.
    # The coercions that write instance variables or ask the bleeding-edge selector (`coerce_effects`,
    # `coerce_effects_snapshot`, `coerce_effects_policy`) stay on `Configuration`.
    #
    # Only the methods `Configuration` calls are public; the helpers behind them are `private_class_method`.
    module Coercion # rubocop:disable Metrics/ModuleLength
      module_function

      # `effects.check:` — true by default under a present block, and never true without one. Only an
      # explicit `false` turns it off; any other value is normalised to true rather than rejected, because a
      # switch whose only two readings are "check" and "do not check" has nothing a tier-2 error would add.
      def coerce_effects_check?(effects)
        return false if effects.nil?

        effects.fetch("check", true) != false
      end

      VALID_EFFECTS_GATES = %i[symmetric additions].freeze
      private_constant :VALID_EFFECTS_GATES

      def coerce_effects_gate(value)
        return :symmetric if value.nil?

        gate = value.to_s.to_sym
        unless VALID_EFFECTS_GATES.include?(gate)
          raise ConfigurationError,
                "effects.snapshot.gate must be one of #{VALID_EFFECTS_GATES.inspect}, got #{value.inspect}"
        end

        gate
      end

      # Entry-point globs and preset names, kept as written.
      #
      # **Shape only.** A preset is *named by a plugin* (#387; ADR-103 WD14) and plugins load from this very
      # configuration, so at this point no preset is registered yet and asking `EntryPoints.known?` would
      # reject `reach: [rails]` for every project that uses one. The existence check therefore lives where
      # the snapshot expands `reach:` ({Effects::Snapshot.expand_reach}), which runs after plugin load and
      # raises there — the same error, at the first moment it can be right.
      def coerce_effects_reach(value)
        entries = Array(value).map(&:to_s)
        entries.each do |entry|
          next if Effects::EntryPoints.glob?(entry) || Effects::EntryPoints.name?(entry)

          raise ConfigurationError,
                "effects.snapshot.reach entry is neither a file glob nor a well-formed entry-point preset " \
                "name: #{entry.inspect} (a preset name is #{Effects::EntryPoints::NAME_PATTERN.inspect}; " \
                "anything carrying a path or glob character is treated as a file glob instead)"
        end
        entries.uniq.freeze
      end

      # Shape validation only: the label grammar of `docs/type-specification/effect-labels.md`.
      def coerce_effects_tolerated(value)
        labels = Array(value).map(&:to_s)
        labels.each do |label|
          raise ConfigurationError, "effects.tolerated is not a well-formed effect label: #{label.inspect}" unless
            Effects::Label.valid?(label)
        end
        labels.uniq.sort.freeze
      end

      NO_ATTRIBUTION = {}.freeze
      private_constant :NO_ATTRIBUTION

      def coerce_effects_labels(value)
        labels = Array(value).map(&:to_s)
        labels.each do |label|
          raise ConfigurationError, "effects.labels is not a well-formed effect label: #{label.inspect}" unless
            Effects::Label.valid?(label)
        end
        labels.uniq.sort.freeze
      end

      # `{ "Net::HTTP.get" => ["io.net.http"] }` — a method key exactly as the symbol tables spell one
      # (`Owner#instance`, `Owner.singleton`), mapped to the labels a call to it contributes.
      def coerce_effects_attribution(value)
        return NO_ATTRIBUTION unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, labels), out|
          name = key.to_s
          unless Effects::MethodKey.valid?(name)
            raise ConfigurationError,
                  "effects.attribution key is not a method key (`Owner#method` / `Owner.method`): #{name.inspect}"
          end

          out[name] = coerce_effect_label_list(Array(labels), "effects.attribution[#{name.inspect}]")
        end.freeze
      end

      # `[{ match: | namespace:, effect: [...] }]`. Exactly one selector per entry: an entry naming both
      # would need a precedence rule between two selectors of the same entry, and one naming neither selects
      # every class in the project, which is never what an author meant to write.
      def coerce_effects_envelopes(value)
        Array(value).each_with_index.map { |entry, index| coerce_effects_envelope(entry, index) }.freeze
      end

      def coerce_effects_envelope(entry, index)
        where = "effects.envelopes[#{index}]"
        raise ConfigurationError, "#{where} is not a mapping: #{entry.inspect}" unless entry.is_a?(Hash)

        match = coerce_effects_envelope_selector(entry["match"], "#{where}.match")
        namespace = coerce_effects_envelope_selector(entry["namespace"], "#{where}.namespace")
        if match.nil? == namespace.nil?
          raise ConfigurationError, "#{where} must name exactly one of `match:` (a path glob) or `namespace:` " \
                                    "(a constant glob), got #{match.nil? ? 'neither' : 'both'}"
        end
        unless entry.key?("effect")
          raise ConfigurationError, "#{where} has no `effect:` bound (write `effect: []` for the empty envelope)"
        end

        {
          "match" => match, "namespace" => namespace,
          "effect" => coerce_effect_label_list(Array(entry["effect"]), "#{where}.effect")
        }.freeze
      end

      def coerce_effects_envelope_selector(value, where)
        return nil if value.nil?

        selector = value.to_s
        raise ConfigurationError, "#{where} is empty" if selector.strip.empty?

        selector.freeze
      end

      def coerce_effect_label_list(labels, where)
        labels.map(&:to_s).each do |label|
          raise ConfigurationError, "#{where} is not a well-formed effect label: #{label.inspect}" unless
            Effects::Label.valid?(label)
        end.uniq.sort.freeze
      end

      # ADR-17 slice 4 — `pre_eval:` glob expansion. Each entry is accepted as either a literal path (slice 1
      # contract) OR a `File.fnmatch?`-shaped glob pattern (`lib/core_ext/**/*.rb`). Glob meta characters (`*`,
      # `?`, `[`) trigger `Dir.glob` expansion; the resulting file list is folded into the `pre_eval:` set with
      # `uniq`. Literal entries that don't exist on disk continue to surface as `pre-eval.file-not-found`
      # `:error` (slice 1 behaviour); glob entries that match nothing degrade silently to "no contribution from
      # this entry" so a templated `**` pattern in a fresh project doesn't generate an error per match-less
      # pattern.
      def expand_pre_eval_entries(entries)
        entries.flat_map { |entry| expand_pre_eval_entry(entry) }.uniq.freeze
      end

      # #1956 — a relative entry arrives joined onto the config file's directory, so the metacharacters the
      # check above sees may be that directory's own (`ds [x]/`). The leading run of segments that name existing
      # directories is read literally and only the rest is globbed under it: a literal entry under such a
      # directory stays a literal path, and a pattern matches what it matches under a plain directory.
      def expand_pre_eval_entry(entry)
        return [entry] unless glob_pattern?(entry)

        base, pattern = literal_directory_prefix(entry)
        return [entry] unless glob_pattern?(pattern)

        base ? RootedGlob.glob(base, pattern) : Dir.glob(entry, sort: true)
      end

      def literal_directory_prefix(entry)
        segments = entry.split("/")
        count = (1...segments.size).take_while { |n| File.directory?(join_segments(segments.take(n))) }.size
        return [nil, entry] if count.zero?

        [join_segments(segments.take(count)), segments.drop(count).join("/")]
      end

      # `"/a".split("/")` leads with an empty segment, which spells the filesystem root.
      def join_segments(segments)
        path = segments.join("/")
        path.empty? ? "/" : path
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
          raise ConfigurationError,
                "plugin configuration entry must be a String or Hash, got #{entry.inspect}"
        end
      end

      # `target_ruby` is passed as Prism's `version:` option at the analyser's parse sites
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
          raise ConfigurationError,
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
        raise ConfigurationError, "parallel.workers must be >= 0, got #{value.inspect}" if integer.negative?

        integer
      rescue TypeError, ArgumentError => e
        raise ConfigurationError, "parallel.workers must be a non-negative Integer, got #{value.inspect} (#{e.message})"
      end

      # Issue #2517 — the directory's existence and contents are checked where the environment is built
      # ({Environment::CoreRoot.validate!}), not here: `rigor init`, `rigor doctor` and the language server's reload
      # load a configuration without building an environment, and must still be able to read one naming a core that
      # is not generated yet.
      def coerce_core_root(value)
        return nil if value.nil?
        raise ConfigurationError, "core_root must be a directory path, got #{value.inspect}" unless value.is_a?(String)
        raise ConfigurationError, "core_root must not be empty" if value.strip.empty?

        value.dup.freeze
      end

      # ADR-22 WD2 (b) — `baseline: <path>` activates the file; `baseline: false` is the explicit-disable form
      # (useful in `.rigor.yml` to override an upstream `.rigor.dist.yml` that names a baseline). `nil`
      # (default / absent key) is also "no baseline".
      def coerce_baseline_path(value)
        return nil if value.nil? || value == false

        value.to_s
      end

      # ADR-87 WD1 — `cache.validation` is `"auto"` (default), `"stat"`, or `"digest"`. An unrecognised value
      # fails soft to `"auto"` rather than aborting a check over a typo, and the always-available
      # `RIGOR_STRICT_VALIDATION=1` env escape hatch does not depend on this value being valid.
      VALID_CACHE_VALIDATIONS = %w[auto stat digest].freeze
      private_constant :VALID_CACHE_VALIDATIONS

      # The `sig_gen.inline_declared:` values, as the Symbols {Configuration#sig_gen_inline_declared} answers.
      VALID_SIG_GEN_INLINE_DECLARED = %w[write skip].freeze
      private_constant :VALID_SIG_GEN_INLINE_DECLARED

      # Rejects rather than fails soft: an unrecognised value read as `write` would put a second declaration of
      # every inline-annotated method into `sig/` for exactly the project that asked for none. A `sig_gen:`
      # block that omits the key, or is written empty, keeps the default.
      def coerce_sig_gen_inline_declared(section)
        section = {} if section.nil?
        raise ConfigurationError, "sig_gen must be a mapping, got #{section.inspect}" unless section.is_a?(Hash)

        # The schema closes this object (`additionalProperties: false`); a misspelled key here would otherwise
        # load as the default and write exactly what `inline_declare: skip` was meant to prevent.
        unknown = section.keys.map(&:to_s) - Defaults::DEFAULTS.fetch("sig_gen").keys
        unless unknown.empty?
          raise ConfigurationError,
                "sig_gen has unknown key(s) #{unknown.inspect}; known keys: #{Defaults::DEFAULTS.fetch('sig_gen').keys.inspect}"
        end

        value = section.fetch("inline_declared", Defaults::DEFAULTS.dig("sig_gen", "inline_declared")).to_s
        unless VALID_SIG_GEN_INLINE_DECLARED.include?(value)
          raise ConfigurationError,
                "sig_gen.inline_declared must be one of #{VALID_SIG_GEN_INLINE_DECLARED.inspect}, " \
                "got #{section['inline_declared'].inspect}"
        end

        value.to_sym
      end

      def coerce_cache_validation(value)
        str = value.to_s
        VALID_CACHE_VALIDATIONS.include?(str) ? str : "auto"
      end

      # Rejects rather than fails soft — a strategy that silently resolves to a different one is exactly
      # the failure #911 exists to close, and the run's isolation is not a detail the user can be assumed
      # not to have meant.
      def coerce_plugins_isolation(value)
        return nil if value.nil?

        str = value.to_s
        return str if Defaults::CONFIGURABLE_PLUGIN_ISOLATIONS.include?(str)

        if str == "ruby_box"
          raise ConfigurationError,
                "plugins_isolation: ruby_box cannot be selected from the configuration file — `Ruby::Box` " \
                "must be active before Ruby boots. Run rigor with RIGOR_PLUGIN_ISOLATION=ruby_box instead " \
                "(the launcher re-execs itself with RUBY_BOX=1 set)."
        end

        raise ConfigurationError,
              "plugins_isolation must be one of #{Defaults::CONFIGURABLE_PLUGIN_ISOLATIONS.inspect} " \
              "(`ruby_box` is environment-only), got #{value.inspect}"
      end

      def coerce_network_policy(value)
        sym = value.to_sym
        unless VALID_NETWORK_POLICIES.include?(sym)
          raise ConfigurationError,
                "plugins_io.network must be one of #{VALID_NETWORK_POLICIES.inspect}, got #{value.inspect}"
        end

        sym
      end

      # ADR-8 § "Severity profile" — accepts the canonical Symbol form or its String spelling; rejects unknown
      # profile names so typos fail loudly.
      def coerce_severity_profile(value)
        sym = value.to_sym
        unless SeverityProfile::VALID_PROFILES.include?(sym)
          raise ConfigurationError,
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
        raise ConfigurationError, "severity_overrides must be a Hash, got #{value.inspect}" unless value.is_a?(Hash)

        value.to_h do |k, v|
          # YAML 1.1 parses bare `off`/`on`/`no`/`yes`/`true`/`false` as booleans, so a user who wrote `off` (a
          # valid severity) without quotes hands us `false`. Catch the non-Symbol / non-String case before
          # `to_sym` blows up with a backtrace.
          unless v.is_a?(String) || v.is_a?(Symbol)
            hint = v == false ? %( — did you mean the string "off"?) : ""
            raise ConfigurationError,
                  "severity_overrides[#{k.inspect}] is #{v.inspect}, a YAML boolean#{hint} " \
                  "Bare off/on/no/yes/true/false are parsed as booleans; quote the severity " \
                  "(e.g. \"off\")."
          end

          sym = v.to_sym
          unless SeverityProfile::VALID_SEVERITIES.include?(sym)
            raise ConfigurationError,
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
          raise ConfigurationError,
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

      private_class_method :coerce_effects_envelope, :coerce_effects_envelope_selector, :coerce_effect_label_list,
                           :expand_pre_eval_entry, :literal_directory_prefix, :join_segments, :glob_pattern?,
                           :coerce_bleeding_edge_hash, :freeze_ids
    end
  end
end
