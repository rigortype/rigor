# frozen_string_literal: true

require "digest"

module Rigor
  module Cache
    # Cache producer that materialises every RBS-declared constant
    # to its translated `Rigor::Type` form and stores the result as
    # a `Hash<String, Rigor::Type>` keyed by canonical constant name.
    # This is the v0.0.8 first cached producer per ADR-6 § 7; it
    # caches a post-translation artefact so the cache value is
    # `Marshal`-clean (RBS-native objects carry `RBS::Location`,
    # which lacks `_dump_data`).
    #
    # Cache descriptor:
    #
    # - `gems`: the `rbs` gem (with the locked version) so a gem
    #   upgrade invalidates the table — bundled core + stdlib
    #   signatures live inside the gem.
    # - `files`: the digest of every `.rbs` file under the loader's
    #   `signature_paths` (project-supplied signatures that the
    #   gem's locked version cannot cover).
    # - `configs`: the SHA-256 of the loader's libraries list so
    #   adding/removing a stdlib library invalidates.
    class RbsConstantTable
      PRODUCER_ID = "rbs.constant_type_table"

      # @param loader [Rigor::Environment::RbsLoader]
      # @param store [Rigor::Cache::Store]
      # @return [Hash{String => Rigor::Type}]
      def self.fetch(loader:, store:)
        descriptor = build_descriptor(loader)
        store.fetch_or_compute(producer_id: PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end

      def self.build_descriptor(loader)
        Descriptor.new(
          gems: [rbs_gem_entry],
          files: file_entries(loader),
          configs: [libraries_entry(loader)]
        )
      end

      def self.compute(loader)
        loader.constant_names.each_with_object({}) do |name, table|
          translated = loader.constant_type(name)
          table[name] = translated unless translated.nil?
        end
      end

      def self.rbs_gem_entry
        Descriptor::GemEntry.new(name: "rbs", requirement: ">= 0", locked: ::RBS::VERSION.to_s)
      end

      def self.file_entries(loader)
        loader.signature_paths.flat_map do |root|
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

      private_class_method :build_descriptor, :compute,
                           :rbs_gem_entry, :file_entries, :libraries_entry
    end
  end
end
