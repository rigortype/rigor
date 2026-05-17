# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/cache/store"
require "rigor/configuration"

module RunnerHelpers
  # Per-spec-process shared `Cache::Store`. Specs typically
  # exercise `Analysis::Runner` against many small fixtures
  # that all consult the same RBS core + stdlib environment;
  # without a shared cache, every `analyze(...)` re-resolves
  # the same constant table / known-class set from scratch.
  # Pointing every `analyze` at one process-wide tmpdir cache
  # lets the second and later calls hit the cache and skip
  # the redundant RBS work. Cache::Store keys by file digest
  # so cross-fixture contamination is impossible — different
  # fixtures get different cache entries.
  #
  # Tests that need to assert cache behaviour explicitly
  # (the `runner_spec.rb` cache_store / --no-cache surface)
  # pass `cache_store: nil` to opt out.
  #
  # Two further per-process directories cut large constant
  # costs out of the helper's hot path:
  #
  # - `shared_workspace_root` — a single empty project dir the
  #   runner can chdir into for source-only analyses. Reusing
  #   it across calls drops the mktmpdir + cleanup round-trip
  #   from each invocation and stops the runner's `Dir.pwd`-
  #   sensitive surfaces (Gemfile.lock / bundler / rbs collection
  #   discovery) from observing different roots between calls.
  # - `sig_cache_root` — content-keyed storage for `sig:` files.
  #   The persistent `Cache::Store` keys the RBS environment by
  #   `(path, sha256)`, so a unique tmpdir per `sig:` call forces
  #   a full env rebuild every time (~1.8 s with default libraries).
  #   Materialising identical sig content at a stable
  #   sha-derived path lets repeated `sig:` calls share one
  #   warm cache entry — the env is built once per distinct sig
  #   set rather than once per call.
  class << self
    def shared_cache_store
      @shared_cache_store ||= Rigor::Cache::Store.new(root: shared_cache_root)
    end

    def shared_cache_root
      @shared_cache_root ||= Dir.mktmpdir("rigor-spec-cache-")
    end

    def shared_workspace_root
      @shared_workspace_root ||= Dir.mktmpdir("rigor-spec-workspace-")
    end

    def sig_cache_root
      @sig_cache_root ||= Dir.mktmpdir("rigor-spec-sig-")
    end

    # Materialises a `sig:` hash to a content-keyed directory
    # under {.sig_cache_root}. Returns the directory path so
    # the caller can thread it into `Configuration` as
    # `signature_paths:`. Idempotent: once a digest's directory
    # exists, the files are not rewritten — every subsequent
    # caller observes the same `(path, sha256)` tuple and the
    # cached RBS environment hits.
    def materialise_sig(sig_hash)
      return nil if sig_hash.nil? || sig_hash.empty?

      digest_input = sig_hash.to_a.sort.map { |k, v| "#{k}\0#{v}" }.join("\0")
      digest = Digest::SHA256.hexdigest(digest_input)[0, 16]
      sig_root = File.join(sig_cache_root, digest)
      unless File.directory?(sig_root)
        FileUtils.mkdir_p(sig_root)
        sig_hash.each { |name, body| File.write(File.join(sig_root, name), body) }
      end
      sig_root
    end

    # Empties the shared workspace's top-level `.rb` files so
    # the runner's `Dir.glob(<workspace>/**/*.rb)` only finds
    # the file the current call writes. The workspace is reused
    # across calls; nested directories created by `files:` callers
    # are removed wholesale so leftover fixtures from a prior call
    # cannot leak into the current one.
    def reset_shared_workspace
      Dir.glob(File.join(shared_workspace_root, "*")).each do |entry|
        FileUtils.rm_rf(entry)
      end
    end
  end

  # Shared analysis-runner helper. Runs `Rigor::Analysis::Runner`
  # against a synthetic project, yielding the resulting
  # `Rigor::Analysis::Result` and the project root.
  #
  # Three fast paths share state across calls (per spec process)
  # to avoid the ~1.8 s RBS env rebuild that a unique tmpdir per
  # call triggers when `sig:` files are involved:
  #
  # - `sig:` content is hashed and written under a stable path
  #   in {RunnerHelpers.sig_cache_root}, so equivalent sigs share
  #   one cached RBS environment.
  # - The empty project dir the runner chdir's into is reused
  #   across calls ({RunnerHelpers.shared_workspace_root}), so
  #   the runner's `Dir.pwd`-sensitive surfaces observe a
  #   stable empty root.
  # - The `Cache::Store` is the same instance for every call by
  #   default; opt out with `cache_store: nil`.
  #
  # Callers that need full isolation (a fixture spanning multiple
  # `files:` entries, a config that overrides `paths:`, or any
  # other shape that depends on a unique `Dir.pwd`) automatically
  # fall back to the per-call `Dir.mktmpdir` path.
  #
  # @param source [String, nil] convenience for single-file
  #   fixtures: written to `<workspace>/code.rb`.
  # @param files [Hash{String => String}] additional files to
  #   write, keyed by relative path inside the workspace.
  # @param sig [Hash{String => String}] RBS files. When present,
  #   content-keyed materialisation kicks in and the resulting
  #   `signature_paths:` entry is threaded into `Configuration`.
  # @param config [Hash] extra `.rigor.yml`-style overrides
  #   merged into the `Configuration`. `paths:` is always
  #   set to the workspace unless overridden.
  # @param explain [Boolean] forwarded to `Runner.new(explain:)`.
  # @param cache_store [Rigor::Cache::Store, :shared, nil]
  #   `:shared` (default) reuses the process-wide cache so
  #   RBS core / stdlib resolution stays hot across examples.
  #   Pass `nil` for the cache-disabled (`--no-cache`-equivalent)
  #   behaviour the cache surface tests assert against; pass
  #   an explicit `Cache::Store` to drive isolated cache
  #   behaviour from a spec.
  # @yieldparam result [Rigor::Analysis::Result]
  # @yieldparam dir    [String] the project root.
  # @return [Rigor::Analysis::Result] for callers that prefer
  #   to assert outside the block.
  def analyze(source = nil, files: {}, sig: {}, config: {}, explain: false, cache_store: :shared, &)
    effective_cache = cache_store == :shared ? RunnerHelpers.shared_cache_store : cache_store

    if shared_workspace_safe?(files: files, config: config)
      analyze_in_shared_workspace(
        source: source, sig: sig, config: config, explain: explain, cache_store: effective_cache, &
      )
    else
      analyze_in_tmpdir(
        source: source, files: files, sig: sig, config: config, explain: explain, cache_store: effective_cache, &
      )
    end
  end

  private

  # The shared workspace path is reused across calls; any config
  # that pins `paths:` or `signature_paths:` to caller-supplied
  # entries cannot share it because the runner's expansion would
  # see the override, not the workspace. The `files:` shape also
  # falls back because callers may write into nested paths whose
  # cleanup is harder to reason about than a tmpdir's wholesale
  # rmtree.
  def shared_workspace_safe?(files:, config:)
    return false unless files.empty?
    return false if config.key?("paths") || config.key?(:paths)
    return false if config.key?("signature_paths") || config.key?(:signature_paths)

    true
  end

  def analyze_in_shared_workspace(source:, sig:, config:, explain:, cache_store:)
    workspace = RunnerHelpers.shared_workspace_root
    RunnerHelpers.reset_shared_workspace
    File.write(File.join(workspace, "code.rb"), source) if source

    sig_root = RunnerHelpers.materialise_sig(sig)
    config_hash = { "paths" => [workspace] }
    config_hash["signature_paths"] = [sig_root] if sig_root
    configuration = Rigor::Configuration.new(config_hash.merge(config))

    result = Dir.chdir(workspace) do
      Rigor::Analysis::Runner.new(
        configuration: configuration, cache_store: cache_store, explain: explain
      ).run
    end
    yield result, workspace if block_given?
    result
  end

  def analyze_in_tmpdir(source:, files:, sig:, config:, explain:, cache_store:)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "code.rb"), source) if source
      files.each do |name, body|
        full = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      unless sig.empty?
        FileUtils.mkdir_p(File.join(dir, "sig"))
        sig.each { |name, body| File.write(File.join(dir, "sig", name), body) }
      end

      configuration = Rigor::Configuration.new({ "paths" => [dir] }.merge(config))
      result = Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(
          configuration: configuration, cache_store: cache_store, explain: explain
        ).run
      end
      yield result, dir if block_given?
      result
    end
  end
end
