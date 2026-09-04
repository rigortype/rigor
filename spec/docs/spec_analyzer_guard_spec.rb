# frozen_string_literal: true

# The regrowth gate for issues #665 / #674 / #683.
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
# build their own Runner and read the raw `Result`. Whole files were green with zero rules running. #683
# found a THIRD entry point the same sweep had deliberately left out of scope: `IncrementalSession`'s
# `#baseline` / `#recheck` / `#run_incremental` / `#run_buffer_recheck` route diagnostics through their
# own `run_runner`, invisibly to both #665's fix and #674's gate — 14 of 60
# `incremental_session_spec.rb` examples still passed under the same injected raise, because the crash
# diagnostic is deterministic content, so an incremental spec's own `recheck.diagnostics == full_run(dir)`
# oracle comparison matches the SAME synthetic row on both sides instead of catching the crash.
#
# Fixing the population is a one-off; keeping it fixed is not. Every new spec that reaches for
# `Rigor::Analysis::Runner.new(...).run` re-creates one member of it, and nothing about writing that line
# feels wrong. So the rule is mechanical: an analyzer run in `spec/` has to end up in front of
# {InternalAnalyzerErrorGuard}. `GuardedAnalysis#guarded_run` / `#guarded_run_source` /
# `#guarded_session_analyze` / `#guarded_baseline` / `#guarded_recheck` / `#guarded_reanalyze_subset` /
# `#guarded_run_incremental` / `#guarded_run_buffer_recheck` are the one-liners that satisfy it; a
# wrapper outside example scope calls `InternalAnalyzerErrorGuard.check!` (or `.check_diagnostics!`) itself.
#
# What is checked is the RUN, never the construction: `WorkerSession.new(...)` on its own is what
# `ractor_readiness_spec.rb` legitimately does to ask whether the object is shareable, and failing that
# would be a false positive on a spec that analyses nothing. Consistent with ADR-5, a gate that fires on
# correct input teaches people to route around it.
require "spec_helper"
require "prism"

SPEC_ANALYZER_GUARD_ROOT = File.expand_path("../..", __dir__)

# Individual run sites whose SUBJECT is the crash envelope itself — keyed `path => { line => reason }`.
# Guarding one of these would make the behaviour untestable, which is a different thing from having been
# missed: the diagnostic {InternalAnalyzerErrorGuard} raises for is the diagnostic the example asserts on.
#
# Keyed by LINE, not by file, and deliberately so. A file-granular entry exempts every site in the file,
# including the ones that were merely missed — `runner_pool_spec.rb` was allowlisted whole while 10 of its
# 11 sites were plainly guardable, and its stale-entry check stayed green on the strength of the one that
# was not. An entry costs a line number that moves when the file is edited; that is the intended price.
#
# A site that crashes a PLUGIN on purpose does NOT belong here — keep the guard and pass
# `allow_plugin_crash: true`, which leaves the check-rule half armed.
SPEC_ANALYZER_GUARD_ALLOWLIST = {
  "spec/rigor/analysis/worker_session_spec.rb" => {
    399 => "the buffer half of the pair below: `target_ruby: \"3.0\"` is version-shaped but older than " \
           "Prism supports, so `Prism.parse` raises ArgumentError out of the buffer path and the example " \
           "asserts on the resulting `internal analyzer error` row.",
    504 => "the non-buffer twin, pinning the whole rescue envelope (path, line, column, severity, " \
           "exception class, message). No `allow_*` flag can express \"expect the check-rule crash\" " \
           "without making the guard a no-op for this call, which is why these two are entries and the " \
           "two plugin-crash examples in the same file are not."
  }
}.freeze

