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
          configs: config_entries(loader)
        )
      end

      # Lazy-files variant for the ADR-45 run-diagnostics record-and-validate cache. The cache KEY reads only
      # `gems` + `configs` ({Runner#run_key_descriptor}); the RBS signature-tree `files` are read solely on a
      # MISS, by the dependency descriptor ({Runner#run_dependency_descriptor}). So a warm HIT never digests
      # the (large, vendored) RBS tree. {RunDescriptor} is NOT a {Descriptor} — it is never composed, hashed,
      # or `==`'d, only its three readers are consulted — so deferring `files` costs no soundness, and `gems`
      # / `configs` are byte-identical to {.build} (the key is unchanged).
      def self.build_run(loader)
        RunDescriptor.new(loader: loader, gems: [rbs_gem_entry], configs: config_entries(loader))
      end

      # The `gems` + `configs` slots the run cache key reads. Cheap — no RBS env load, no file digesting
      # (only the configured library names + any plugin-synthesised virtual RBS are hashed).
      def self.config_entries(loader)
        [libraries_entry(loader.libraries), virtual_rbs_entry(loader)].compact
      end

      # Public (ADR-87 WD4) so the boot-slimming run-cache probe reconstructs the identical `gems` +
      # `rbs.libraries` key slots the runner writes, from the config-derived library list, without a loader.
      def self.rbs_gem_entry
        Descriptor::GemEntry.new(name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION.to_s)
      end

      # @rbs comparator: Symbol --
      #   `:digest` (default) for the env-cache KEY descriptor ({.build}), where the value must be deterministic;
      #   `:stat` (ADR-87 WD1) for the validation-only run-dependency descriptor ({RunDescriptor#files}), where the
      #   stat tier short-circuits the SHA-256 on an unmoved file.
      def self.file_entries(loader, comparator: :digest)
        roots = loader.signature_paths +
                Rigor::Environment::RbsLoader.vendored_gem_sig_paths +
                Rigor::Environment::RbsLoader.core_overlay_sig_paths
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

      # @rbs library_names: Array[String | Symbol] --
      #   The loader's merged library list (or, on the WD4 probe path, `Environment::DEFAULT_LIBRARIES +
      #   config.libraries` reconstructed without a loader).
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

      # The lazy-files run descriptor {RbsDescriptor.build_run} returns. Exposes the three readers the
      # run-diagnostics cache consults — `gems` + `configs` are supplied eagerly (they feed the cache KEY,
      # and are cheap); `files` (the RBS signature-tree digests, read only on a MISS) is computed once on
      # first access and memoised, so a warm HIT never pays for it.
      class RunDescriptor
        attr_reader :gems, :configs

        def initialize(loader:, gems:, configs:)
          @loader = loader
          @gems = gems
          @configs = configs
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
