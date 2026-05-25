# frozen_string_literal: true

require_relative "blueprint"

module Rigor
  module Plugin
    # Read-side query API over the plugins loaded for a single
    # `Analysis::Runner.run`. Constructed by
    # {Rigor::Plugin::Loader.load} and exposed downstream so the
    # contribution merger (slice 3) and diagnostic provenance
    # (slice 5) can iterate over loaded plugin instances in
    # deterministic order.
    #
    # The registry is read-only after construction; ordering is
    # the order in which {Rigor::Plugin::Loader} resolved
    # configuration entries, which is project-config order with
    # plugin-id alphabetical as the tie-breaker.
    #
    # ADR-15 Phase 3 — alongside the instantiated `plugins`, the
    # registry carries `blueprints`: a frozen, Ractor-shareable
    # `Array<Blueprint>` that records how to re-instantiate the
    # same plugin set in a worker Ractor. The eventual Phase 4
    # pool ships `blueprints` across the boundary and calls
    # {.materialize} per-Ractor; the live `plugins` carriage on
    # the coordinator registry stays unchanged.
    class Registry
      attr_reader :plugins, :load_errors, :blueprints

      # @param plugins [Array<Rigor::Plugin::Base>] instantiated
      #   plugin instances in deterministic order.
      # @param load_errors [Array<Rigor::Plugin::LoadError>] failures
      #   surfaced during loading. Each error is also turned into a
      #   diagnostic by the runner.
      # @param blueprints [Array<Rigor::Plugin::Blueprint>] frozen,
      #   Ractor-shareable replay descriptors aligned 1:1 with
      #   `plugins`. The loader fills this in; callers that
      #   construct Registry manually MAY pass `[]` and accept
      #   that {.materialize} cannot replay the set.
      def initialize(plugins: [], load_errors: [], blueprints: [])
        @plugins = plugins.dup.freeze
        @load_errors = load_errors.dup.freeze
        @blueprints = blueprints.dup.freeze
        freeze
      end

      # ADR-15 Phase 3 — build a fresh Registry from the supplied
      # blueprint set by replaying {Blueprint#materialize} per
      # entry against `services`. The returned registry carries
      # NEW plugin instances (mutable per-Ractor accumulators
      # included) and the same blueprint set, so a worker can
      # hand the materialised registry to Environment without
      # losing the replay handle. `load_errors` is intentionally
      # empty: load-time failures already surfaced in the
      # coordinator registry and don't repeat per worker.
      def self.materialize(blueprints:, services:)
        plugins = blueprints.map { |bp| bp.materialize(services: services) }
        new(plugins: plugins, blueprints: blueprints, load_errors: [])
      end

      def find(id)
        id_s = id.to_s
        plugins.find { |plugin| plugin.manifest.id == id_s }
      end

      def ids
        plugins.map { |plugin| plugin.manifest.id }
      end

      def empty?
        plugins.empty?
      end

      def any_load_errors?
        !load_errors.empty?
      end

      # ADR-13 slice 2 — flat ordered list of every loaded
      # plugin's manifest-declared {TypeNodeResolver} instances,
      # in plugin registration order. Slice 3 wires this into
      # the parser's resolver chain; until then the method is a
      # read-side aggregator only. The first non-nil
      # `#resolve(node, scope)` return wins per ADR-13 WD3 / WD5
      # — registration order is the user's lever.
      def type_node_resolvers
        plugins.flat_map { |plugin| plugin.manifest.type_node_resolvers }
      end

      # ADR-20 slice 6 — aggregate every loaded plugin's
      # manifest-declared HKT registrations + definitions
      # into a single `Inference::HktRegistry` overlay that
      # `Environment#hkt_registry` merges on top of the
      # bundled `Builtins::HktBuiltins.registry`. Last
      # plugin to register a URI wins (registration order
      # determined by the user's `plugins:` list); user
      # `.rbs` overlays merge on top of this overlay last.
      # Returns `Inference::HktRegistry::EMPTY` when no
      # plugin contributes HKT entries so callers can skip
      # the merge.
      def hkt_overlay_registry
        registrations = plugins.flat_map { |plugin| plugin.manifest.hkt_registrations }
        definitions = plugins.flat_map { |plugin| plugin.manifest.hkt_definitions }
        return Inference::HktRegistry::EMPTY if registrations.empty? && definitions.empty?

        Inference::HktRegistry.new(registrations: registrations, definitions: definitions)
      end

      # ADR-25 — flat, ordered list of every loaded plugin's
      # resolved RBS signature directories (absolute paths), in
      # plugin registration order. `Environment.for_project`
      # merges these into the signature-path set fed to
      # `RbsLoader`, alongside the configuration's `signature_paths:`
      # and the `bundler:` / `rbs_collection:` discovery output.
      def signature_paths
        plugins.flat_map(&:signature_paths)
      end

      # ADR-26 — the aggregate set of "open" receiver class names
      # declared across loaded plugins (manifest `open_receivers:`).
      # A class is open when a plugin vouches that it responds
      # beyond its RBS-declared method surface. `open_receiver?`
      # is the membership predicate `Analysis::CheckRules` consults
      # to skip the `call.undefined-method` rule for such a class.
      def open_receivers
        plugins.flat_map { |plugin| plugin.manifest.open_receivers }
      end

      def open_receiver?(class_name)
        return false if class_name.nil?

        open_receivers.include?(class_name.to_s)
      end

      # ADR-28 — flat, ordered list of every loaded plugin's
      # path-scoped method-protocol contracts, in plugin
      # registration order. Read from each plugin's
      # `#protocol_contracts` (which the manifest backs by default
      # but a plugin MAY override to fold in per-project config).
      # Consumed by `Inference::MethodParameterBinder` (the
      # parameter-type provision) and by contributing plugins'
      # `#diagnostics_for_file` hooks (the presence + return-type
      # check).
      def protocol_contracts
        plugins.flat_map(&:protocol_contracts)
      end

      # ADR-28 — the subset of `protocol_contracts` whose
      # `path_glob` matches `path`. Contract globs are authored
      # project-root-relative (`lib/controller/**/*.rb`); the
      # analyzer may hand this method either a project-relative
      # path (`rigor check` run from the project root) or an
      # absolute one (run from elsewhere, or a spec tmpdir), so the
      # glob is matched both directly and as a `**/`-prefixed path
      # suffix. `File::FNM_PATHNAME` keeps `*` from crossing `/`;
      # `File::FNM_EXTGLOB` enables `{a,b}` groups. Returns `[]` for
      # a nil path so the binder can call this unconditionally.
      def contracts_for_path(path)
        return [] if path.nil?

        path_s = path.to_s
        protocol_contracts.select { |contract| path_matches_glob?(contract.path_glob, path_s) }
      end

      # ADR-32 WD4 + WD5 — flat ordered list of
      # `[plugin, callable]` pairs for every loaded plugin that
      # declares a `source_rbs_synthesizer:` in its manifest. The
      # engine invokes each callable once per analysed Ruby source
      # file at env-build time; non-nil return strings are merged
      # into the RBS environment as virtual signature sources.
      # The full plugin instance is carried alongside the
      # callable so the engine's cache layer (WD5) can compose
      # `plugin.plugin_entry` into its per-file descriptor — a
      # config change to the plugin (e.g. flipping
      # `require_magic_comment:`) invalidates the dependent
      # synthesizer cache without any plugin-side bookkeeping.
      def source_rbs_synthesizers
        plugins.filter_map do |plugin|
          synthesizer = plugin.manifest.source_rbs_synthesizer
          next nil if synthesizer.nil?

          [plugin, synthesizer]
        end
      end

      FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      private_constant :FNMATCH_FLAGS

      EMPTY = new.freeze

      private

      def path_matches_glob?(glob, path)
        File.fnmatch?(glob, path, FNMATCH_FLAGS) ||
          File.fnmatch?(File.join("**", glob), path, FNMATCH_FLAGS)
      end
    end
  end
end
