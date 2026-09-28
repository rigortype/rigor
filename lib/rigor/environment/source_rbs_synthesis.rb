# frozen_string_literal: true

require "digest"
require_relative "../cache/value_digest"

module Rigor
  class Environment
    # ADR-32 WD5 — one plugin's `source_rbs_synthesizer` output for one source file, cached per (file content,
    # plugin entry, engine source). Two callers read it, and sharing the function is the point:
    #
    # - {Environment.collect_virtual_rbs} hands each output to the loader as a `virtual:` buffer;
    # - {.digest} reduces every loaded synthesizer's output for a file to one comparable value, which the
    #   incremental session (ADR-89 WD1, issue #1536) keeps on the file's seed bundle and compares across an
    #   edit.
    #
    # Because the digest reads the very function (and the very cache entries) the loader is fed from, "the
    # digest did not move" means "the loader read the same bytes for this file", not "some model of what
    # the plugin reads did not move". That is why it is taken from the output rather than from the file's
    # comment lines: rbs-inline binds an annotation by adjacency, so a plain comment or a blank line can move
    # one to another declaration, and in an annotated file every `def`, `attr`, constant and mixin gets a
    # skeleton whether or not it carries an annotation of its own.
    module SourceRbsSynthesis
      PRODUCER_ID = "plugin.source_rbs_synthesizer"

      # The digest of a file no loaded synthesizer contributes anything for — the answer for every file of a
      # project without an annotation, and for every file when no synthesizer is loaded at all. Not a hex
      # digest, so it can never collide with one.
      NO_CONTRIBUTION = "none"

      module_function

      # The cache stores the empty string `""` as the "no contribution" sentinel because `Cache::Store`
      # treats `nil` as a cache miss. Error tuples are stored as the canonical `[:error, message_string]`
      # Array so the same wrapper short-circuits subsequent runs against unchanged broken input.
      def output_for(plugin, callable, path, cache_store)
        return invoke_safely(callable, path) if cache_store.nil?
        return invoke_safely(callable, path) unless File.file?(path)

        descriptor = cache_descriptor(plugin, path)
        return invoke_safely(callable, path) if descriptor.nil?

        cache_store.fetch_or_compute(
          producer_id: PRODUCER_ID,
          params: {},
          descriptor: descriptor,
          generation_cap: generation_cap
        ) { invoke_safely(callable, path) || "" }
      end

      # Issue #1536 — every synthesizer's output for `path`, reduced to one value: {NO_CONTRIBUTION} when none
      # of them contributes anything, a SHA-256 hex digest of each plugin's id and {.contribution} otherwise,
      # and nil when an output could not be read at all.
      #
      # nil means "unknown", and a caller must treat it as moved. Every failure is per file: one plugin that
      # cannot answer for one file leaves every other file's digest intact.
      #
      # @param synthesizers — `Plugin::Registry#source_rbs_synthesizers` pairs.
      def digest(synthesizers, path, cache_store)
        sha = Digest::SHA256.new
        contributed = false
        synthesizers.each do |plugin, callable|
          tag, text = contribution(output_for(plugin, callable, path, cache_store))
          next if tag.nil?

          contributed = true
          sha << plugin.manifest.id.to_s.b << "\x00" << tag << "\x00" << text.to_s.b << "\x01"
        end
        contributed ? sha.hexdigest : NO_CONTRIBUTION
      rescue StandardError
        nil
      end

      # What one output puts into the environment, as a `[tag, text]` pair, or nil for nothing: exactly the
      # RBS {Environment.interpret_synthesizer_outcome} hands the loader. The ADR-32 WD6 / WD12 notices are left
      # out. They reach only the run-level `source-rbs-*` rows, which every run regenerates and the per-file
      # cache never serves, and they quote line numbers, so a line shift in a file carrying a malformed `#:`
      # would otherwise read as a moved contribution. A failed synthesis contributes nothing to the loader but
      # is kept as one stable value of its own, so a file flipping between "no annotation" and "broken
      # annotation" still reads as moved. Any shape the contract does not name is digested whole, by value: the
      # output is computed on one run and served from its cache entry on the next, and a digest of its
      # `Marshal.dump` bytes can differ between the two (issue #1574).
      #
      # The RBS text itself is digested whole, comments included. RBS reads a `# resolve-type-names: false`
      # magic comment at the start of a buffer, rbs-inline copies a `.rb` file's first comment line there, and
      # a string-literal type may span lines that start with `#`, so no line-based stripping is sound (#1549).
      def contribution(output)
        return nil if output.nil? || output == ""
        return ["rbs", output] if output.is_a?(String)
        return ["raw", Cache::ValueDigest.hexdigest(output)] unless output.is_a?(Array)

        case output[0]
        when :error then ["error", nil]
        when :ok then contribution(output[1])
        else ["raw", Cache::ValueDigest.hexdigest(output)]
        end
      end

      # One entry per (plugin, source file), all of them live for as long as the file is in the project — a
      # generation count says nothing about staleness here, so this producer declares itself out of
      # `Cache::Store#evict!`'s compaction pass and is bounded only by the size-based LRU pass. A method
      # rather than a constant: `Cache::Store` is not loaded yet when this file is.
      def generation_cap
        Cache::Store::UNBOUNDED_GENERATIONS
      end

      # The key composes the file's content SHA with the plugin's `PluginEntry` (id + version + config_hash),
      # so a config change or a content change invalidates the entry, and with the engine's source identity
      # (issue #1009): a plugin's manifest version does not move when a checkout edits its synthesizer, and
      # a stale string here also keeps the `rbs.virtual_rbs` env key warm, so the new build's rules would
      # read the old build's RBS.
      def cache_descriptor(plugin, path)
        Cache::Descriptor.new(
          files: [Cache::Descriptor::FileEntry.new(
            path: path.to_s,
            comparator: :digest,
            value: input_digest(path)
          )],
          plugins: [plugin.plugin_entry],
          configs: Cache::EngineSource.key_config_entries
        )
      rescue Cache::EngineSource::Unavailable
        # An engine that cannot be identified must not be keyed by its inputs alone (issue #1009): nil runs the
        # synthesizer uncached rather than serving an entry another build may have written.
        nil
      end

      def input_digest(path)
        Digest::SHA256.hexdigest(File.binread(path))
      rescue ::SystemCallError
        # Unreadable file → key on the path alone; the synthesizer's File.file?/File.read will see the same
        # failure and return nil.
        Digest::SHA256.hexdigest(path.to_s)
      end

      def invoke_safely(callable, path)
        callable.call(path.to_s)
      rescue StandardError
        # WD6 fail-soft — a synthesizer that raises does NOT crash analysis. Unlike the `[:error, msg]`
        # return path (which the runner surfaces as `source-rbs-synthesis-failed`), an unhandled raise is
        # swallowed silently; the unexamined-raise channel is deliberately silent per WD6.
        nil
      end

      private_class_method :contribution, :generation_cap, :cache_descriptor, :input_digest, :invoke_safely
    end
  end
end
