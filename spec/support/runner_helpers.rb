# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

module RunnerHelpers
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
  # @yieldparam result [Rigor::Analysis::Result]
  # @yieldparam dir    [String] the tmpdir root.
  # @return [Rigor::Analysis::Result] for callers that prefer
  #   to assert outside the block.
  def analyze(source = nil, files: {}, sig: {}, config: {}, explain: false)
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
        Rigor::Analysis::Runner.new(configuration: configuration, explain: explain).run
      end
      yield result, dir if block_given?
      result
    end
  end
end
