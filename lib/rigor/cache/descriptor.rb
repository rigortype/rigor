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
      # v5: ADR-87 WD1/WD2 changed the dependency-side freshness format — {FileEntry} gains the `:stat`
      # comparator (a packed `digest + size + mtime_ns + ctime_ns + inode + recording_instant` tuple) and
      # {GlobEntry}'s aggregate signature is now a SHA-256 over per-file STAT tuples rather than per-file
      # content digests. Old entries must read as misses so the first writable run rebuilds them in the new
      # format for a clean one-shot migration (the #57 marker discipline: the bump clears the root and
      # reclaims the unreadable bytes).
      SCHEMA_VERSION = 5

      # Per-slot entry value objects. Constructors validate enums / required fields and freeze the resulting
      # struct so no caller can mutate after the entry is in a Descriptor.

      class FileEntry
        include Rigor::ValueSemantics

        # `:stat` (ADR-87 WD1) is the stat-then-digest comparator for the validation-only dependency
        # descriptor; its `value` packs the content digest PLUS a `(size, mtime_ns, ctime_ns, inode)` stat
        # tuple and the run's recording instant, so validation can skip the SHA-256 when the stat is unmoved.
        # It MUST NOT be placed in a descriptor used as a cache KEY (its value carries machine-local,
        # per-run-nondeterministic stat data); {RbsDescriptor.build}'s env-cache `files` therefore stay
        # `:digest`, while the {Runner} run-dependency descriptor and plugin {IoBoundary} reads use `:stat`.
        VALID_COMPARATORS = %i[digest stat mtime exists].freeze

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

        # ADR-87 WD1 — builds a `:stat` entry, packing the supplied content `digest` with the file's live stat
        # tuple. Falls back to a plain `:digest` entry when the file cannot be stat-ed (a race between the
        # digest and the stat), so the resulting entry is always valid to re-validate.
        def self.stat(path:, digest:)
          packed = FileDigest.pack_stat(path, digest)
          return new(path: path, comparator: :digest, value: digest) if packed.nil?

          new(path: path, comparator: :stat, value: packed)
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

      # ADR-60 WD3 / ADR-87 WD2 — one glob's-worth of watched files, covering content change, addition, AND
      # removal in a single aggregate `value`. Pre-ADR-87 the value was a SHA-256 over sorted
      # `"<path>\0<content-sha256>\n"` rows — sound but it re-READ + re-hashed every file's CONTENT on every
      # validation (the ~40 MB gitlab plugin-prepass tax). ADR-87 WD2 keeps the identical one-hash shape (small
      # to Marshal, deterministic, composition-safe) but hashes STAT TUPLES instead of content: the value is a
      # SHA-256 over sorted `"<path>\0<size>\0<mtime_ns>\0<ctime_ns>\0<inode>\n"` rows. {.fresh?} re-globs +
      # re-stats and compares — reading ZERO file-content bytes on an unchanged tree — while any content edit
      # (which moves mtime + ctime) still moves the signature. `RIGOR_STRICT_VALIDATION` / `cache.validation:
      # digest` restores the content-hash signature for a filesystem whose stat cannot be trusted. A single
      # aggregate hash is the right granularity here: a watched dependency is all-or-nothing (one changed file
      # invalidates the producer's cache regardless), so per-file partial re-hashing bought nothing but a heavy
      # per-file table to Marshal. The trade vs the old content signature is that a bare `touch` (moved stat,
      # identical content) now invalidates the glob — rare, and only forces the same recompute the old form
      # paid on EVERY run.
      class GlobEntry
        include Rigor::ValueSemantics

        ROW_SEPARATOR = "\n"
        FIELD_SEPARATOR = "\0"
        private_constant :ROW_SEPARATOR, :FIELD_SEPARATOR

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
          new(root: root, pattern: pattern, value: signature_for(root: root, pattern: pattern))
        end

        # The aggregate signature the entry's `value` carries: SHA-256 over the sorted per-file rows. In the
        # default (`:stat`) mode a row is the file's `(path, size, mtime_ns, ctime_ns, inode)` tuple — NO
        # content read; in strict mode a row is `(path, content-sha256)`, restoring the pre-ADR-87 authority.
        # Per-file stat failures (a file vanishing between the glob and the stat) drop the row — same race
        # posture as {Descriptor#file_entry_fresh?}. `Dir.glob` returns sorted entries by default so the row
        # order — and therefore the signature — is stable.
        def self.signature_for(root:, pattern:)
          strict = FileDigest.strict_validation?
          rows = Dir.glob(File.join(root, pattern)).filter_map do |path|
            st = File.stat(path)
            next nil unless st.file?

            if strict
              "#{path}#{FIELD_SEPARATOR}#{FileDigest.hexdigest(path)}#{ROW_SEPARATOR}"
            else
              "#{path}#{FIELD_SEPARATOR}#{st.size}#{FIELD_SEPARATOR}#{FileDigest.ns_of(st.mtime)}" \
                "#{FIELD_SEPARATOR}#{FileDigest.ns_of(st.ctime)}#{FIELD_SEPARATOR}#{st.ino}#{ROW_SEPARATOR}"
            end
          rescue StandardError
            nil
          end
          Digest::SHA256.hexdigest(rows.join)
        end

        # ADR-87 WD2 — fresh iff re-globbing + re-stat-ing reproduces the recorded signature. Zero file-content
        # bytes are read in the default mode. Any failure reads as stale (recompute), never a crash. A stored
        # signature recorded under the opposite validation mode simply mismatches and recomputes.
        def self.fresh?(entry)
          signature_for(root: entry.root, pattern: entry.pattern) == entry.value
        rescue StandardError
          false
        end

        # Composition key — {.compose} unions per (root, pattern) slot; two contributions for the same slot
        # must agree on the value or {Conflict} is raised. Within one run the same glob stat-reads identically,
        # so contributions never conflict.
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

      # File-comparator strictness ordering. `:stat` is strictest (it carries the content digest AND a stat
      # tuple, so it validates content-authoritatively while short-circuiting on an unmoved stat); `:digest` is
      # deterministic across machines; `:mtime` is cheaper but local; `:exists` is the weakest signal. Ranking
      # `:stat` and `:digest` apart guarantees a path contributed under both never raises a value {Conflict}
      # (their `value` strings differ by construction) — the stricter one wins and its value is used.
      COMPARATOR_STRICTNESS = { stat: 3, digest: 2, mtime: 1, exists: 0 }.freeze
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
        when :stat
          # ADR-87 WD1 — stat-then-digest: stat first, re-hash only when the tuple moved (or the racy window
          # fires, or strict mode forces it). A stat failure raises and the outer rescue reads it as stale.
          FileDigest.stat_fresh?(entry.path, entry.value)
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

      # ADR-60 WD3 / ADR-87 WD2 — stat-validates the entry's per-file table against the live tree, re-hashing
      # only stat-moved files. Any failure reads as stale (recompute), never a crash.
      def glob_entry_fresh?(entry)
        GlobEntry.fresh?(entry)
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
