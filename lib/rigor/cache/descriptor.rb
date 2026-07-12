# frozen_string_literal: true

require "digest"
require "json"
require_relative "../value_semantics"
require_relative "file_digest"

module Rigor
  module Cache
    # Cache invalidation descriptor — the typed-slot schema fixed by
    # [`docs/design/20260505-cache-slice-taxonomy.md`](../../../docs/design/20260505-cache-slice-taxonomy.md).
    # Pure value object: no I/O, no global state, fully immutable after construction. The storage layer
    # ([`Rigor::Cache::Store`](store.rb), v0.0.8 slice 2) consumes descriptors but does not extend them.
    #
    # The descriptor has six slots (`files`, `gems`, `plugins`, `configs`, `dependencies`, `globs`); every slot is
    # an array of typed entries; an empty array means "no dependency in this slot". Composition unions by key per
    # slot; conflicts on the comparison fields raise {Conflict}.
    #
    # See ADR-2 § "Registration, Configuration, and Caching" for the design rationale and ADR-6 for the storage
    # backend decisions that consume this schema.
    class Descriptor
      # Bumped on incompatible schema changes. The storage layer mixes this into the cache key, so a bump
      # implicitly invalidates every cached value. v2 added the `dependencies` slot for ADR-10 per-gem-version
      # cache slice invalidation. v3: `RbsLoader.build_env_for` now synthesizes `module`s for namespaces a
      # project's `signature_paths:` RBS references but never declares, so the marshalled RBS env cached by an
      # older Rigor (which would leave those signatures inert) MUST be rebuilt for the synthesis to take effect.
      # v4: ADR-60 WD3 added the `globs` slot ({GlobEntry}) for the record-and-validate plugin-producer cache;
      # the new slot changes `#to_canonical_hash` (and is Marshal-dumped inside `fetch_or_validate` entry
      # pairs), so entries written by an older Rigor must read as misses.
      SCHEMA_VERSION = 4

      # Per-slot entry value objects. Constructors validate enums / required fields and freeze the resulting
      # struct so no caller can mutate after the entry is in a Descriptor.

      class FileEntry
        include Rigor::ValueSemantics

        VALID_COMPARATORS = %i[digest mtime exists].freeze

        attr_reader :path, :comparator, :value

        value_fields :path, :comparator, :value

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
      end

      class GemEntry
        include Rigor::ValueSemantics

        attr_reader :name, :requirement, :locked

        value_fields :name, :requirement, :locked

        def initialize(name:, requirement:, locked: nil)
          @name = name.to_s.dup.freeze
          @requirement = requirement.to_s.dup.freeze
          @locked = locked.nil? ? nil : locked.to_s.dup.freeze
          freeze
        end

        def to_h
          { "name" => name, "requirement" => requirement, "locked" => locked }
        end
      end

      class PluginEntry
        include Rigor::ValueSemantics

        attr_reader :id, :version, :config_hash

        value_fields :id, :version, :config_hash

        def initialize(id:, version:, config_hash: nil)
          @id = id.to_s.dup.freeze
          @version = version.to_s.dup.freeze
          @config_hash = config_hash.nil? ? nil : config_hash.to_s.dup.freeze
          freeze
        end

        def to_h
          { "id" => id, "version" => version, "config_hash" => config_hash }
        end
      end

      class ConfigEntry
        include Rigor::ValueSemantics

        attr_reader :key, :value_hash

        value_fields :key, :value_hash

        def initialize(key:, value_hash:)
          @key = key.to_s.dup.freeze
          @value_hash = value_hash.to_s.dup.freeze
          freeze
        end

        def to_h
          { "key" => key, "value_hash" => value_hash }
        end
      end

      # Per-(gem, version, mode) row carrying the cache slice boundary for ADR-10 dependency-source inference.
      # A `bundle update` that bumps a listed gem's pinned version produces a different `gem_version` here and
      # therefore a fresh cache key — invalidating exactly that gem's slice without disturbing other gems'
      # slices or the project's own cache.
      #
      # `mode` mirrors the [Configuration::Dependencies::VALID_MODES](../configuration/dependencies.rb) enum
      # (`:disabled` / `:when_missing` / `:full`); a mode change for the same gem also forces invalidation
      # because the inferred shapes depend on whether RBS overrides the walk.
      class DependencyEntry
        include Rigor::ValueSemantics

        VALID_MODES = %i[disabled when_missing full].freeze

        attr_reader :gem_name, :gem_version, :mode

        value_fields :gem_name, :gem_version, :mode

        def initialize(gem_name:, gem_version:, mode:)
          unless VALID_MODES.include?(mode)
            raise ArgumentError,
                  "DependencyEntry mode must be one of #{VALID_MODES.inspect}, got #{mode.inspect}"
          end

          @gem_name = gem_name.to_s.dup.freeze
          @gem_version = gem_version.to_s.dup.freeze
          @mode = mode
          freeze
        end

        def to_h
          { "gem_name" => gem_name, "gem_version" => gem_version, "mode" => mode.to_s }
        end
      end

      # ADR-60 WD3 — one glob's-worth of watched files, digested as a single value so the entry covers content
      # change, addition, AND removal in one row: the digest is the SHA-256 over the sorted
      # `"<path>\0<sha256-of-content>\n"` rows of every file matching `File.join(root, pattern)`. A new file
      # adds a row, a deleted file drops one, an edit changes one — all three move the digest.
      # {Descriptor#fresh?} re-runs the same computation and compares.
      class GlobEntry
        include Rigor::ValueSemantics

        attr_reader :root, :pattern, :value

        value_fields :root, :pattern, :value

        def initialize(root:, pattern:, value:)
          @root = root.to_s.dup.freeze
          @pattern = pattern.to_s.dup.freeze
          @value = value.to_s.dup.freeze
          freeze
        end

        # Builds the entry for the glob's CURRENT filesystem state.
        def self.compute(root:, pattern:)
          new(root: root, pattern: pattern, value: digest_for(root: root, pattern: pattern))
        end

        # The digest the entry's `value` carries. Per-file read failures (a file vanishing between the glob and
        # the digest) are treated as the file being absent — same race posture as
        # {Descriptor#file_entry_fresh?}.
        def self.digest_for(root:, pattern:)
          # Dir.glob returns sorted entries by default (sort: true), so the row order — and therefore the
          # digest — is stable.
          rows = Dir.glob(File.join(root, pattern)).filter_map do |path|
            next nil unless File.file?(path)

            "#{path}\0#{FileDigest.hexdigest(path)}\n"
          rescue StandardError
            nil
          end
          Digest::SHA256.hexdigest(rows.join)
        end

        # Composition key — {.compose} unions per (root, pattern) slot; two contributions for the same slot
        # must agree on the digest or {Conflict} is raised.
        def slot_key
          "#{root}\0#{pattern}"
        end

        def to_h
          { "root" => root, "pattern" => pattern, "value" => value }
        end
      end

      # Raised when {.compose} encounters incompatible entries under the same key (file digest mismatch,
      # gem-locked disagreement, …). Callers handle the exception by invalidating the cache slice rather than
      # choosing one contribution silently.
      class Conflict < StandardError; end

      attr_reader :files, :gems, :plugins, :configs, :dependencies, :globs

      def initialize(files: [], gems: [], plugins: [], configs: [], dependencies: [], globs: [])
        @files = files.dup.freeze
        @gems = gems.dup.freeze
        @plugins = plugins.dup.freeze
        @configs = configs.dup.freeze
        @dependencies = dependencies.dup.freeze
        @globs = globs.dup.freeze
        freeze
      end

      # ADR-45 — re-validates this descriptor's recorded {FileEntry}s against the current filesystem. Used by
      # the record-and-validate run-result cache: a value cached alongside its dependency descriptor is fresh
      # iff every recorded file still matches. Only `files` are checked — non-file inputs (config / gems /
      # version) belong in the cache *key*, not the validated dependency set — so a descriptor carrying any
      # non-file slot is never considered fresh (it was built wrong for this use). ADR-60 WD3 adds `globs`
      # alongside `files` as a re-validatable slot: a {GlobEntry} is fresh when re-globbing + re-digesting
      # reproduces its recorded value.
      def fresh?
        return false unless gems.empty? && plugins.empty? && configs.empty? && dependencies.empty?

        files.all? { |entry| file_entry_fresh?(entry) } &&
          globs.all? { |entry| glob_entry_fresh?(entry) }
      end

      # File-comparator strictness ordering. `:digest` is strictest (deterministic across machines); `:mtime`
      # is cheaper but local; `:exists` is the weakest signal. When two contributors disagree on the
      # comparator for the same `path`, the stricter one wins.
      COMPARATOR_STRICTNESS = { digest: 2, mtime: 1, exists: 0 }.freeze
      private_constant :COMPARATOR_STRICTNESS

      # Composes any number of descriptors into a single descriptor whose slots are the union of the inputs'
      # slots. Conflicts raise {Conflict}; idempotent contributions (same key, same value) collapse to a
      # single entry.
      def self.compose(*descriptors)
        return new if descriptors.empty?

        files = compose_files(descriptors.flat_map(&:files))
        gems = compose_by_key(descriptors.flat_map(&:gems), :name)
        plugins = compose_by_key(descriptors.flat_map(&:plugins), :id)
        configs = compose_by_key(descriptors.flat_map(&:configs), :key)
        dependencies = compose_by_key(descriptors.flat_map(&:dependencies), :gem_name)
        globs = compose_by_key(descriptors.flat_map(&:globs), :slot_key)
        new(files: files, gems: gems, plugins: plugins, configs: configs,
            dependencies: dependencies, globs: globs)
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

      # Canonical UTF-8 JSON serialisation. Slots appear in lexicographic order; entries are sorted by their
      # key field so two equivalent descriptors produce identical bytes.
      def to_canonical_bytes
        JSON.generate(to_canonical_hash).b
      end

      def to_canonical_hash
        {
          "configs" => sort_entries(configs, "key").map(&:to_h),
          "dependencies" => sort_entries(dependencies, "gem_name").map(&:to_h),
          "files" => sort_entries(files, "path").map(&:to_h),
          "gems" => sort_entries(gems, "name").map(&:to_h),
          "globs" => globs.sort_by { |e| [e.root, e.pattern] }.map(&:to_h),
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
        # Recursively coerces a Ruby value into a JSON-canonical structure: hash keys are stringified and
        # sorted; arrays preserve order; symbols stringify; everything else is JSON-renderable.
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

      def file_entry_fresh?(entry)
        case entry.comparator
        when :digest
          # `FileDigest` serves a per-run memo when a run is active (validation digests overlap the
          # dependency descriptor's), and falls back to a direct digest otherwise — same value either way.
          File.file?(entry.path) && FileDigest.hexdigest(entry.path) == entry.value
        when :mtime
          File.exist?(entry.path) && File.mtime(entry.path).to_i.to_s == entry.value
        when :exists
          File.exist?(entry.path).to_s == entry.value
        else
          false
        end
      rescue StandardError
        false
      end

      # ADR-60 WD3 — re-runs the entry's glob + digest and compares against the recorded value. Any failure
      # reads as stale (recompute), never a crash.
      def glob_entry_fresh?(entry)
        GlobEntry.digest_for(root: entry.root, pattern: entry.pattern) == entry.value
      rescue StandardError
        false
      end

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
