# frozen_string_literal: true

module Rigor
  module Plugin
    # Declarative trust / I/O policy for the active plugin set.
    # Pinned by [ADR-2 § "Plugin Trust and I/O Policy"](../../../docs/adr/2-extension-api.md):
    # plugins are *trusted Ruby gems selected by the user, their
    # Gemfile, or project configuration*; this class is the
    # programmatic surface that documents that trust and lets the
    # analyzer enforce read scope + network disablement at the
    # documented edges.
    #
    # The policy is **not a sandbox.** A plugin that uses raw
    # `File.read` or `Net::HTTP` bypasses the policy — ADR-2
    # explicitly chooses documentation over forced isolation. The
    # contract is: when plugins go through {Rigor::Plugin::IoBoundary}
    # (the analyzer-side helper service slice 2 introduces), the
    # boundary checks against this policy and feeds compliant reads
    # into the cache descriptor for invalidation. Slices 3-6 wire
    # plugin contributions through the boundary so the policy is
    # the actual mechanism, not just paperwork.
    #
    # ## Fields
    #
    # - `trusted_gems`: gem names the user has authorised. Derived
    #   from the `plugins:` section of `.rigor.yml` plus any gems
    #   they reach transitively. Used today for documentation and
    #   future trust diagnostics.
    # - `allowed_read_roots`: absolute paths plugin code may read
    #   from through the {IoBoundary}. The default set covers the
    #   project root, the project's `signature_paths`, the active
    #   `Gemfile.lock`, and each trusted gem's
    #   `Gem::Specification#full_gem_path`. The user extends this
    #   with `.rigor.yml`'s `plugins_io.allowed_paths:`.
    # - `network_policy`: one of {VALID_NETWORK_POLICIES}.
    #   `:disabled` (default) makes {IoBoundary#open_url} always
    #   raise. `:allowlist` (v0.1.2) consults `allowed_url_hosts`
    #   on every fetch — the hostname must be on the list and
    #   the URL scheme MUST be `https`. The list of allowed hosts
    #   is exact-match (no wildcards in v0.1.2).
    class TrustPolicy
      VALID_NETWORK_POLICIES = %i[disabled allowlist].freeze

      attr_reader :trusted_gems, :allowed_read_roots, :network_policy, :allowed_url_hosts

      def initialize(trusted_gems: [], allowed_read_roots: [], network_policy: :disabled, allowed_url_hosts: [])
        validate_network_policy!(network_policy)

        @trusted_gems = trusted_gems.map { |g| g.to_s.dup.freeze }.uniq.sort.freeze
        @allowed_read_roots = allowed_read_roots
                              .map { |path| File.expand_path(path).freeze }
                              .uniq
                              .sort
                              .freeze
        @network_policy = network_policy
        @allowed_url_hosts = allowed_url_hosts.map { |h| h.to_s.downcase.dup.freeze }.uniq.sort.freeze
        freeze
      end

      # @param path [String]
      # @return [Boolean] true when the absolute path falls inside
      #   any allowed read root. Symlinks are resolved through
      #   `File.expand_path` only (no `realpath`); plugins with
      #   adversarial intent are out of scope per ADR-2.
      def allow_read?(path)
        absolute = File.expand_path(path.to_s)
        @allowed_read_roots.any? { |root| inside?(absolute, root) }
      end

      def network_allowed?
        @network_policy != :disabled
      end

      # @param url [String, URI]
      # @return [Boolean] true when the URL scheme is `https` and
      #   the parsed hostname is in `allowed_url_hosts`. Always
      #   `false` while `network_policy` is `:disabled`.
      def allow_url?(url)
        return false if @network_policy == :disabled
        return false if @allowed_url_hosts.empty?

        require "uri"
        uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
        return false unless uri.is_a?(URI::HTTPS)
        return false if uri.host.nil?

        @allowed_url_hosts.include?(uri.host.downcase)
      rescue URI::InvalidURIError
        false
      end

      def gem_trusted?(name)
        @trusted_gems.include?(name.to_s)
      end

      def to_h
        {
          "trusted_gems" => trusted_gems,
          "allowed_read_roots" => allowed_read_roots,
          "network_policy" => network_policy.to_s,
          "allowed_url_hosts" => allowed_url_hosts
        }
      end

      private

      def validate_network_policy!(policy)
        return if VALID_NETWORK_POLICIES.include?(policy)

        raise ArgumentError,
              "TrustPolicy network_policy must be one of #{VALID_NETWORK_POLICIES.inspect}, got #{policy.inspect}"
      end

      def inside?(absolute, root)
        return true if absolute == root

        prefix = "#{root}#{File::SEPARATOR}"
        absolute.start_with?(prefix)
      end
    end
  end
end