# Scans one spec file for analyzer runs whose diagnostics never reach {InternalAnalyzerErrorGuard}.
#
# A "run site" is a call to `run` / `run_source` / `analyze` / `analyze_body` whose receiver is an analyzer
# the same file produced — constructed inline, held in a local, or returned by a local factory method.
#
# It is satisfied STRUCTURALLY: the site is an argument of a guard call, or it is assigned to a local that
# a guard call later takes as an argument in the same scope. The first cut of this gate asked only whether
# the enclosing method or example MENTIONED the guard constant, which is not a property of the run at all —
# a comment, a string, a `raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed)` matcher, or a `check!`
# on a DIFFERENT result in the same example all laundered an unguarded run past it (issue #674 review; the
# `check!(a)`-vouches-for-`b` shape is the one that would happen by accident). Requiring the guard to name
# the value costs nothing: on the tree as it stands the structural rule accepts every site the textual one
# did.
module SpecAnalyzerGuardScan
  # Issue #683 — `IncrementalSession` is the third analyzer class the gate tracks, alongside `Runner`
  # and `WorkerSession`.
  ANALYZER_CLASSES = %w[Runner WorkerSession IncrementalSession].freeze
  # `analyze` is `WorkerSession`'s PUBLIC per-file entry; `analyze_body` is the private half behind it,
  # listed so that making it public later cannot open a hole. A bare `analyze(...)` with no receiver is
  # `RunnerHelpers#analyze`, which is already guarded — a run site needs an analyzer receiver, so it is
  # never matched here. `baseline` / `recheck` / `run_incremental` / `run_buffer_recheck` /
  # `reanalyze_subset` are `IncrementalSession`'s five run methods (#683, #695) — none of their names
  # collide with `Runner`'s or `WorkerSession`'s, so listing them here applies only to an
  # `IncrementalSession` receiver in practice.
  RUN_METHODS = %i[run run_source analyze analyze_body baseline recheck run_incremental
                   run_buffer_recheck reanalyze_subset].freeze
  GUARD_CONSTANT = "InternalAnalyzerErrorGuard"
  GUARD_METHODS = %i[check! check_diagnostics!].freeze
  # Where an example's own scope begins. A run site inside one of these must carry its own guard.
  EXAMPLE_SCOPES = %i[it specify example fit fspecify xit xspecify let let! subject subject!
                      before after around].freeze

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
      return false unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      ANALYZER_CLASSES.include?(node.name.to_s)
    end

    # `Rigor::Analysis::Runner.new(...)`, `Runner.new(...)`, or `described_class.new(...)` in a file that
    # describes one.
    def construction?(node, described:)
      return false unless node.is_a?(Prism::CallNode) && node.name == :new

      receiver = node.receiver
      return true if analyzer_constant?(receiver)

      described && receiver.is_a?(Prism::CallNode) && receiver.name == :described_class && receiver.receiver.nil?
    end

    # Local variables ever assigned an analyzer construction OR a call to a known factory method,
    # file-wide. Deliberately not scope-aware: a name reused for something else would only cost a
    # spurious hit on `<name>.run`, and no spec has one.
    #
    # The factory half (issue #683) matters whenever a file's ONLY session-producing shape is
    # `session = session_for(dir)` with no bare `described_class.new` / `Rigor::Analysis::X.new`
    # assigned to that same name anywhere else in the file: without it, `session` never enters this
    # set, so `session.baseline` downstream is invisible to {#run_site?} even though `session_for`
    # itself IS a recognised factory ({#collect_factory_methods}) — `cross_file_value_constant_incremental_spec.rb`
    # was exactly this shape, and every one of its `session.baseline` / `session.recheck` calls
    # scanned clean only because no OTHER file in the corpus happened to reuse the name "session" on
    # a direct construction (the coincidence #674's own review warned a file-granular gate hides).
    def collect_analyzer_locals(root)
      described = describes_analyzer?(root)
      factories = collect_factory_methods(root)
      names = []
      walk(root, []) do |node, _|
        next unless node.is_a?(Prism::LocalVariableWriteNode)

        value = node.value
        next unless construction?(value, described: described) || factory_call?(value, factories)

        names << node.name
      end
      names.uniq
    end

    # `name = factory_method(...)` — a bare call (no receiver) to a method {#collect_factory_methods}
    # already proved constructs an analyzer.
    def factory_call?(node, factories)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && factories.include?(node.name)
    end

    # `def build_runner(...) = <construction>` — a factory, so `build_runner(...).run` is a run site too.
    # Issue #695 — transitive and conditional:
    # 1. A factory whose body calls another factory (`def make(d) = session_for(d)`) is recognised.
    # 2. A factory whose return expression (or any branch / return statement) yields an analyzer.
    def collect_factory_methods(root)
      described = describes_analyzer?(root)
      factories = []
      loop do
        size_before = factories.size
        walk(root, []) do |node, _|
          next unless node.is_a?(Prism::DefNode)
          next if factories.include?(node.name)

          factories << node.name if def_produces_analyzer?(node, described: described, factories: factories)
        end
        break if factories.size == size_before
      end
      factories.uniq
    end

    def def_produces_analyzer?(def_node, described:, factories:)
      return false if def_node.body.nil?

      has_exit = false
      walk(def_node.body, []) do |child, _|
        if child.is_a?(Prism::ReturnNode) || child.is_a?(Prism::BreakNode)
          arg = child.arguments&.arguments&.last
          has_exit = true if produces_analyzer?(arg, described: described, factories: factories)
        end
      end
      return true if has_exit

      last = def_node.body.is_a?(Prism::StatementsNode) ? def_node.body.body.last : def_node.body
      produces_analyzer?(last, described: described, factories: factories)
    end

    def produces_analyzer?(node, described:, factories:)
      return false if node.nil?
      return true if construction?(node, described: described) || factory_call?(node, factories)

      branch_produces_analyzer?(node, described: described, factories: factories)
    end

    def branch_produces_analyzer?(node, described:, factories:)
      case node
      when Prism::IfNode
        produces_analyzer?(node.statements&.body&.last, described: described, factories: factories) ||
          produces_analyzer?(node.subsequent, described: described, factories: factories)
      when Prism::ElseNode
        produces_analyzer?(node.statements&.body&.last, described: described, factories: factories)
      when Prism::BeginNode
        begin_produces_analyzer?(node, described: described, factories: factories)
      when Prism::RescueModifierNode
        produces_analyzer?(node.expression, described: described, factories: factories) ||
          produces_analyzer?(node.rescue_expression, described: described, factories: factories)
      when Prism::CaseNode
        case_produces_analyzer?(node, described: described, factories: factories)
      else
        false
      end
    end

    def begin_produces_analyzer?(node, described:, factories:)
      ensure_stmt = node.ensure_clause&.statements
      produces_analyzer?(node.statements&.body&.last, described: described, factories: factories) ||
        rescue_produces_analyzer?(node.rescue_clause, described: described, factories: factories) ||
        produces_analyzer?(node.else_clause, described: described, factories: factories) ||
        produces_analyzer?(ensure_stmt&.body&.last, described: described, factories: factories)
    end

    def rescue_produces_analyzer?(node, described:, factories:)
      curr = node
      while curr
        return true if produces_analyzer?(curr.statements&.body&.last, described: described, factories: factories)

        curr = curr.subsequent
      end
      false
    end

    def case_produces_analyzer?(node, described:, factories:)
      node.conditions.any? do |w|
        produces_analyzer?(w.statements&.body&.last, described: described, factories: factories)
      end || produces_analyzer?(node.else_clause, described: described, factories: factories)
    end

    def run_site?(node, analyzer_locals:, factories:, described:)
      return false unless node.is_a?(Prism::CallNode) && RUN_METHODS.include?(node.name)

      receiver = node.receiver
      return true if construction?(receiver, described: described)
      return true if receiver.is_a?(Prism::LocalVariableReadNode) && analyzer_locals.include?(receiver.name)

      factory_call?(receiver, factories)
    end

    # Structural, in the two shapes a real wrapper takes:
    #
    #   1. the run is an argument of the guard call —  `check!(runner.run, context: …)`
    #   2. the run reaches a local the guard call names — `result = Dir.chdir(d) { …run }` … `check!(result, …)`
    #
    # For (2) the search is confined to the site's own scope (its enclosing `def`, else its enclosing
    # example), so a `check!` in a sibling helper cannot vouch for it, and the local has to be the one
    # actually checked — `a = …run; b = …run; check!(a)` leaves `b` an offense.
    def guarded?(stack)
      return true if stack.any? { |ancestor| guard_call?(ancestor) }

      names = assigned_local_names(stack)
      return false if names.empty?

      guard_checks_local?(scope_node(stack), names)
    end

    def guard_call?(node)
      node.is_a?(Prism::CallNode) && GUARD_METHODS.include?(node.name) &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_s == GUARD_CONSTANT
    end

    # The local(s) the run's value flows into, if any: the innermost enclosing `<local> = …` that is
    # still inside the site's own scope. Handles the `result = Dir.chdir(dir) { …run }` shape, a bare
    # `result = …run`, and — issue #683 review — a MultiWriteNode destructure (`diagnostics, warm =
    # session.run_incremental(…)`), the shape every `run_incremental` / `run_buffer_recheck` caller uses
    # since both return a `[diagnostics, warm]` / possibly-nil tuple rather than a bare Array. Without this
    # a manual `check_diagnostics!(diagnostics, context: …)` right below such a line had no accepted shape
    # at all — the gate's own failure message told the reader to "call the guard yourself" and then
    # rejected the result.
    def assigned_local_names(stack)
      stack.reverse_each do |ancestor|
        return [ancestor.name] if ancestor.is_a?(Prism::LocalVariableWriteNode)
        return ancestor.lefts.grep(Prism::LocalVariableTargetNode).map(&:name) if ancestor.is_a?(Prism::MultiWriteNode)
        break if ancestor.is_a?(Prism::DefNode)
      end
      []
    end

    # The innermost `def`, else the innermost example block, else the whole file.
    def scope_node(stack)
      stack.each_index.reverse_each do |i|
        ancestor = stack[i]
        return ancestor if ancestor.is_a?(Prism::DefNode)
        return ancestor if example_scope?(ancestor, stack[i - 1])
      end
      stack.first
    end

    def guard_checks_local?(scope, names)
      return false if scope.nil?

      found = false
      walk(scope, []) do |node, _|
        next unless guard_call?(node)

        found ||= (node.arguments&.arguments || []).any? do |argument|
          argument.is_a?(Prism::LocalVariableReadNode) && names.include?(argument.name)
        end
      end
      found
    end

    # A `BlockNode` carries no parent pointer, so the owning call comes from the walk stack: the node
    # directly above a block is always the call it is attached to.
    def example_scope?(node, parent)
      node.is_a?(Prism::BlockNode) && parent.is_a?(Prism::CallNode) && EXAMPLE_SCOPES.include?(parent.name)
    end
  end
