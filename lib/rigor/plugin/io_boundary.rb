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
    # - `#open_url(url)` — fetches the URL when the policy
    #   permits it (`network_policy: :allowlist` plus an
    #   `allowed_url_hosts` match) and raises
    #   {AccessDeniedError} otherwise. v0.1.2 ships the
    #   allowlist surface; the default project policy still
    #   has `network_policy: :disabled` so plugins that want
    #   network access opt in explicitly through
    #   `.rigor.yml`'s `plugins_io.network: allowlist` plus
    #   `plugins_io.allowed_url_hosts: [...]`. The HTTP fetch
    #   is GET-only over HTTPS, capped at {URL_TIMEOUT_SECONDS}
    #   wall time and {URL_MAX_BYTES} body size; non-2xx
    #   responses raise {AccessDeniedError} so plugin code
    #   doesn't have to rescue mid-build.
    # - `#cache_descriptor` — flushes the accumulated entries into
    #   a fresh {Cache::Descriptor} for the contribution that
    #   built it. URL fetches contribute `ConfigEntry` rows
    #   keyed `"url:#{url}"` with the response body's SHA-256
    #   so contributions invalidate when the remote document
    #   changes.
    class IoBoundary
      URL_TIMEOUT_SECONDS = 10
      URL_MAX_BYTES = 10 * 1024 * 1024

      attr_reader :policy, :plugin_id

      def initialize(policy:, plugin_id:, http_client: DefaultHttpClient.new)
        @policy = policy
        @plugin_id = plugin_id.to_s.dup.freeze
        @file_entries = {}
        @config_entries = {}
        @http_client = http_client
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

      # Fetches the URL when the policy permits it. Returns the
      # response body. Raises {AccessDeniedError} when the policy
      # is `:disabled`, the URL scheme is not `https`, the host is
      # not on the allowlist, the response is non-2xx, the body
      # exceeds {URL_MAX_BYTES}, or the request times out
      # ({URL_TIMEOUT_SECONDS}). On success, records a
      # `ConfigEntry` keyed `"url:#{url}"` with the body's
      # SHA-256 so the cache descriptor invalidates if the remote
      # document changes.
      def open_url(url)
        url_string = url.to_s
        unless @policy.allow_url?(url_string)
          raise AccessDeniedError.new(
            "plugin #{@plugin_id.inspect} cannot open URL #{url.inspect}: " \
            "URL is not permitted by the active TrustPolicy " \
            "(network_policy=#{@policy.network_policy} allowed_url_hosts=#{@policy.allowed_url_hosts.inspect})",
            reason: :network_disabled,
            resource: url_string
          )
        end

        body = @http_client.get(url_string, timeout: URL_TIMEOUT_SECONDS, max_bytes: URL_MAX_BYTES)
        record_url_entry(url_string, body)
        body
      end

      # @return [Rigor::Cache::Descriptor] frozen snapshot of every
      #   file / URL the boundary has read so far. Calling this
      #   multiple times yields equal descriptors; subsequent
      #   reads expand the underlying record tables.
      def cache_descriptor
        files, configs = @mutex.synchronize { [@file_entries.values.dup, @config_entries.values.dup] }
        Cache::Descriptor.new(files: files, configs: configs)
      end

      private

      def record_file_entry(path, contents)
        digest = Digest::SHA256.hexdigest(contents)
        entry = Cache::Descriptor::FileEntry.new(path: path, comparator: :digest, value: digest)
        @mutex.synchronize { @file_entries[path] = entry }
      end

      def record_url_entry(url, body)
        digest = Digest::SHA256.hexdigest(body)
        key = "url:#{url}"
        entry = Cache::Descriptor::ConfigEntry.new(key: key, value_hash: digest)
        @mutex.synchronize { @config_entries[key] = entry }
      end
    end

    # Default HTTP client wrapping `Net::HTTP`. Wraps a single
    # `GET` over HTTPS. Specs inject a fake client that conforms
    # to the same `#get(url, timeout:, max_bytes:)` shape so the
    # tests don't require network access.
    class DefaultHttpClient
      # rubocop:disable Metrics/MethodLength
      def get(url, timeout:, max_bytes:)
        require "net/http"
        require "uri"

        uri = URI.parse(url)
        body = +""
        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                            open_timeout: timeout,
                                            read_timeout: timeout) do |http|
          http.request_get(uri.request_uri) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              raise Plugin::AccessDeniedError.new(
                "URL #{url.inspect} returned non-success status #{response.code}",
                reason: :url_fetch_failed,
                resource: url
              )
            end
            response.read_body do |chunk|
              body << chunk
              if body.bytesize > max_bytes
                raise Plugin::AccessDeniedError.new(
                  "URL #{url.inspect} body exceeds #{max_bytes} bytes",
                  reason: :url_body_too_large,
                  resource: url
                )
              end
            end
          end
        end
        body
      end
      # rubocop:enable Metrics/MethodLength
    end
  end
end
