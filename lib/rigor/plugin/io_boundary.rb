# frozen_string_literal: true

require "digest"

require_relative "access_denied_error"

module Rigor
  module Plugin
    # Analyzer-side helper plugins go through to read files and (eventually) reach the network. The boundary
    # enforces the active {TrustPolicy} and accumulates a {Cache::Descriptor} of every read so plugin
    # contributions stay invalidatable alongside their inputs.
    #
    # ADR-2 § "Plugin Trust and I/O Policy" is the binding contract. The boundary is **not** a sandbox: a
    # plugin that uses `File.read` directly bypasses everything here, and the ADR explicitly accepts that
    # trade-off. The discipline is: when plugin code goes through this surface, reads stay within the trust
    # scope and feed the cache descriptor; contributions built on top of out-of-scope reads will not
    # invalidate correctly.
    #
    # Slice 2 ships a minimal surface:
    #
    # - `#read_file(path)` — validates against the policy, returns the file's contents, and adds a
    #   digest-keyed {Cache::Descriptor::FileEntry} to the boundary's accumulated descriptor. A read that
    #   fails because the path does not exist adds an ABSENCE row instead (ADR-45 WD1, #577), so a result
    #   computed on the file being missing invalidates once it appears.
    # - `#file?(path)` / `#directory?(path)` — the existence PROBE (ADR-45 WD1b, #613): the same answer
    #   `File.file?` / `File.directory?` gives, plus the existence row `#read_file` would have recorded.
    #   A plugin that gates its read or its glob on one of these shapes its result on the answer, so the
    #   answer is a dependency; probing through `File` directly leaves that dependency unrecorded and the
    #   warm run serves the pre-appearance result.
    # - `#open_url(url)` — fetches the URL when the policy permits it (`network_policy: :allowlist` plus an
    #   `allowed_url_hosts` match) and raises {AccessDeniedError} otherwise. v0.1.2 ships the allowlist
    #   surface; the default project policy still has `network_policy: :disabled` so plugins that want network
    #   access opt in explicitly through `.rigor.yml`'s `plugins_io.network: allowlist` plus
    #   `plugins_io.allowed_url_hosts: [...]`. The HTTP fetch is GET-only over HTTPS, capped at
    #   {URL_TIMEOUT_SECONDS} wall time and {URL_MAX_BYTES} body size; non-2xx responses raise
    #   {AccessDeniedError} so plugin code doesn't have to rescue mid-build.
    # - `#cache_descriptor` — flushes the accumulated entries into a fresh {Cache::Descriptor} for the
    #   contribution that built it. URL fetches contribute `ConfigEntry` rows keyed `"url:#{url}"` with the
    #   response body's SHA-256 so contributions invalidate when the remote document changes.
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

      # Reads the file at `path` after validating it against the policy. Raises {AccessDeniedError} when the
      # path is outside every allowed read root. Records a `:stat` {Cache::Descriptor::FileEntry} so the
      # resulting cache slice invalidates on content change.
      #
      # ADR-45 WD1 (#577) — a read that fails because the path does NOT exist (`Errno::ENOENT`, or
      # `Errno::ENOTDIR` when a parent component is a regular file) is a deliberate existence probe: the
      # plugin asked for the file and shaped its answer on the file being absent (rigor-activerecord's
      # reduced mode on a missing `db/schema.rb`). That is a dependency too — "the analysis depended on X
      # being absent" — so the boundary records an ABSENCE row ({Cache::Descriptor::FileEntry.absent})
      # before re-raising, and every cache built on this boundary's descriptor (the run-result entry, the
      # plugin-producer entries) goes stale the moment the path comes into existence. Only the not-there
      # outcome is recorded: a path that exists but cannot be read (`EISDIR`, `EACCES`) is a failure the
      # plugin reports, not a probe of absence, and records nothing — as before.
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

        contents = begin
          File.binread(absolute)
        rescue Errno::ENOENT, Errno::ENOTDIR
          record_absence_entry(absolute)
          raise
        end
        record_file_entry(absolute, contents)
        contents
      end

      # ADR-45 WD1b (#613) — the existence probe. Returns exactly what `File.file?(path)` returns, and
      # records the answer as a {Cache::Descriptor::FileEntry} `:exists` row so a plugin that gates its read
      # on the probe carries the same dependency a plugin that just called {#read_file} carries.
      # `File.file?` in plugin code records nothing, which is how the #577 staleness class survived at every
      # `return nil unless File.file?(config)` gate: the miss shaped the result and left no edge for the
      # file's later appearance.
      #
      # @rbs path: String -- Project path; relative paths expand against the working directory
      # @rbs return: bool -- `File.file?`'s answer, unchanged
      def file?(path)
        probe(path) { |absolute| File.file?(absolute) }
      end

      # ADR-45 WD1b (#613) — {#file?} for directories: the answer `File.directory?` gives, plus the
      # existence row. The discovery shape (`next [] unless directory?(root)` before a `Dir.glob`) depends
      # on the root existing exactly as a config read depends on the config file existing.
      #
      # @rbs path: String -- Project path; relative paths expand against the working directory
      # @rbs return: bool -- `File.directory?`'s answer, unchanged
      def directory?(path)
        probe(path) { |absolute| File.directory?(absolute) }
      end

      # Fetches the URL when the policy permits it. Returns the response body. Raises {AccessDeniedError} when
      # the policy is `:disabled`, the URL scheme is not `https`, the host is not on the allowlist, the
      # response is non-2xx, the body exceeds {URL_MAX_BYTES}, or the request times out
      # ({URL_TIMEOUT_SECONDS}). On success, records a `ConfigEntry` keyed `"url:#{url}"` with the body's
      # SHA-256 so the cache descriptor invalidates if the remote document changes.
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

      # @rbs return: Rigor::Cache::Descriptor --
      #   Frozen snapshot of every file / URL the boundary has read so far. Calling this multiple times yields equal
      #   descriptors; subsequent reads expand the underlying record tables.
      def cache_descriptor
        files, configs = @mutex.synchronize { [@file_entries.values.dup, @config_entries.values.dup] }
        Cache::Descriptor.new(files: files, configs: configs)
      end

      private

      # ADR-45 WD1b (#613) — the shared body of {#file?} / {#directory?}.
      #
      # The probe answers TRUTHFULLY for every path, in or out of the trusted-read scope, and never raises:
      # it replaces a bare `File.file?` in plugin code, and a predicate that raised (or answered `false` for
      # an out-of-scope path that exists) would change what the converted plugin does rather than only what
      # it records. Existence is not content — ADR-2's boundary is not a sandbox, and the plugin could ask
      # `File` directly — so the policy governs RECORDING here, not the answer: an out-of-scope path
      # contributes no dependency row, exactly as an out-of-scope read contributes none.
      #
      # Three outcomes, mirroring {#read_file}'s bounds:
      #
      # - the probe found what it asked for → a PRESENCE row (`:exists` / `"true"`), stale once the path is
      #   gone;
      # - the probe found nothing at all → an ABSENCE row, stale once anything appears there;
      # - the path exists but is not what was asked for (a directory where a file was wanted, or the
      #   reverse) → NOTHING, the same bound `#read_file` pins for `EISDIR`: the probe observed neither a
      #   usable file nor an absence, and either row would misdescribe what the plugin saw.
      def probe(path)
        absolute = File.expand_path(path.to_s)
        answer = yield(absolute)
        return answer unless @policy.allow_read?(absolute)

        if answer
          record_presence_entry(absolute)
        elsif !File.exist?(absolute)
          record_absence_entry(absolute)
        end
        answer
      end

      def record_file_entry(path, contents)
        # ADR-87 WD1 — the boundary descriptor is validation-only (it never keys a cache), so a plugin-read
        # file rides the stat-then-digest `:stat` tier: a warm run stat-checks the (on a Rails monorepo,
        # 30k+ file) plugin-read set instead of re-hashing it. The digest is taken from the in-memory content
        # we just read; `FileEntry.stat` stats the same path to pack the tuple.
        digest = Digest::SHA256.hexdigest(contents)
        entry = Cache::Descriptor::FileEntry.stat(path: path, digest: digest)
        # A content row replaces an earlier existence row for the same path outright: the file appeared and
        # its bytes were consumed, and a content row validates existence as well as content.
        @mutex.synchronize { @file_entries[path] = entry }
      end

      # ADR-45 WD1 (#577) — the absence row for a probed-but-missing path. A content row already recorded
      # for the same path is KEPT in preference: two outcomes for one path within one run mean the file
      # moved under the analysis, and of the two rows the content row is the one whose validation covers
      # both the content that was read and the file's existence — so it is the one that reads stale while
      # the file is gone. The reverse order (probed absent, then read once it appeared) is the content
      # row's replacement above.
      #
      # WD1b (#613) — the same `||=` also settles absence against PRESENCE: the FIRST existence row for a
      # path stands. Both orders are then conservative under a mid-run mutation, because the row that
      # stands describes the world the earlier decision was shaped on, and it reads stale the moment the
      # world stops matching it — a recompute, never a wrong hit.
      def record_absence_entry(path)
        entry = Cache::Descriptor::FileEntry.absent(path: path)
        @mutex.synchronize { @file_entries[path] ||= entry }
      end

      # ADR-45 WD1b (#613) — the presence row: fresh while the probed path exists, stale once it is gone.
      # It is the weakest row the boundary records (a rename that keeps a file at the path leaves it fresh),
      # and it is the honest one for a probe that never read the bytes — a discovery root globbed for `.rb`
      # files, a config file whose mere existence switched a mode. Ranked under a content row, and under an
      # earlier existence row, by the `||=`/`=` split above.
      def record_presence_entry(path)
        entry = Cache::Descriptor::FileEntry.present(path: path)
        @mutex.synchronize { @file_entries[path] ||= entry }
      end

      def record_url_entry(url, body)
        digest = Digest::SHA256.hexdigest(body)
        key = "url:#{url}"
        entry = Cache::Descriptor::ConfigEntry.new(key: key, value_hash: digest)
        @mutex.synchronize { @config_entries[key] = entry }
      end
    end

    # Default HTTP client wrapping `Net::HTTP`. Wraps a single `GET` over HTTPS. Specs inject a fake client
    # that conforms to the same `#get(url, timeout:, max_bytes:)` shape so the tests don't require network
    # access.
    class DefaultHttpClient
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
    end
  end
end