end

RSpec.describe "analyzer runs in spec/ reach the internal-error guard (#674)" do
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

    # Issue #683 review — a local assigned from a FACTORY call (rather than a bare construction) is
    # just as much an analyzer local as one built inline, and `cross_file_value_constant_incremental_spec.rb`
    # was invisible to the gate for exactly this reason: `session = session_for(dir)` never populated
    # `collect_analyzer_locals` because that scan looked only for a direct `.new` on the RHS.
    it "flags a run through a local assigned from a factory method (not a bare construction)" do
      expect(offense_lines(<<~RUBY)).to eq([7])
        def build_runner(dir)
          Rigor::Analysis::Runner.new(configuration: config(dir))
        end

        it "x" do
          runner = build_runner(dir)
          runner.run
        end
      RUBY
    end

    # Issue #695 — transitive factory: def make(d) = session_for(d)
    it "flags a run through a transitive factory method" do
      expect(offense_lines(<<~RUBY)).to eq([11])
        def session_for(dir)
          Rigor::Analysis::IncrementalSession.new(configuration: config(dir))
        end

        def make(dir)
          session_for(dir)
        end

        it "x" do
          session = make(dir)
          session.baseline
        end
      RUBY
    end

    # Issue #695 — conditional factory: def make(d) = if cond then Runner.new else other_runner end
    it "flags a run through a factory whose return expression is a conditional with an analyzer branch" do
      expect(offense_lines(<<~RUBY)).to eq([11])
        def make_runner(flag, dir)
          if flag
            Rigor::Analysis::Runner.new(configuration: config(dir))
          else
            Rigor::Analysis::Runner.new(configuration: other_config(dir))
          end
        end

        it "x" do
          runner = make_runner(true, dir)
          runner.run
        end
      RUBY
    end

    it "flags a run through an else-branch analyzer factory" do
      expect(offense_lines(<<~RUBY)).to eq([11])
        def make_runner(flag, dir)
          if flag
            123
          else
            Rigor::Analysis::Runner.new(configuration: config(dir))
          end
        end

        it "x" do
          runner = make_runner(false, dir)
          runner.run
        end
      RUBY
    end

    it "flags a run through a ternary else-branch factory" do
      expect(offense_lines(<<~RUBY)).to eq([7])
        def make_runner(flag, dir)
          flag ? 123 : Rigor::Analysis::Runner.new(configuration: config(dir))
        end

        it "x" do
          runner = make_runner(false, dir)
          runner.run
        end
      RUBY
    end

    it "flags a run through a begin-block endless factory" do
      expect(offense_lines(<<~RUBY)).to eq([5])
        def make = begin; Rigor::Analysis::Runner.new; end

        it "x" do
          runner = make
          runner.run
        end
      RUBY
    end

    it "flags a run through an early-return factory" do
      expect(offense_lines(<<~RUBY)).to eq([9])
        def make_runner(cond)
          return Rigor::Analysis::Runner.new if cond

          nil
        end

        it "x" do
          runner = make_runner(true)
          runner.run
        end
      RUBY
    end

    it "flags a run through a rescue-clause factory" do
      expect(offense_lines(<<~RUBY)).to eq([9])
        def make_runner
          risky_call
        rescue StandardError
          Rigor::Analysis::Runner.new
        end

        it "x" do
          runner = make_runner
          runner.run
        end
      RUBY
    end

    it "flags a run through a rescue-modifier factory" do
      expect(offense_lines(<<~RUBY)).to eq([5])
        def make_runner = nil rescue Rigor::Analysis::Runner.new

        it "x" do
          runner = make_runner
          runner.run
        end
      RUBY
    end

    it "flags a run through an ensure-clause factory" do
      expect(offense_lines(<<~RUBY)).to eq([9])
        def make_runner
          nil
        ensure
          Rigor::Analysis::Runner.new
        end

        it "x" do
          runner = make_runner
          runner.run
        end
      RUBY
    end

    it "flags a run through a loop-break factory" do
      expect(offense_lines(<<~RUBY)).to eq([9])
        def make_runner
          loop do
            break Rigor::Analysis::Runner.new
          end
        end

        it "x" do
          runner = make_runner
          runner.run
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

    it "accepts a result the guard names after a chdir block" do
      expect(offense_lines(<<~RUBY)).to be_empty
        def diagnostics_for(source)
          result = Dir.chdir(dir) { Rigor::Analysis::Runner.new(configuration: config).run }
          InternalAnalyzerErrorGuard.check!(result, context: "diagnostics_for").diagnostics
        end
      RUBY
    end

    it "flags a `WorkerSession#analyze`, the public per-file entry that returns a bare Array" do
      expect(offense_lines(<<~RUBY)).to eq([3])
        it "x" do
          session = Rigor::Analysis::WorkerSession.new(configuration: config, environment: env)
          diags = session.analyze(path)
        end
      RUBY
    end

    it "accepts a `WorkerSession#analyze` through the Array-shaped guard" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          session = Rigor::Analysis::WorkerSession.new(configuration: config, environment: env)
          diags = InternalAnalyzerErrorGuard.check_diagnostics!(session.analyze(path), context: "x")
        end
      RUBY
    end

    # Issue #683 — `IncrementalSession` is a third analyzer class, with four run methods of its own.
    it "flags an `IncrementalSession#baseline` / `#recheck` pair, unguarded" do
      expect(offense_lines(<<~RUBY)).to eq([3, 5])
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          session.baseline
          edit_files
          session.recheck
        end
      RUBY
    end

    it "flags a bare `IncrementalSession#run_incremental` / `#run_buffer_recheck` chain" do
      expect(offense_lines(<<~RUBY)).to eq([2, 3])
        it "x" do
          Rigor::Analysis::IncrementalSession.new(configuration: config).run_incremental(snapshot: s, fingerprint: fp)
          Rigor::Analysis::IncrementalSession.new(configuration: config).run_buffer_recheck(snapshot: s, fingerprint: fp)
        end
      RUBY
    end

    it "flags an unguarded `IncrementalSession#reanalyze_subset` call (#695)" do
      expect(offense_lines(<<~RUBY)).to eq([3])
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          session.reanalyze_subset(%w[a.rb])
        end
      RUBY
    end

    it "accepts an `IncrementalSession` run through the matching guarded_* helper" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          guarded_baseline(session)
          edit_files
          guarded_recheck(session)
          guarded_reanalyze_subset(session, %w[a.rb])
          guarded_run_incremental(session, snapshot: s, fingerprint: fp)
          guarded_run_buffer_recheck(session, snapshot: s, fingerprint: fp)
        end
      RUBY
    end

    # Issue #683 review — `run_incremental` / `run_buffer_recheck` return a tuple / possibly-nil struct, so
    # a manual (non-helper) guard site destructures the result: `assigned_local_name` recognised only a
    # bare `LocalVariableWriteNode`, so this shape had NO accepted form at all before the fix below.
    it "flags a manually-destructured `run_incremental` whose local is never checked" do
      expect(offense_lines(<<~RUBY)).to eq([3])
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          diagnostics, warm = session.run_incremental(snapshot: s, fingerprint: fp)
          expect(warm).to be(true)
        end
      RUBY
    end

    it "accepts a manually-destructured `run_incremental` checked via the FIRST target local" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          diagnostics, warm = session.run_incremental(snapshot: s, fingerprint: fp)
          InternalAnalyzerErrorGuard.check_diagnostics!(diagnostics, context: "x")
        end
      RUBY
    end

    # The scanner does not know WHICH destructured name a real guard call would sensibly take — it only
    # has to stop rejecting every one of them, so checking the second target proves it tracks the whole
    # `lefts` list, not just the first.
    it "accepts a manually-destructured `run_incremental` checked via the SECOND target local" do
      expect(offense_lines(<<~RUBY)).to be_empty
        it "x" do
          session = Rigor::Analysis::IncrementalSession.new(configuration: config)
          diagnostics, warm = session.run_incremental(snapshot: s, fingerprint: fp)
          InternalAnalyzerErrorGuard.check_diagnostics!(warm, context: "x")
        end
      RUBY
    end

    # The seven ways the first cut of this gate — "does the enclosing scope MENTION the guard constant?" —
    # could be talked out of an offense. None of them is a property of the run.
    describe "laundering the guard by merely naming it" do
      it "is not fooled by a comment" do
        expect(offense_lines(<<~RUBY)).to eq([3])
          it "x" do
            # InternalAnalyzerErrorGuard is not needed here
            Rigor::Analysis::Runner.new(configuration: config).run
          end
        RUBY
      end

      it "is not fooled by a string" do
        expect(offense_lines(<<~RUBY)).to eq([3])
          it "x" do
            note = "InternalAnalyzerErrorGuard"
            Rigor::Analysis::Runner.new(configuration: config).run
          end
        RUBY
      end

      it "is not fooled by a raise_error matcher naming the guard's exception" do
        expect(offense_lines(<<~RUBY)).to eq([2])
          it "x" do
            result = Rigor::Analysis::Runner.new(configuration: config).run
            expect { result }.not_to raise_error(InternalAnalyzerErrorGuard::AnalyzerCrashed)
          end
        RUBY
      end

      it "is not fooled by a call to the crash predicate" do
        expect(offense_lines(<<~RUBY)).to eq([2])
          it "x" do
            result = Rigor::Analysis::Runner.new(configuration: config).run
            expect(result.diagnostics.none? { |d| InternalAnalyzerErrorGuard.crash?(d) }).to be(true)
          end
        RUBY
      end

      it "is not fooled by a bare mention of the constant" do
        expect(offense_lines(<<~RUBY)).to eq([3])
          it "x" do
            InternalAnalyzerErrorGuard
            Rigor::Analysis::Runner.new(configuration: config).run
          end
        RUBY
      end

      it "is not fooled by a nested def that mentions the guard" do
        expect(offense_lines(<<~RUBY)).to eq([2])
          it "x" do
            Rigor::Analysis::Runner.new(configuration: config).run
            define_method(:unused) { InternalAnalyzerErrorGuard }
          end
        RUBY
      end

      # The one that would happen by accident: a second run added to an example that already checks one.
      it "is not fooled by a check! on a DIFFERENT result in the same example" do
        expect(offense_lines(<<~RUBY)).to eq([3])
          it "x" do
            a = Rigor::Analysis::Runner.new(configuration: config).run
            b = Rigor::Analysis::Runner.new(configuration: other_config).run
            InternalAnalyzerErrorGuard.check!(a, context: "x")
            expect(b.diagnostics).to be_empty
          end
        RUBY
      end
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
    let(:offenders) do
      Dir.glob(File.join(SPEC_ANALYZER_GUARD_ROOT, "spec/**/*.rb")).filter_map do |path|
        relative = path.delete_prefix("#{SPEC_ANALYZER_GUARD_ROOT}/")
        exempt = SPEC_ANALYZER_GUARD_ALLOWLIST.fetch(relative, {})

        found = SpecAnalyzerGuardScan.offenses(File.read(path)).reject { |o| exempt.key?(o.line) }
        next if found.empty?

        "#{relative}\n    #{found.map { |o| "L#{o.line}: #{o.source}" }.join("\n    ")}"
      end
    end

    # Site-granular, so an entry cannot quietly cover a sibling site that was merely missed: each
    # allowlisted LINE has to still be an offense on its own.
    it "keeps every allowlisted site present and still offending" do
      stale = SPEC_ANALYZER_GUARD_ALLOWLIST.flat_map do |relative, sites|
        path = File.join(SPEC_ANALYZER_GUARD_ROOT, relative)
        next ["#{relative} (file is gone)"] unless File.exist?(path)

        offending = SpecAnalyzerGuardScan.offenses(File.read(path)).map(&:line)
        (sites.keys - offending).map { |line| "#{relative}:#{line}" }
      end

      expect(stale).to be_empty, <<~MSG
        Allowlisted sites that are no longer unguarded runs — delete the entry, or move its line number
        if the file was edited around it:
          #{stale.join("\n  ")}
      MSG
    end

    it "routes every other analyzer run through the guard" do
      expect(offenders).to be_empty, <<~MSG
        An analyzer run in spec/ whose Result never reaches InternalAnalyzerErrorGuard (#674 / #683).

        A check rule that raises is rescued into ONE "internal analyzer error" diagnostic and every other
        diagnostic for that file is discarded, so an absence assertion on the raw Result passes while
        nothing ran. Use the harness helpers at the construction site:

            guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
            guarded_run(runner, %w[app.rb])
            guarded_run_source(runner, source: source, path: "mem.rb")
            guarded_session_analyze(session, path)
            guarded_baseline(session)
            guarded_recheck(session)
            guarded_reanalyze_subset(session, subset)
            guarded_run_incremental(session, snapshot: snapshot, fingerprint: fingerprint)
            guarded_run_buffer_recheck(session, snapshot: snapshot, fingerprint: fingerprint)

        Outside example scope (a `def self.` memo, a plain helper class) call the guard yourself, and note
        that the guard has to name the VALUE — a `check!` on a different result in the same example does
        not count:

            InternalAnalyzerErrorGuard.check!(runner.run, context: "<what ran it>")
            result = Dir.chdir(dir) { runner.run }
            InternalAnalyzerErrorGuard.check!(result, context: "<what ran it>")

        If it deliberately crashes a PLUGIN, keep the guard and pass `allow_plugin_crash: true` — the
        check-rule half stays armed. Only if the site's SUBJECT is the check-rule crash diagnostic itself
        does it belong in SPEC_ANALYZER_GUARD_ALLOWLIST, keyed by line, with the reason.

        #{offenders.join("\n  ")}
      MSG
    end
  end
end
