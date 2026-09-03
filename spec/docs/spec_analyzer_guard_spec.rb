# frozen_string_literal: true

# The regrowth gate for issues #665 / #674.
#
# When a check rule raises, `Runner#analyze_file_body` (and `WorkerSession#analyze_body`) rescues it into
# ONE `"internal analyzer error"` diagnostic for the whole file and DISCARDS every other diagnostic that
# file would have produced; a raising plugin folds the same way into a `:plugin_loader` / `"runtime-error"`
# row. In the CLI both are loud. In a spec both are silent: `expect(rules(result)).not_to include(...)`,
# `expect(diagnostics).to be_empty` and `expect(dumps(result)).to all(eq(...))` all hold on the
# one-diagnostic list the rescue leaves behind, so an example keeps passing while nothing ran.
#
# #665 fixed the two shared harness entry points. #674 measured the rest: with an unconditional raise in
# `CheckRules.diagnose`, **1,177 of 1,925 examples across 86 files still passed**, because those files
# build their own Runner and read the raw `Result`. Whole files were green with zero rules running.
#
# Fixing the population is a one-off; keeping it fixed is not. Every new spec that reaches for
# `Rigor::Analysis::Runner.new(...).run` re-creates one member of it, and nothing about writing that line
# feels wrong. So the rule is mechanical: an analyzer run in `spec/` has to end up in front of
# {InternalAnalyzerErrorGuard}. `GuardedAnalysis#guarded_run` / `#guarded_run_source` are the one-liners
# that satisfy it; a wrapper outside example scope calls `InternalAnalyzerErrorGuard.check!` itself.
#
# What is checked is the RUN, never the construction: `WorkerSession.new(...)` on its own is what
# `ractor_readiness_spec.rb` legitimately does to ask whether the object is shareable, and failing that
# would be a false positive on a spec that analyses nothing. Consistent with ADR-5, a gate that fires on
# correct input teaches people to route around it.
require "spec_helper"
require "prism"

SPEC_ANALYZER_GUARD_ROOT = File.expand_path("../..", __dir__)

