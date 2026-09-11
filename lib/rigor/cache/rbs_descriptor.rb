# frozen_string_literal: true

require "digest"

require_relative "descriptor"
require_relative "file_digest"

module Rigor
  module Cache
    # Shared descriptor builder for cache producers that depend on the RBS environment (constant table,
    # known-class set, future Marshal-clean reflection artefacts). Every consumer attaches the same three
    # slots, so factoring the construction here keeps the producers small and ensures invalidation behaves
    # identically across them.
    module RbsDescriptor
      def self.build(loader)
        Descriptor.new(
          gems: [rbs_gem_entry],
          files: file_entries(loader),
          configs: config_entries(loader) + env_only_config_entries(loader)
        )
      end

      # Lazy-files variant for the ADR-45 run-diagnostics record-and-validate cache. The cache KEY reads only
      # `gems` + `configs` ({Runner#run_key_descriptor}); the RBS signature-tree `files` are read solely on a
      # MISS, by the dependency descriptor ({Runner#run_dependency_descriptor}). So a warm HIT never digests
      # the (large, vendored) RBS tree. {RunDescriptor} is NOT a {Descriptor} — it is never composed, hashed,
      # or `==`'d, only its four readers are consulted — so deferring `files` costs no soundness, and `gems`
      # / `configs` match {.build}'s shared slots (the key is unchanged; the one slot the env key adds on
      # top, {.env_only_config_entries}, is never read here).
      def self.build_run(loader)
        RunDescriptor.new(loader: loader, gems: [rbs_gem_entry], configs: config_entries(loader))
      end

      # The `gems` + `configs` slots the run cache key reads. Cheap — no RBS env load, no file digesting
      # (only the configured library names + any plugin-synthesised virtual RBS are hashed).
      def self.config_entries(loader)
        [libraries_entry(loader.libraries), virtual_rbs_entry(loader)].compact
      end

      # Issue #610 — the slots only the env-cache KEY reads, on top of {.config_entries}. Which of the
      # loader's `signature_paths:` are DEFERRED (a bundled plugin's `sig/`, loaded last and allowed to
      # stand down against a colliding generic arity) changes the env built from byte-identical files, so
      # the partition belongs in the key: moving a plugin's `sig/` between `plugins:` and an explicit
      # `signature_paths:` entry changes no file, and an env cached before the producer honoured the
      # partition must read as a miss once. Kept OUT of {.config_entries} deliberately — the run-result
      # key already digests the whole resolved configuration (`RunCacheKey`), and its boot-slimming probe
      # reconstructs {.config_entries} without loading a plugin, so an entry there that it cannot rebuild
      # would turn the warm fast lane into a permanent miss on every project that enables a bundled plugin.
      def self.env_only_config_entries(loader)
        [deferred_signature_paths_entry(loader)].compact
      end

      def self.deferred_signature_paths_entry(loader)
        return nil unless loader.respond_to?(:deferred_signature_paths)

        deferred = Array(loader.deferred_signature_paths).map(&:to_s).sort
        return nil if deferred.empty?

        Descriptor::ConfigEntry.new(
          key: "rbs.deferred_signature_paths",
          value_hash: Digest::SHA256.hexdigest(deferred.join("\n"))
        )
      end

      private_class_method :deferred_signature_paths_entry

      # Public (ADR-87 WD4) so the boot-slimming run-cache probe reconstructs the identical `gems` +
      # `rbs.libraries` key slots the runner writes, from the config-derived library list, without a loader.
      def self.rbs_gem_entry
        Descriptor::GemEntry.new(name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION.to_s)
      end

      # @param comparator — `:digest` (default) for the env-cache KEY descriptor ({.build}), where the
      #   value must be deterministic; `:stat` (ADR-87 WD1) for the validation-only run-dependency descriptor
      #   ({RunDescriptor#files}), where the stat tier short-circuits the SHA-256 on an unmoved file.
      def self.file_entries(loader, comparator: :digest)
        roots = loader.signature_paths +
                Rigor::Environment::RbsLoader.vendored_gem_sig_paths +
                Rigor::Environment::RbsLoader.core_overlay_sig_paths +
                Rigor::Environment::RbsLoader.capability_role_sig_paths
        roots.flat_map do |root|
          next [] unless root.directory?

          Dir.glob(root.join("**", "*.rbs")).map do |path|
            digest = FileDigest.hexdigest(path)
            if comparator == :stat
              Descriptor::FileEntry.stat(path: path, digest: digest)
            else
              Descriptor::FileEntry.new(path: path, comparator: :digest, value: digest)
            end
          end
        end
      end

      # Issue #979 — the directory-LISTING rows for the signature roots, one {Descriptor::GlobEntry} per
      # root over `**/*.rbs`. {.file_entries} answers "did any signature file I read change", which is a
      # question only about files that existed when the run recorded its dependencies; a `sig/roles.rbs`
      # written afterwards is in no row, so the ADR-45 run-result slot validated fresh and the warm run kept
      # serving diagnostics computed without it. A glob row is the same edge {Plugin::IoBoundary} records
      # for a listed directory (#954): re-globbing on the next run sees the appearance, and one row per root
      # (not per file) keeps the cost a single `Dir.glob` + stat walk.
      #
      # Scoped to the loader's own roots — the project's `signature_paths:` (including the auto-detected
      # `sig/`), the bundled-plugin `sig/` trees (ADR-25), the bundle walk, `rbs collection`, the ADR-72
      # overlays. Rigor's own `data/` trees ({RbsLoader.vendored_gem_sig_paths}, `.core_overlay_sig_paths`,
      # `.capability_role_sig_paths`) are engine-owned: a file appears under one only when the engine tree is
      # edited, which normally arrives with the `lib/` change that reads it and so re-keys every
      # computed-value slot through {EngineSource}. They get file rows and no glob — a glob there would cost
      # every project a stat walk of the vendored gem-signature tree per warm run to catch an
      # engine-development edit.
      def self.glob_entries(loader)
        # Deduplicated by path: a root reachable twice (an explicit `signature_paths:` entry that is also a
        # bundled plugin's `sig/`, #610) would otherwise contribute two rows whose stat signatures race.
        loader.signature_paths.uniq(&:to_s).filter_map do |root|
          next unless root.directory?

          Descriptor::GlobEntry.compute(root: root.to_s, pattern: File.join("**", "*.rbs"))
        end
      end

      # @param library_names — the loader's merged library list (or, on the WD4 probe
      #   path, `Environment::DEFAULT_LIBRARIES + config.libraries` reconstructed without a loader).
      def self.libraries_entry(library_names)
        sorted = library_names.map(&:to_s).sort
        Descriptor::ConfigEntry.new(
          key: "rbs.libraries",
          value_hash: Digest::SHA256.hexdigest(sorted.join("\n"))
        )
      end

      # ADR-32 WD5 — encode the loader's virtual_rbs set into a `ConfigEntry` so the env cache invalidates when
      # a plugin-contributed synthesised RBS string changes (or appears for the first time). Returns nil when
      # the loader has no virtual_rbs entries, so callers without any synthesizer-emitting plugin pay zero
      # descriptor cost.
      def self.virtual_rbs_entry(loader)
        return nil unless loader.respond_to?(:virtual_rbs)
        return nil if loader.virtual_rbs.nil? || loader.virtual_rbs.empty?

        sorted_pairs = loader.virtual_rbs.sort_by { |name, _content| name }
        joined = sorted_pairs.map { |name, content| "#{name}\0#{content}" }.join("\n\0\n")
        Descriptor::ConfigEntry.new(
          key: "rbs.virtual_rbs",
          value_hash: Digest::SHA256.hexdigest(joined)
        )
      end

      private_class_method :virtual_rbs_entry

      # The lazy-files run descriptor {RbsDescriptor.build_run} returns. Exposes the four readers the
      # run-diagnostics cache consults — `gems` + `configs` are supplied eagerly (they feed the cache KEY,
      # and are cheap); `files` (the RBS signature-tree digests) and `globs` (#979, the per-root listing
      # rows) are read only on a MISS, computed once on first access and memoised, so a warm HIT pays for
      # neither.
      class RunDescriptor
        attr_reader :gems, :configs

        def initialize(loader:, gems:, configs:)
          @loader = loader
          @gems = gems
          @configs = configs
        end

        # Issue #979 — one directory-listing row per signature root, so a `.rbs` file APPEARING under one
        # (or vanishing from it) invalidates the run-result slot. Memoised for the same reason `files` is:
        # a collecting run asks twice about the same post-run world.
        def globs
          @globs ||= RbsDescriptor.glob_entries(@loader)
        end

        def files
          # ADR-87 WD1 — this descriptor is validated (never a cache key), so the RBS signature tree rides the
          # stat-then-digest `:stat` tier: a warm run stat-checks the (large, vendored) tree instead of
          # re-hashing it.
          @files ||= RbsDescriptor.file_entries(@loader, comparator: :stat)
        end
      end
    end
  end
end
