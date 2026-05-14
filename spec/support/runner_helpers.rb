# frozen_string_literal: true

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
  class << self
    def shared_cache_store
      @shared_cache_store ||= Rigor::Cache::Store.new(root: shared_cache_root)
    end

    def shared_cache_root
      @shared_cache_root ||= Dir.mktmpdir("rigor-spec-cache-")
    end
  end

  # Shared analysis-runner helper. Materialises a temporary
  # project on disk, points `Rigor::Analysis::Runner` at it,
  # and yields the resulting `Rigor::Analysis::Result`.
  #
  # @param source [String, nil] convenience for single-file
  #   fixtures: written to `<tmp>/code.rb`.
  # @param files [Hash{String => String}] additional files to
  #   write, keyed by relative path inside the tmpdir.
  # @param sig [Hash{String => String}] RBS files to write
  #   under `<tmp>/sig/`. Picked up automatically by
  #   `Environment.for_project` because the helper `chdir`s
  #   into the tmpdir for the run.
  # @param config [Hash] extra `.rigor.yml`-style overrides
  #   merged into the `Configuration`. `paths:` is always
  #   set to the tmpdir unless overridden.
  # @param explain [Boolean] forwarded to `Runner.new(explain:)`.
  # @param cache_store [Rigor::Cache::Store, :shared, nil]
  #   `:shared` (default) reuses the process-wide cache so
  #   RBS core / stdlib resolution stays hot across examples.
  #   Pass `nil` for the cache-disabled (`--no-cache`-equivalent)
  #   behaviour the cache surface tests assert against; pass
  #   an explicit `Cache::Store` to drive isolated cache
  #   behaviour from a spec.
  # @yieldparam result [Rigor::Analysis::Result]
  # @yieldparam dir    [String] the tmpdir root.
  # @return [Rigor::Analysis::Result] for callers that prefer
  #   to assert outside the block.
  def analyze(source = nil, files: {}, sig: {}, config: {}, explain: false, cache_store: :shared)
    effective_cache = cache_store == :shared ? RunnerHelpers.shared_cache_store : cache_store
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
          configuration: configuration, cache_store: effective_cache, explain: explain
        ).run
      end
      yield result, dir if block_given?
      result
    end
  end
end
