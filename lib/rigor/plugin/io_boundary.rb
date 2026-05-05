# frozen_string_literal: true

require "digest"

require_relative "access_denied_error"

module Rigor
  module Plugin
    # Analyzer-side helper plugins go through to read files and
    # (eventually) reach the network. The boundary enforces the
    # active {TrustPolicy} and accumulates a {Cache::Descriptor}
    # of every read so plugin contributions stay invalidatable
    # alongside their inputs.
    #
    # ADR-2 § "Plugin Trust and I/O Policy" is the binding
    # contract. The boundary is **not** a sandbox: a plugin that
    # uses `File.read` directly bypasses everything here, and the
    # ADR explicitly accepts that trade-off. The discipline is:
    # when plugin code goes through this surface, reads stay
    # within the trust scope and feed the cache descriptor;
    # contributions built on top of out-of-scope reads will not
    # invalidate correctly.
    #
    # Slice 2 ships a minimal surface:
    #
    # - `#read_file(path)` — validates against the policy, returns
    #   the file's contents, and adds a digest-keyed
    #   {Cache::Descriptor::FileEntry} to the boundary's
    #   accumulated descriptor.
    # - `#open_url(url)` — always raises {AccessDeniedError} while
    #   `network_policy` is `:disabled` (the only setting in slice
    #   2). The hook exists so slices 3-6 can layer richer access
    #   policy without re-defining the API.
    # - `#cache_descriptor` — flushes the accumulated entries into
    #   a fresh {Cache::Descriptor} for the contribution that
    #   built it.
    class IoBoundary
      attr_reader :policy, :plugin_id

      def initialize(policy:, plugin_id:)
        @policy = policy
        @plugin_id = plugin_id.to_s.dup.freeze
        @file_entries = {}
        @mutex = Mutex.new
      end

      # Reads the file at `path` after validating it against the
      # policy. Raises {AccessDeniedError} when the path is outside
      # every allowed read root. Records a `:digest` {FileEntry}
      # so the resulting cache slice invalidates on content change.
      def read_file(path)
        absolute = File.expand_path(path.to_s)
        unless @policy.allow_read?(absolute)
          raise AccessDeniedError.new(
            "plugin #{@plugin_id.inspect} cannot read #{absolute.inspect}: " \
            "path is outside the trusted-read scope",
            reason: :read_outside_scope,
            resource: absolute
          )
        end

        contents = File.binread(absolute)
        record_file_entry(absolute, contents)
        contents
      end

      # Slice 2 stub: every URL access is denied while
      # `network_policy` is `:disabled`. Slices that need to relax
      # the rule (e.g. for opt-in offline-replay caches) will lift
      # the policy gate; the API does not change.
      def open_url(url)
        unless @policy.network_allowed?
          raise AccessDeniedError.new(
            "plugin #{@plugin_id.inspect} cannot open URL #{url.inspect}: " \
            "network access is disabled during analysis",
            reason: :network_disabled,
            resource: url.to_s
          )
        end

        raise NotImplementedError, "URL fetch surface is reserved; slice 2 only ships the deny path"
      end

      # @return [Rigor::Cache::Descriptor] frozen snapshot of every
      #   file the boundary has read so far. Calling this multiple
      #   times yields equal descriptors; subsequent reads expand
      #   the underlying record table.
      def cache_descriptor
        entries = @mutex.synchronize { @file_entries.values.dup }
        Cache::Descriptor.new(files: entries)
      end

      private

      def record_file_entry(path, contents)
        digest = Digest::SHA256.hexdigest(contents)
        entry = Cache::Descriptor::FileEntry.new(path: path, comparator: :digest, value: digest)
        @mutex.synchronize { @file_entries[path] = entry }
      end
    end
  end
end