# Scans one spec file for analyzer runs whose `Result` never reaches {InternalAnalyzerErrorGuard}.
#
# A "run site" is a call to `run` / `run_source` / `analyze_body` whose receiver is an analyzer the same
# file produced — constructed inline, held in a local, or returned by a local factory method. It is
# satisfied when the guard is named inside the site's enclosing method or example, which is where a
# wrapper's `check!` lives; the search stops at that boundary so a single `check!` elsewhere in the file
# cannot vouch for an unrelated example.
module SpecAnalyzerGuardScan
  ANALYZER_CLASSES = %w[Runner WorkerSession].freeze
  RUN_METHODS = %i[run run_source analyze_body].freeze
  GUARD_CONSTANT = "InternalAnalyzerErrorGuard"
  # Where an example's own scope begins. A run site inside one of these must carry its own guard.
  EXAMPLE_SCOPES = %i[it specify example fit ftt xit let let! subject subject! before after around].freeze

  Offense = Struct.new(:line, :source)

  class << self
    # @return [Array<Offense>] every unguarded run site, in source order.
    def offenses(source)
      root = Prism.parse(source).value
      analyzer_locals = collect_analyzer_locals(root)
      factories = collect_factory_methods(root)
      described = describes_analyzer?(root)
      lines = source.lines
      found = []
      walk(root, []) do |node, stack|
        next unless run_site?(node, analyzer_locals: analyzer_locals, factories: factories, described: described)
        next if guarded?(stack)

        line = node.location.start_line
        found << Offense.new(line, lines[line - 1].to_s.strip)
      end
      found.sort_by(&:line)
    end

    private

    def walk(node, stack, &)
      yield node, stack
      stack.push(node)
      node.compact_child_nodes.each { |child| walk(child, stack, &) }
      stack.pop
    end

    # `described_class.new` only counts in a file that describes one of the analyzer classes —
    # `runner_spec.rb` builds 74 of its runners that way.
    def describes_analyzer?(root)
      found = false
      walk(root, []) do |node, _|
        next unless node.is_a?(Prism::CallNode) && node.name == :describe

        first = node.arguments&.arguments&.first
        found ||= analyzer_constant?(first)
      end
      found
    end

    def analyzer_constant?(node)
      case node
      when Prism::ConstantReadNode then ANALYZER_CLASSES.include?(node.name.to_s)
      when Prism::ConstantPathNode then ANALYZER_CLASSES.include?(node.name.to_s)
      else false
      end
    end

    # `Rigor::Analysis::Runner.new(...)`, `Runner.new(...)`, or `described_class.new(...)` in a file that
    # describes one.
    def construction?(node, described:)
      return false unless node.is_a?(Prism::CallNode) && node.name == :new

      receiver = node.receiver
      return true if analyzer_constant?(receiver)

      described && receiver.is_a?(Prism::CallNode) && receiver.name == :described_class && receiver.receiver.nil?
    end

    # Local variables ever assigned an analyzer construction, file-wide. Deliberately not scope-aware: a
    # name reused for something else would only cost a spurious hit on `<name>.run`, and no spec has one.
    def collect_analyzer_locals(root)
      described = describes_analyzer?(root)
      names = []
      walk(root, []) do |node, _|
        next unless node.is_a?(Prism::LocalVariableWriteNode) && construction?(node.value, described: described)

        names << node.name
      end
      names.uniq
    end

    # `def build_runner(...) = <construction>` — a factory, so `build_runner(...).run` is a run site too.
    def collect_factory_methods(root)
      described = describes_analyzer?(root)
      names = []
      walk(root, []) do |node, _|
        next unless node.is_a?(Prism::DefNode)

        last = node.body.is_a?(Prism::StatementsNode) ? node.body.body.last : node.body
        names << node.name if construction?(last, described: described)
      end
      names.uniq
    end

    def run_site?(node, analyzer_locals:, factories:, described:)
      return false unless node.is_a?(Prism::CallNode) && RUN_METHODS.include?(node.name)

      receiver = node.receiver
      return true if construction?(receiver, described: described)
      return true if receiver.is_a?(Prism::LocalVariableReadNode) && analyzer_locals.include?(receiver.name)

      receiver.is_a?(Prism::CallNode) && receiver.receiver.nil? && factories.include?(receiver.name)
    end

    # Innermost-out: the guard counts when it is the call the run site is an argument of, or when it is
    # named anywhere in the enclosing method / example — the two shapes a real wrapper takes.
    def guarded?(stack)
      stack.each_index.reverse_each do |i|
        ancestor = stack[i]
        return true if guard_call?(ancestor)
        return mentions_guard?(ancestor) if ancestor.is_a?(Prism::DefNode)
        return mentions_guard?(ancestor) if example_scope?(ancestor, stack[i - 1])
      end
      false
    end

    def guard_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::ConstantReadNode) &&
        node.receiver.name.to_s == GUARD_CONSTANT
    end

    # A `BlockNode` carries no parent pointer, so the owning call comes from the walk stack: the node
    # directly above a block is always the call it is attached to.
    def example_scope?(node, parent)
      node.is_a?(Prism::BlockNode) && parent.is_a?(Prism::CallNode) && EXAMPLE_SCOPES.include?(parent.name)
    end

    def mentions_guard?(node)
      node.location.slice.include?(GUARD_CONSTANT)
    end
  end
end

