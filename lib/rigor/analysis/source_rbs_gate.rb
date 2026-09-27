# frozen_string_literal: true

require "digest"

module Rigor
  module Analysis
    # Issue #1536 (ADR-89 WD1 amendment) — what the incremental session knows about the RBS that source-RBS
    # synthesizers derive from each file's comments. The declaration gates read a file's Ruby side only; a
    # synthesizer's output reaches the environment as a `virtual:` buffer, and a reader of that RBS records no
    # edge back to the file, so the session asks this gate one question before deciding a closure: did the
    # edit move any synthesized output? A yes re-analyses the whole project.
    #
    # Each seed bundle carries its file's {Environment::SourceRbsSynthesis.digest} under {DIGEST_KEY}. The
    # gate writes it ({#stamp}), not the scope indexer that builds the rest of the bundle: the digest needs a
    # plugin registry, which discovery never sees.
    #
    # The synthesizers are read from a registry the gate loads for itself, WITHOUT `#prepare`, because the
    # closure is decided before the recheck runner (which loads and prepares its own) exists. That is exact
    # only for a synthesizer reachable without `#prepare`, so {#verify} compares the two sets after every run:
    # a plugin that builds its synthesizer in `#prepare` leaves the gate UNTRUSTED for the rest of the
    # session — every stored digest reads as unknown, and every edit re-analyses the whole project.
    class SourceRbsGate
      DIGEST_KEY = :source_rbs_digest

      def initialize(configuration:, cache_store:, plugin_requirer:)
        @configuration = configuration
        @cache_store = cache_store
        @plugin_requirer = plugin_requirer
        @synthesizers = nil
        @readings = nil
        @digested = false
        @untrusted = false
      end

      # True once a run's prepared registry declared a different synthesizer set from the one the gate
      # digests with. Sticky for the session: the configuration, and so the plugin set, is fixed for its life.
      def untrusted?
        @untrusted
      end

      # Whether this edit moved what any synthesizer contributes: a changed file whose digest differs from
      # the one on its snapshot bundle (or either is unknown), an added file that contributes anything, or a
      # removed file that did. Decided from the synthesizers' output, never from which plugins `plugins:`
      # names. The readings taken here are kept for {#stamp}.
      def moved?(bundles, changed, added, removed)
        return true if @untrusted && [changed, added, removed].any?(&:any?)

        @readings = (changed + added).to_h { |path| [path, reading(path)] }
        none = Environment::SourceRbsSynthesis::NO_CONTRIBUTION
        changed.any? { |path| !unmoved?(bundles, path) } ||
          added.any? { |path| @readings.fetch(path).last != none } ||
          removed.any? { |path| stored(bundles, path) != none }
      end

      # Every bundle the runner built this run (a baseline's all, a recheck's re-walked ones) gets its file's
      # digest; a bundle the runner reused keeps the one it carries, which stays exact because a bundle is
      # reused only for byte-identical content. Each digest is bound to the bytes its bundle was built from
      # ({#bound_digest}). An untrusted gate stamps every bundle unknown.
      def stamp(bundles)
        readings = @readings || {}
        @readings = nil
        return distrust(bundles) if @untrusted

        unstamped = bundles.reject { |_path, bundle| bundle.key?(DIGEST_KEY) }
        return bundles if unstamped.empty?

        stamped = bundles.dup
        unstamped.each do |path, bundle|
          stamped[path] = bundle.merge(DIGEST_KEY => bound_digest(path, bundle, readings[path]))
        end
        stamped
      end

      # Compares, by plugin id and order, the synthesizers the gate digested with against those of
      # `prepared_registry` — the registry the run's environment was built from, after `#prepare` (nil when
      # it could not be built, which also distrusts). On a mismatch the gate turns untrusted and every bundle
      # is stamped unknown, so no later run trusts a digest computed from the other set. A session that never
      # digested anything has nothing to distrust. Returns the bundles to keep.
      def verify(prepared_registry, bundles)
        return bundles unless @digested
        return bundles if synthesizer_ids(prepared_registry&.source_rbs_synthesizers) == synthesizer_ids(synthesizers)

        @untrusted = true
        distrust(bundles)
      end

      private

      def unmoved?(bundles, path)
        before = stored(bundles, path)
        !before.nil? && before == @readings.fetch(path).last
      end

      def stored(bundles, path)
        bundles[path]&.fetch(DIGEST_KEY, nil)
      end

      def distrust(bundles)
        bundles.transform_values { |bundle| bundle.merge(DIGEST_KEY => nil) }
      end

      # The digest for `bundle`, but only when it was read from the bytes the bundle was built from: a reading
      # taken from other bytes (the file was saved between the closure decision and the runner's discovery, or
      # while it was being read) is retaken once, and stored as unknown if it still does not match.
      def bound_digest(path, bundle, reading)
        reading = reading(path) unless reading && reading.first == bundle[:digest]
        reading.first == bundle[:digest] ? reading.last : nil
      end

      # `[content SHA-256, digest]`, the SHA nil unless the file read the same before and after the digest was
      # taken, so the pair can be matched against a bundle's content digest.
      def reading(path)
        @digested = true
        before = content_sha(path)
        digest = Environment::SourceRbsSynthesis.digest(synthesizers, path, @cache_store)
        [before && before == content_sha(path) ? before : nil, digest]
      end

      def content_sha(path)
        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        nil
      end

      def synthesizers
        @synthesizers ||= Runner::ProjectPrePasses.new(
          configuration: @configuration, cache_store: @cache_store, buffer: nil,
          plugin_requirer: @plugin_requirer, pool_mode: -> { false }
        ).prepared_registry(prepare: false).source_rbs_synthesizers
      end

      def synthesizer_ids(pairs)
        pairs&.map { |plugin, _| plugin.manifest.id.to_s }
      end
    end
  end
end
