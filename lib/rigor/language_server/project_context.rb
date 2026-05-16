# frozen_string_literal: true

require_relative "../environment"
require_relative "../cache/store"

module Rigor
  module LanguageServer
    # Per-session cache of the project-wide analyzer state the LSP
    # reads on every request — chiefly the `Environment` (with its
    # ~100-300ms RBS env build) and a read-only `Cache::Store` that
    # lets the runner hit the on-disk RBS cache without writing back.
    #
    # Slice 7 floor: caches `Environment.for_project` + cache_store
    # only. Synthetic-method / project-patched / plugin registries
    # are still rebuilt per request inside `Analysis::Runner.run`
    # (cheap relative to the env build). Full pre-pass caching is a
    # follow-up.
    #
    # Invalidation:
    # - `#invalidate!` drops the cached environment + bumps the
    #   generation counter; the next reader rebuilds.
    # - The cache store is NOT invalidated on file change — it's
    #   content-addressed (digests over file contents), so stale
    #   entries naturally lose their key match. We DO keep a single
    #   Store instance across the session so the in-process memo
    #   serves repeat reads cheaply.
    class ProjectContext
      attr_reader :configuration, :generation

      def initialize(configuration:)
        @configuration = configuration
        @generation = 0
        @environment = nil
        @cache_store = nil
      end

      # Returns the cached `Rigor::Environment` for this session,
      # building it on first access. Subsequent calls return the
      # same instance until `#invalidate!` drops the cache.
      def environment
        @environment ||= Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths,
          cache_store: cache_store
        )
      end

      # Returns the per-session read-only `Cache::Store`. Read-only
      # so multiple LSP sessions against the same project don't
      # race on cache writes — same contract editor mode v1 already
      # uses for the CLI `--tmp-file` path.
      def cache_store
        @cache_store ||= Cache::Store.new(root: @configuration.cache_path, read_only: true)
      end

      # Drops every cached collaborator and bumps the generation.
      # The next reader rebuilds from scratch. Triggered by
      # `workspace/didChangeWatchedFiles` for project source files
      # and by `workspace/didChangeConfiguration`.
      def invalidate!
        @generation += 1
        @environment = nil
        # Cache store stays — it's content-addressed; a stale env
        # build won't be served because the file digest mixed into
        # the cache key has changed.
        nil
      end
    end
  end
end
