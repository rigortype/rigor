# frozen_string_literal: true

require "digest"
require "json"

module Rigor
  module Cache
    # Cache invalidation descriptor — the typed-slot schema fixed by
    # [`docs/design/20260505-cache-slice-taxonomy.md`](../../../docs/design/20260505-cache-slice-taxonomy.md).
    # Pure value object: no I/O, no global state, fully immutable
    # after construction. The storage layer
    # ([`Rigor::Cache::Store`](store.rb), v0.0.8 slice 2) consumes
    # descriptors but does not extend them.
    #
    # The descriptor has four slots (`files`, `gems`, `plugins`,
    # `configs`); every slot is an array of typed entries; an empty
    # array means "no dependency in this slot". Composition unions
    # by key per slot; conflicts on the comparison fields raise
    # {Conflict}.
    #
    # See ADR-2 § "Registration, Configuration, and Caching" for
    # the design rationale and ADR-6 for the storage backend
    # decisions that consume this schema.
    class Descriptor # rubocop:disable Metrics/ClassLength
      # Bumped on incompatible schema changes. The storage layer
      # mixes this into the cache key, so a bump implicitly
      # invalidates every cached value.
      SCHEMA_VERSION = 1

      # Per-slot entry value objects. Constructors validate enums /
      # required fields and freeze the resulting struct so no caller
      # can mutate after the entry is in a Descriptor.

      class FileEntry
        VALID_COMPARATORS = %i[digest mtime exists].freeze

        attr_reader :path, :comparator, :value

        def initialize(path:, comparator:, value:)
          unless VALID_COMPARATORS.include?(comparator)
            raise ArgumentError,
                  "FileEntry comparator must be one of #{VALID_COMPARATORS.inspect}, got #{comparator.inspect}"
          end

          @path = path.to_s.dup.freeze
          @comparator = comparator
          @value = value.to_s.dup.freeze
          freeze
        end

        def to_h
          { "path" => path, "comparator" => comparator.to_s, "value" => value }
        end

        def ==(other)
          other.is_a?(FileEntry) && other.path == path && other.comparator == comparator && other.value == value
        end
        alias eql? ==

        def hash
          [self.class, path, comparator, value].hash
        end
      end

      class GemEntry
        attr_reader :name, :requirement, :locked

        def initialize(name:, requirement:, locked: nil)
          @name = name.to_s.dup.freeze
          @requirement = requirement.to_s.dup.freeze
          @locked = locked.nil? ? nil : locked.to_s.dup.freeze
          freeze
        end

        def to_h
          { "name" => name, "requirement" => requirement, "locked" => locked }
        end

        def ==(other)
          other.is_a?(GemEntry) && other.name == name && other.requirement == requirement && other.locked == locked
        end
        alias eql? ==

        def hash
          [self.class, name, requirement, locked].hash
        end
      end

      class PluginEntry
        attr_reader :id, :version, :config_hash

        def initialize(id:, version:, config_hash: nil)
          @id = id.to_s.dup.freeze
          @version = version.to_s.dup.freeze
          @config_hash = config_hash.nil? ? nil : config_hash.to_s.dup.freeze
          freeze
        end

        def to_h
          { "id" => id, "version" => version, "config_hash" => config_hash }
        end

        def ==(other)
          other.is_a?(PluginEntry) &&
            other.id == id && other.version == version && other.config_hash == config_hash
        end
        alias eql? ==

        def hash
          [self.class, id, version, config_hash].hash
        end
      end

      class ConfigEntry
        attr_reader :key, :value_hash

        def initialize(key:, value_hash:)
          @key = key.to_s.dup.freeze
          @value_hash = value_hash.to_s.dup.freeze
          freeze
        end

        def to_h
          { "key" => key, "value_hash" => value_hash }
        end

        def ==(other)
          other.is_a?(ConfigEntry) && other.key == key && other.value_hash == value_hash
        end
        alias eql? ==

        def hash
          [self.class, key, value_hash].hash
        end
      end

      # Raised when {.compose} encounters incompatible entries
      # under the same key (file digest mismatch, gem-locked
      # disagreement, …). Callers handle the exception by
      # invalidating the cache slice rather than choosing one
      # contribution silently.
      class Conflict < StandardError; end

      attr_reader :files, :gems, :plugins, :configs

      def initialize(files: [], gems: [], plugins: [], configs: [])
        @files = files.dup.freeze
        @gems = gems.dup.freeze
        @plugins = plugins.dup.freeze
        @configs = configs.dup.freeze
        freeze
      end

      # File-comparator strictness ordering. `:digest` is strictest
      # (deterministic across machines); `:mtime` is cheaper but
      # local; `:exists` is the weakest signal. When two
      # contributors disagree on the comparator for the same
      # `path`, the stricter one wins.
      COMPARATOR_STRICTNESS = { digest: 2, mtime: 1, exists: 0 }.freeze
      private_constant :COMPARATOR_STRICTNESS

      # Composes any number of descriptors into a single descriptor
      # whose slots are the union of the inputs' slots. Conflicts
      # raise {Conflict}; idempotent contributions (same key, same
      # value) collapse to a single entry.
      def self.compose(*descriptors)
        return new if descriptors.empty?

        files = compose_files(descriptors.flat_map(&:files))
        gems = compose_by_key(descriptors.flat_map(&:gems), :name)
        plugins = compose_by_key(descriptors.flat_map(&:plugins), :id)
        configs = compose_by_key(descriptors.flat_map(&:configs), :key)
        new(files: files, gems: gems, plugins: plugins, configs: configs)
      end

      # @param producer_id [String]
      # @param params [Hash] inputs the producer was called with
      # @return [String] hex SHA-256 cache key for the value
      def cache_key_for(producer_id:, params: {})
        payload = {
          "schema_version" => SCHEMA_VERSION,
          "producer_id" => producer_id.to_s,
          "params" => self.class.canonicalize_value(params),
          "descriptor" => to_canonical_hash
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      # Canonical UTF-8 JSON serialisation. Slots appear in
      # lexicographic order; entries are sorted by their key field
      # so two equivalent descriptors produce identical bytes.
      def to_canonical_bytes
        JSON.generate(to_canonical_hash).b
      end

      def to_canonical_hash
        {
          "configs" => sort_entries(configs, "key").map(&:to_h),
          "files" => sort_entries(files, "path").map(&:to_h),
          "gems" => sort_entries(gems, "name").map(&:to_h),
          "plugins" => sort_entries(plugins, "id").map(&:to_h)
        }
      end

      def ==(other)
        other.is_a?(Descriptor) &&
          to_canonical_bytes == other.to_canonical_bytes
      end
      alias eql? ==

      def hash
        to_canonical_bytes.hash
      end

      class << self
        # Recursively coerces a Ruby value into a JSON-canonical
        # structure: hash keys are stringified and sorted; arrays
        # preserve order; symbols stringify; everything else is
        # JSON-renderable.
        def canonicalize_value(value)
          case value
          when Hash
            value.to_a.map { |k, v| [k.to_s, canonicalize_value(v)] }.sort_by(&:first).to_h
          when Array
            value.map { |v| canonicalize_value(v) }
          when Symbol
            value.to_s
          else
            value
          end
        end
      end

      private

      def sort_entries(entries, key)
        entries.sort_by { |e| e.to_h.fetch(key).to_s }
      end

      def self.compose_by_key(entries, key)
        grouped = entries.group_by { |e| e.public_send(key) }
        grouped.map do |_k, group|
          unique = group.uniq
          if unique.size == 1
            unique.first
          else
            raise Conflict,
                  "cache descriptor conflict on #{key}=#{group.first.public_send(key).inspect}: " \
                  "got #{unique.size} incompatible entries"
          end
        end
      end
      private_class_method :compose_by_key

      def self.compose_files(entries)
        grouped = entries.group_by(&:path)
        grouped.map do |path, group|
          merge_file_group(path, group)
        end
      end
      private_class_method :compose_files

      def self.merge_file_group(path, group)
        strictest_rank = group.map { |e| COMPARATOR_STRICTNESS.fetch(e.comparator) }.max
        strictest = group.select { |e| COMPARATOR_STRICTNESS.fetch(e.comparator) == strictest_rank }
        values = strictest.map(&:value).uniq
        unless values.size == 1
          raise Conflict,
                "cache descriptor conflict on file=#{path.inspect}: " \
                "got #{values.size} disagreeing values under the stricter comparator"
        end

        strictest.first
      end
      private_class_method :merge_file_group
    end
  end
end
