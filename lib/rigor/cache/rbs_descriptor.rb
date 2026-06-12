# frozen_string_literal: true

require "digest"

require_relative "descriptor"

module Rigor
  module Cache
    # Shared descriptor builder for cache producers that depend on the
    # RBS environment (constant table, known-class set, future
    # Marshal-clean reflection artefacts). Every consumer attaches the
    # same three slots, so factoring the construction here keeps the
    # producers small and ensures invalidation behaves identically
    # across them.
    module RbsDescriptor
      # @param loader [Rigor::Environment::RbsLoader]
      # @return [Rigor::Cache::Descriptor]
      def self.build(loader)
        Descriptor.new(
          gems: [rbs_gem_entry],
          files: file_entries(loader),
          configs: [libraries_entry(loader), virtual_rbs_entry(loader)].compact
        )
      end

      def self.rbs_gem_entry
        Descriptor::GemEntry.new(name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION.to_s)
      end

      def self.file_entries(loader)
        roots = loader.signature_paths +
                Rigor::Environment::RbsLoader.vendored_gem_sig_paths +
                Rigor::Environment::RbsLoader.core_overlay_sig_paths
        roots.flat_map do |root|
          next [] unless root.directory?

          Dir.glob(root.join("**", "*.rbs")).map do |path|
            Descriptor::FileEntry.new(
              path: path,
              comparator: :digest,
              value: Digest::SHA256.file(path).hexdigest
            )
          end
        end
      end

      def self.libraries_entry(loader)
        sorted = loader.libraries.map(&:to_s).sort
        Descriptor::ConfigEntry.new(
          key: "rbs.libraries",
          value_hash: Digest::SHA256.hexdigest(sorted.join("\n"))
        )
      end

      # ADR-32 WD5 — encode the loader's virtual_rbs set into a
      # `ConfigEntry` so the env cache invalidates when a
      # plugin-contributed synthesised RBS string changes (or
      # appears for the first time). Returns nil when the
      # loader has no virtual_rbs entries, so callers without
      # any synthesizer-emitting plugin pay zero descriptor
      # cost.
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

      private_class_method :rbs_gem_entry, :file_entries, :libraries_entry, :virtual_rbs_entry
    end
  end
end
