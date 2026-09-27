# frozen_string_literal: true

require "fileutils"
require "prism"
require "tmpdir"

# #1507 — a two-file project that fills almost every `Scope::DiscoveryIndex` member, and the index `rigor check`
# analyses its main file under: the runner's own project pre-pass and seed (`Runner#ensure_project_discovery`,
# `#seed_project_scope`, with dependency recording on so the source-attribution tables are seeded), then the file's
# own `ScopeIndexer.index`. `member_classes_spec.rb` checks each member's shape on it.
module DeclarationFactFixture
  FILES = {
    "lib/app_config.rb" => <<~RUBY,
      module AppConfig
        MODE = :production
      end
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
      $counter = 0
      $stdout = $stderr

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
        def self.bump = (@@count = 1)
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

  # `{discovery:, root:, seed:, bundles:}`: the main file's index, its parse, the runner's seed tables and the
  # ADR-85 per-file seed bundles for the project.
  def build
    with_project do |dir, paths|
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new("paths" => [File.join(dir, "lib")]),
          cache_store: nil, collect_stats: false, record_dependencies: true
        )
        runner.send(:ensure_project_discovery, { files: paths })
        main = File.join(dir, MAIN)
        { discovery: index(runner, main), second: index(runner, main), seed: runner.send(:project_scope_seed_tables),
          bundles: Rigor::Inference::ScopeIndexer.discovered_project_index_incremental(paths, seed_bundles: {})
                                                 .fetch(:bundles) }
      end
    end
  end

  # {build}, once per process.
  def built
    @built ||= build
  end

  # One independent parse and index of `path`: `[discovery, root]`.
  def index(runner, path)
    base = runner.send(:seed_project_scope, Rigor::Scope.empty(source_path: path))
    root = Prism.parse(File.read(path), filepath: path).value
    [Rigor::Inference::ScopeIndexer.index(root, default_scope: base).default.discovery, root]
  end
end
