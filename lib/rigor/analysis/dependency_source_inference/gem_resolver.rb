# frozen_string_literal: true

require_relative "../../cache/descriptor"

module Rigor
  module Analysis
    module DependencySourceInference
      # Maps a `Configuration::Dependencies::Entry` to the gem's on-disk installation directory by consulting
      # RubyGems (`Gem.loaded_specs` first, falling back to `Gem::Specification.find_by_name`). Returns either
      # a frozen {Resolved} value object or an {Unresolvable} value describing why the gem cannot participate
      # in this run.
      #
      # Resolution failures are surfaced as `dynamic.dependency-source.gem-not-found` diagnostics by
      # {Analysis::Runner} rather than crashing the run, so a missing gem in `dependencies.source_inference`
      # degrades cleanly to "no contributions from that gem" — every other gem and the project source remain
      # unaffected.
      module GemResolver
        # Successful resolution. `version` is the spec version as a String so it round-trips into cache
        # descriptors (slice 3) without leaking a `Gem::Version` instance through public surfaces.
        class Resolved < Data.define(:gem_name, :version, :gem_dir, :mode, :roots)
          def descriptor_key
            [gem_name, version, mode].freeze
          end

          # ADR-10 slice 3 — this gem's row of a cache descriptor: its name, resolved version and mode.
          def dependency_entry
            Cache::Descriptor::DependencyEntry.new(gem_name: gem_name, gem_version: version, mode: mode)
          end
        end

        # Unresolvable reasons. `:not_in_bundle` covers both the "RubyGems doesn't know this gem" case and the
        # `LoadError`-style raise from `find_by_name`. Future reasons (`:c_extension_only`, `:no_lib_root`) are
        # introduced as the walker discovers them in slice 2b.
        Unresolvable = Data.define(:gem_name, :reason)

        VALID_REASONS = %i[not_in_bundle].freeze

        module_function

        def resolve(entry)
          spec = locate_gem_spec(entry.gem)
          return Unresolvable.new(gem_name: entry.gem, reason: :not_in_bundle) if spec.nil?

          Resolved.new(
            gem_name: entry.gem,
            version: spec.version.to_s,
            gem_dir: spec.full_gem_path, # rigor:disable undefined-method
            mode: entry.mode,
            roots: entry.roots
          )
        end

        # Issue #1814 — the {Resolved#dependency_entry} of each non-disabled `dependencies.source_inference` entry that
        # resolves, in configuration order, without walking any gem. The run-result cache key and the incremental
        # snapshot's fingerprint are built before analysis from inputs that are cheap to read, and a gem's walked
        # source (its method catalogue, its refinement table, which modules it read in full) is an input of the
        # run that no analysed file records; a `Gemfile.lock` digest covers a `bundle update` and nothing else, so a
        # project with no lockfile, or a gem installed beside the bundle, would replay the diagnostics of the gem's
        # previous version. Unresolvable entries have no version to key on and add nothing: the gem appearing later
        # adds its row.
        def dependency_entries(dependencies)
          dependencies.source_inference.reject(&:disabled?).filter_map do |entry|
            resolved = resolve(entry)
            resolved.dependency_entry if resolved.is_a?(Resolved)
          end
        end

        # Locator. `Gem.loaded_specs` reflects the bundle (cheap lookup, no filesystem walk); `find_by_name` is
        # the broader fallback for gems present on the gem path but not yet `require`'d. `Gem::MissingSpecError`
        # is a `LoadError` subclass, so the rescue covers both missing-spec and load-error signals.
        def locate_gem_spec(name)
          Gem.loaded_specs[name] || begin
            Gem::Specification.find_by_name(name)
          rescue LoadError
            nil
          end
        end
      end
    end
  end
end
