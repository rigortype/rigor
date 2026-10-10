# frozen_string_literal: true

require "fileutils"
require "prism"
require "tmpdir"

# #1507 — a two-file project that fills almost every `Scope::DiscoveryIndex` member, and two indexes of its main file:
# the one `rigor check` analyses it under (the runner's own project pre-pass and seed, with dependency recording on
# so the source-attribution tables are seeded and a run token minted, then the file's own `ScopeIndexer.index`), and
# the one the file's parse alone gives (`ScopeIndexer.index` over an empty scope). The second file contributes to
# every project table, so a table that depends on the project differs between the two. `member_classes_spec.rb` checks
# each member's shape on them.
module DeclarationFactFixture
  FILES = {
    "lib/app_config.rb" => <<~RUBY,
      module AppConfig
        MODE = :production
        Size = Data.define(:width, :height)
        Cell = Struct.new(:value)

        def self.load = new
      end

      module Numbers
        refine Integer do
          def half = self / 2
        end
      end

      class Gadget < Base
        include Greeting
        prepend Wrap
        extend Loud
        include Conditional if defined?(Conditional)

        def self.make = new
        def use(first, second = 1) = first
        def to_int = 1

        private

        def hidden = 1
      end

      # Issue #1715 — a top-level include, so the pre-pass folds `discovered_defined_names`.
      include Greeting
    RUBY
    "lib/widget.rb" => <<~RUBY
      module Greeting
        def hello = "hi"
      end

      module Wrap
        def render = "wrapped"
      end

      module Loud
        def shout = "HI"
      end

      module Strings
        refine String do
          def whisper = downcase
        end
      end

      Point = Data.define(:x, :y)
      Pair = Struct.new(:a, :b)
      LIMIT = 7
      $counter = AppConfig::MODE
      $stdout = AppConfig::MODE

      class Base
        def base_method(first, second = 1) = first + second
      end

      class Widget < Base
        include Greeting
        prepend Wrap
        extend Loud

        MODE2 = AppConfig::MODE

        def initialize
          @mode = AppConfig::MODE
          @size = 1
        end

        def self.build = new
        def self.bump = (@@count = AppConfig::MODE)
        def render = "r"
        def to_str = "widget"

        private

        def secret = 2
      end

      module Helpers
        module_function

        def fmt(value) = value.to_s
      end

      Widget.define_method(:===) { |_other| true }
      $stdin.define_singleton_method(:gets) { "line" }
      Process.wait(1, Process::WNOHANG)
      [1].each { |item| item }
    RUBY
  }.freeze
  MAIN = "lib/widget.rb"

  module_function

  # Yields `dir, paths` with the project written under a temporary directory.
  def with_project
    Dir.mktmpdir("rigor-declaration-facts-") do |dir|
      FILES.each do |relative, source|
        FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
        File.write(File.join(dir, relative), source)
      end
      yield dir, FILES.keys.map { |relative| File.join(dir, relative) }
    end
  end

  # `{discovery:, file_only:, seed:, bundles:}`: the main file's index as `rigor check` builds it and as its parse
  # alone builds it (each `[discovery, root]`), the runner's seed tables, and the ADR-85 per-file seed bundles.
  def build
    with_project do |dir, paths|
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => [File.join(dir, "lib")]),
          cache_store: nil, collect_stats: false, record_dependencies: true
        )
        runner.send(:ensure_project_discovery, { files: paths })
        # `Runner#run_analysis` mints the run token the same way before it seeds any file.
        runner.instance_variable_set(:@run_generation, Object.new.freeze)
        main = File.join(dir, MAIN)
        { discovery: index(runner.send(:seed_project_scope, Rigor::Scope.empty(source_path: main)), main),
          file_only: index(Rigor::Scope.empty(source_path: main), main),
          seed: runner.send(:project_scope_seed_tables),
          bundles: Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: {})
                                                 .fetch(:bundles) }
      end
    end
  end

  # {build}, once per process.
  def built
    @built ||= build
  end

  # One parse and index of `path` under `base`: `[discovery, root]`.
  def index(base, path)
    root = Prism.parse(File.read(path), filepath: path).value
    [Rigor::Inference::ScopeIndexer.index(root, default_scope: base).default.discovery, root]
  end
end