RSpec.describe "analyzer runs in spec/ reach the internal-error guard (#674)" do
  # Files whose SUBJECT is the crash envelope itself. Guarding them would make the behaviour untestable,
  # which is a different thing from having been missed — each one asserts on the very diagnostic
  # {InternalAnalyzerErrorGuard} raises for. Anything else belongs in `guarded_run`, not here.
  allowlist = {
    "spec/rigor/analysis/worker_session_spec.rb" =>
      "asserts the rescue envelope directly: `internal analyzer error` for a raising check rule, and " \
      "`rule: \"runtime-error\" / source_family: :plugin_loader` for a raising plugin #prepare, " \
      "#diagnostics_for_file, node_rule and manifest.",
    "spec/rigor/analysis/runner_pool_spec.rb" =>
      "excluded from the default suite (`make test-ractor-pool`); drives the Ractor/fork pool backends " \
      "directly and asserts the `:plugin_loader` runtime-error a worker-side plugin raise folds into."
  }.freeze

  describe "the scanner (pinned inline, so the rule holds independently of today's tree)" do
    def offense_lines(source)
      SpecAnalyzerGuardScan.offenses(source).map(&:line)
    end

    it "flags a bare construction-and-run chain" do
      expect(offense_lines(<<~RUBY)).to eq([2])
        it "x" do
          result = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil).run
        end
      RUBY
    end

    it "flags a run through a local the same example constructed" do
      expect(offense_lines(<<~RUBY)).to eq([3])
        it "x" do
          runner = Rigor::Analysis::Runner.new(configuration: config)
          runner.run(%w[app.rb])
        end
      RUBY
    end

    it "flags `described_class.new(...).run` in a file that describes the Runner" do
      expect(offense_lines(<<~RUBY)).to eq([3])
        RSpec.describe Rigor::Analysis::Runner do
          it "x" do
            described_class.new(configuration: config).run
          end
        end
      RUBY
    end

    it "flags a run through a local factory method" do
      expect(offense_lines(<<~RUBY)).to eq([6])
        def build_runner(dir)
          Rigor::Analysis::Runner.new(configuration: config(dir))
        end

        it "x" do
          build_runner(dir).run
        end
      RUBY
    end

    it "accepts a run wrapped in the guard at the site" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          runner = Rigor::Analysis::Runner.new(configuration: config)
          InternalAnalyzerErrorGuard.check!(runner.run, context: "x")
        end
      RUBY
    end

    it "accepts a wrapper method whose own body checks the result" do
      expect(offense_lines(<<~RUBY)).to be_empty
        def diagnostics_for(source)
          result = Dir.chdir(dir) do
            Rigor::Analysis::Runner.new(configuration: config).run
          end
          InternalAnalyzerErrorGuard.check!(result, context: "diagnostics_for").diagnostics
        end
      RUBY
    end

    it "accepts a `guarded_run` call site, which chains no run method of its own" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          guarded_run(Rigor::Analysis::Runner.new(configuration: config), %w[app.rb])
        end
      RUBY
    end

    # A `check!` in a sibling helper says nothing about this example, so it must not launder one.
    it "does not let a guard elsewhere in the file vouch for an unguarded example" do
      expect(offense_lines(<<~RUBY)).to eq([6])
        def guarded_helper(runner)
          InternalAnalyzerErrorGuard.check!(runner.run, context: "helper")
        end

        it "x" do
          Rigor::Analysis::Runner.new(configuration: config).run
        end
      RUBY
    end

    # `ractor_readiness_spec.rb`'s real shape: constructed to be inspected, never run.
    it "leaves a construction that is never run alone" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          session = Rigor::Analysis::WorkerSession.new(configuration: config, environment: env)
          expect(Ractor.shareable?(session)).to be(false)
        end
      RUBY
    end

    it "leaves an unrelated `#run` alone" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          status = Rigor::CLI::CheckCommand.new(argv: [], out: out, err: err).run
          expect(status).to eq(0)
        end
      RUBY
    end
  end

  describe "the live tree" do
    it "keeps every allowlisted file present and still offending" do
      stale = allowlist.keys.reject do |relative|
        path = File.join(SPEC_ANALYZER_GUARD_ROOT, relative)
        File.exist?(path) && !SpecAnalyzerGuardScan.offenses(File.read(path)).empty?
      end

      expect(stale).to be_empty, <<~MSG
        Allowlist entries that no longer need to be there — delete them:
          #{stale.join("\n  ")}
      MSG
    end

    it "routes every other analyzer run through the guard" do
      offenders = Dir.glob(File.join(SPEC_ANALYZER_GUARD_ROOT, "spec/**/*.rb")).sort.filter_map do |path|
        relative = path.delete_prefix("#{SPEC_ANALYZER_GUARD_ROOT}/")
        next if allowlist.key?(relative)

        found = SpecAnalyzerGuardScan.offenses(File.read(path))
        next if found.empty?

        "#{relative}\n    #{found.map { |o| "L#{o.line}: #{o.source}" }.join("\n    ")}"
      end

      expect(offenders).to be_empty, <<~MSG
        An analyzer run in spec/ whose Result never reaches InternalAnalyzerErrorGuard (#674).

        A check rule that raises is rescued into ONE "internal analyzer error" diagnostic and every other
        diagnostic for that file is discarded, so an absence assertion on the raw Result passes while
        nothing ran. Use the harness helpers at the construction site:

            guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
            guarded_run(runner, %w[app.rb])
            guarded_run_source(runner, source: source, path: "mem.rb")

        Outside example scope (a `def self.` memo, a plain helper class) call the guard yourself:

            InternalAnalyzerErrorGuard.check!(runner.run, context: "<what ran it>")

        If the example's SUBJECT is the crash envelope, add it to this spec's `allowlist` with the
        reason. If it deliberately crashes a PLUGIN, keep the guard and pass
        `allow_plugin_crash: true` — the check-rule half stays armed.

        #{offenders.join("\n  ")}
      MSG
    end
  end
end
