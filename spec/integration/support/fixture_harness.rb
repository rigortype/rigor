# frozen_string_literal: true

require "prism"

module Rigor
  module IntegrationSupport
    # Loads a fixture under `spec/integration/fixtures/` and runs
    # the engine end-to-end against it. Each fixture is a
    # self-contained Ruby snippet — readable on its own, runnable
    # under MRI, and independently inspectable through the
    # `rigor type-of` CLI.
    #
    # Two layouts are supported:
    #
    # - **Flat fixture**: `fixtures/<name>.rb`. Parsed and
    #   evaluated under `Rigor::Scope.empty`. No project sig is
    #   loaded, so only `Environment.default` (RBS-core +
    #   bundled stdlib) is visible.
    # - **Project fixture**: `fixtures/<name>/` directory
    #   containing `<entry>.rb` (default: `demo.rb`) and a sibling
    #   `sig/` directory. The harness `chdir`s into the directory
    #   and uses `Environment.for_project` so the project sig is
    #   merged with the bundled stdlib.
    #
    # Each `evaluate` / `type_at` returns plain Rigor values so
    # the surrounding RSpec `expect` calls stay declarative.
    class FixtureHarness
      FIXTURES_ROOT = File.expand_path("../fixtures", __dir__)

      attr_reader :name, :source, :tree, :scope, :index

      def initialize(name, entry: "demo.rb")
        @name = name
        @entry = entry
        load_fixture
      end

      # Evaluates the fixture top to bottom under the harness
      # scope and returns the post-scope so callers can inspect
      # `local(:foo)` / `ivar(:@bar)` bindings.
      def post_scope
        @post_scope ||= scope.evaluate(tree).last
      end

      # Resolves the type at a 1-indexed `(line, column)` pair
      # by routing through the per-node scope index. The position
      # MAY land on any node Prism produces; callers usually
      # target a `LocalVariableReadNode` or write target.
      def type_at(line:, column:)
        node = locator.at_position(line: line, column: column)
        index[node].type_of(node)
      end

      # Convenience: returns the type bound to a top-level local
      # in the fully-evaluated post-scope.
      def local(name)
        post_scope.local(name)
      end

      # Runs the full `Rigor::Analysis::CheckRules` catalogue
      # against the fixture and returns the resulting
      # diagnostics. Used by the self-asserting fixtures
      # (e.g. `assertions.rb`) — `harness.diagnostics` should
      # be empty when the fixture's `assert_type(...)` calls
      # all match the engine's inference.
      def diagnostics
        @diagnostics ||= Rigor::Analysis::CheckRules.diagnose(
          path: name,
          root: tree,
          scope_index: index
        )
      end

      def errors
        diagnostics.select(&:error?)
      end

      private

      def load_fixture
        flat_path = File.join(FIXTURES_ROOT, "#{@name}.rb")
        project_dir = File.join(FIXTURES_ROOT, @name)

        if File.file?(flat_path)
          load_flat(flat_path)
        elsif File.directory?(project_dir)
          load_project(project_dir)
        else
          raise ArgumentError, "fixture not found: #{@name} " \
                               "(checked #{flat_path} and #{project_dir}/)"
        end

        @tree = Prism.parse(@source).value
        @index = Rigor::Inference::ScopeIndexer.index(@tree, default_scope: @scope)
      end

      def load_flat(path)
        @source = File.read(path)
        @scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
      end

      def load_project(dir)
        entry_path = File.join(dir, @entry)
        @source = File.read(entry_path)
        # `for_project` auto-detects `<dir>/sig` so the fixture's
        # sig files are merged with the bundled stdlib.
        env = Rigor::Environment.for_project(root: dir)
        @scope = Rigor::Scope.empty(environment: env)
      end

      def locator
        @locator ||= Rigor::Source::NodeLocator.new(source: @source, root: @tree)
      end
    end
  end
end
