# frozen_string_literal: true

require "spec_helper"

# `call.wrong-arity` family — `CheckRules::WrongArity` (once check_rules.rb ~L1084-1232: `wrong_arity_diagnostic`,
# `anonymous_struct_new_call?`, `plain_positional_call?`, `simple_positional?`,
# `compute_arity_envelope`, `arity_eligible?`) plus the `build_arity_diagnostic` builder (~L2510). Fires
# when an explicit-receiver call's positional argument count falls outside the RBS-declared arity
# envelope of the resolved method.
#
# First spec for this family (#135 checkbox-1 wave 1). Mutation recon measured 5 de-noised survivors from
# 7 biteable sites; 4 of them — L1151/L1153/L1154/L1157, the whole body of `anonymous_struct_new_call?` —
# were entirely unobserved: no existing example anywhere in the suite drove an arity check through a
# chained `Struct.new(...).new` call. The 5th, `build_arity_diagnostic`'s `from_message_loc` (L2514), was
# unobserved too.
RSpec.describe Rigor::Analysis::CheckRules::WrongArity do
  def diagnostics_for(source)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
  end

  def arity_diagnostics(source)
    diagnostics_for(source).select { |d| d.rule == "call.wrong-arity" }
  end

  describe "wrong_arity_diagnostic (entry point)" do
    it "fires on a call whose positional count exceeds the RBS envelope" do
      diags = arity_diagnostics("[1].rotate(1, 2)\n")
      expect(diags.size).to eq(1)

      diagnostic = diags.first
      expect(diagnostic.rule).to eq("call.wrong-arity")
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.error?).to be(true)
      expect(diagnostic.receiver_type).to eq("Array")
      expect(diagnostic.method_name).to eq("rotate")
      expect(diagnostic.line).to eq(1)
      expect(diagnostic.column).to eq(5) # points at `rotate`, not the `[1]` receiver
      expect(diagnostic.message).to eq("wrong number of arguments to `rotate' on Array (given 2, expected 0..1)")
    end

    it "declines when the positional count is within the envelope (adjacent to the firing case above)" do
      expect(arity_diagnostics("[1].rotate(1)\n")).to be_empty
    end
  end

  describe "build_arity_diagnostic message shape" do
    # Mutation survivor L2514 — the `Diagnostic.from_message_loc` call inside the builder. These two
    # examples pin both arms of `range = min == max ? min.to_s : "#{min}..#{max}"`: a mutant that always
    # renders the ranged form (or always the bare number) goes wrong on one of the two messages below.
    it "renders a bare number when min == max (String#+ takes exactly one positional)" do
      diags = arity_diagnostics(%("a".+()\n))
      expect(diags.size).to eq(1)
      expect(diags.first.message).to eq("wrong number of arguments to `+' on String (given 0, expected 1)")
    end

    it "declines when the exact arity is satisfied (adjacent to the firing case above)" do
      expect(arity_diagnostics(%("a".+("b")\n))).to be_empty
    end

    it "renders a min..max range when min != max (Array#rotate takes zero or one)" do
      diags = arity_diagnostics("[1].rotate(1, 2)\n")
      expect(diags.first.message).to include("expected 0..1")
    end
  end

  describe "plain_positional_call? / simple_positional? (call-site shape gating)" do
    it "fires on a plain positional call (baseline, adjacent to the declines below)" do
      expect(arity_diagnostics("[1].rotate(1, 2)\n")).not_to be_empty
    end

    it "declines a splat argument — SplatNode disqualifies plain_positional_call?" do
      # `args` carries 2 elements, a real arity mismatch at runtime too — this pins that the decline is
      # structural (the splat's element count isn't known statically), not a lucky count match.
      expect(arity_diagnostics("args = [1, 2]\n[1].rotate(*args)\n")).to be_empty
    end

    it "declines a keyword-argument call — KeywordHashNode disqualifies plain_positional_call?" do
      expect(arity_diagnostics("[1].rotate(count: 2)\n")).to be_empty
    end

    it "declines a block-pass argument — BlockArgumentNode disqualifies plain_positional_call?" do
      expect(arity_diagnostics("blk = proc {}\n[1].rotate(&blk)\n")).to be_empty
    end

    it "declines a `...` forwarding call — ForwardingArgumentsNode disqualifies plain_positional_call?" do
      source = <<~RUBY
        def wrapper(...)
          [1].rotate(...)
        end
        wrapper(1, 2)
      RUBY
      expect(arity_diagnostics(source)).to be_empty
    end
  end

  describe "compute_arity_envelope / arity_eligible?" do
    it "fires against a finite optional-positional envelope (baseline, adjacent to the declines below)" do
      expect(arity_diagnostics("[1].rotate(1, 2)\n")).not_to be_empty
    end

    it "declines any positional count once an overload has rest positionals (max raised to Infinity)" do
      # Array#push is `(*E objects) -> self` — a rest positional raises `max` to Float::INFINITY, so no
      # actual count can ever fall outside `[0, Infinity]`. Five arguments overflows `rotate`'s `[0, 1]`
      # envelope above; push must stay silent regardless of how many are given.
      expect(arity_diagnostics("[1].push(1, 2, 3, 4, 5)\n")).to be_empty
    end

    it "declines a method whose only overload has required keywords (arity_eligible? bails the method)" do
      # NoMatchingPatternKeyError#initialize is `(?string message, matchee: M, key: K) -> void` — required
      # keywords make `arity_eligible?` return false, so `compute_arity_envelope` returns nil for the whole
      # method and this (badly wrong, 4-positional) call is never checked.
      expect(arity_diagnostics("NoMatchingPatternKeyError.new(1, 2, 3, 4)\n")).to be_empty
    end
  end

  describe "anonymous_struct_new_call? (the Struct.new(...).new chain)" do
    it "fires on a bare Struct.new() — the class-defining call needs at least one positional" do
      # Baseline: with no inner `.new` chain, `anonymous_struct_new_call?` never triggers — its
      # `receiver.is_a?(Prism::CallNode) && receiver.name == :new` guard (L1151) is false because the
      # receiver here is a bare ConstantReadNode. So the real `Struct.new` envelope `[1, Infinity]` applies,
      # and 0 args is a genuine wrong-arity firing. Pairs with the chained decline below, same zero-arg
      # count, opposite verdict.
      diags = arity_diagnostics("Struct.new()\n")
      expect(diags.size).to eq(1)
      expected_message = "wrong number of arguments to `new' on Struct (given 0, expected 1..Infinity)"
      expect(diags.first.message).to eq(expected_message)
    end

    it "declines Struct.new(:a, :b).new() with zero args — the chained anonymous-subclass exclusion" do
      # The mutation-recon prize: L1151/L1153/L1154/L1157 were entirely unobserved before this spec.
      # `Struct.new(:a, :b)` types as `Singleton[Struct]` (the dispatcher's `struct_new_lift`), so the outer
      # `.new` would otherwise be checked against the SAME `[1, Infinity]` envelope as the bare case above
      # and wrongly fire on 0 args — but the chained anonymous subclass's real `.new` accepts any arity
      # (every unset member defaults to nil). `anonymous_struct_new_call?` detects the `receiver.receiver`
      # (L1153) ConstantReadNode named `:Struct` (L1154) chained through a `.new` CallNode (L1151) and skips
      # the check entirely.
      expect(arity_diagnostics("Struct.new(:a, :b).new()\n")).to be_empty
    end

    it "declines Struct.new(:a, :b).new(1, 2) with a matching member count" do
      expect(arity_diagnostics("Struct.new(:a, :b).new(1, 2)\n")).to be_empty
    end

    it "declines the `::Struct.new(...).new` form — the ConstantPathNode branch (L1157)" do
      # The top-level constant-path spelling exercises the OTHER accepted receiver shape:
      # `inner.parent.nil? && inner.name == :Struct` on a Prism::ConstantPathNode, instead of the
      # ConstantReadNode branch the two examples above exercise.
      expect(arity_diagnostics("::Struct.new(:a, :b).new()\n")).to be_empty
    end
  end

  describe "without the runner (ADR-116 WD1 / C4)" do
    # ADR-116 WD1 / C4 — {CheckRules::WrongArity} on a parsed snippet and its scope index, with no runner: the
    # examples above pin the rule through the whole run at 200-400 ms an example, these at a millisecond or two. The
    # snippet is indexed against an empty scope with the core RBS, so a call is judged against core signatures and what
    # the snippet itself records.
    #
    # Mutation-proved: each guard line (a `return` / `next` modifier) of `diagnostic` and of the helpers it calls was
    # blanked in turn and an example in this file failed, except these, which no input here distinguishes (one line on
    # what was tried each; the first two groups survive in the runner examples above as well):
    #
    # - `return nil if call_node.receiver.nil?` and `return nil if class_name.nil?`: an implicit-self call and an
    #   untyped receiver reach the same nil class name, which the later guards decline; each is backed by the other.
    # - `return nil if scope.nil?`: every call of an indexed snippet has a scope.
    # - `ReceiverPredicates.inferred_param_receiver?`: true only for a parameter whose type the whole-project run infers
    #   from its call sites; a one-file snippet leaves the parameter untyped.
    # - `ReceiverPredicates.unenumerable_receiver_shape?` and `definition_available?`: no core-class receiver tried
    #   (`Array`, `String`, `Object`, `Math`) reaches either; they decline an includer of a module the receiver's RBS
    #   declares (#879), which needs a receiver of that shape.
    # - the chained `Struct.new(...).new` guards (`return nil if anonymous_struct_new_call?` and the four conditions
    #   inside it): blanking any one leaves the zero-argument chained example above green, here and in the runner
    #   describe, because the `Struct.new(:a, :b).new()` call is declined before it reaches the test.
    # - `return false if arg.is_a?(Prism::BlockArgumentNode)` in `simple_positional?`: Prism keeps a block-pass on
    #   `call.block`, never in `arguments`, so the test cannot be true.
    # - `return nil if mins.empty?` and `return false unless function.respond_to?(:required_keywords)`: a method with no
    #   overload, and a method with an untyped `(?)` signature, were not found among the core methods tried.
    # - `return false unless kind == :singleton && call_node.name == :new` and `return false unless
    #   method_def.respond_to?(:defined_in)` in `undeclared_constructor?`: the line after them answers the same for
    #   every instance method of a core class, and every resolved method answers `defined_in`.
    # - the whole project-`def` lane (`arity_report_withheld?`'s `source_arity` test, `source_lane_open?` and its
    #   guard in `arity_envelope_for`, and every guard of `source_arity_envelope`, `project_module?` and
    #   `project_module_class_receiver?`): it needs `discovered_parameter_envelopes` keyed project-wide, which only a
    #   whole-project pre-pass records; a snippet's own `def` (`A.new.f` with `def f(a)`, with optionals, on a module,
    #   on a `self.` method, a constructor) gives no row either way. `spec/integration/source_arity_resolution_spec.rb`
    #   and `arity_declared_source_method_spec.rb` pin it through the runner.
    def calls_in(node, found = [])
      found << node if node.is_a?(Prism::CallNode)
      node.compact_child_nodes.each { |child| calls_in(child, found) }
      found
    end

    def scope_index_of(program)
      Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    end

    # `[line, message]` for each call of `source` the rule reports.
    def fired(source)
      program = Prism.parse(source).value
      scope_index = scope_index_of(program)
      sites = Rigor::Analysis::CheckRules::LexicalMethodSites.new(program)
      calls_in(program).filter_map do |call|
        row = described_class.diagnostic("mem.rb", call, Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index),
                                         sites)
        [call.location.start_line, row.message] if row
      end
    end

    describe "an instance receiver" do
      it "reports too many arguments, with the declared range" do
        expect(fired("[1].rotate(1, 2)\n")).to eq(
          [[1, "wrong number of arguments to `rotate' on Array (given 2, expected 0..1)"]]
        )
      end

      it "reports too few arguments, with the bare count when the arity is exact" do
        expect(fired(%("a".+()\n))).to eq([[1, "wrong number of arguments to `+' on String (given 0, expected 1)"]])
      end

      it "carries the rule id, the error severity, the receiver class and the method name" do
        program = Prism.parse("[1].rotate(1, 2)\n").value
        call = calls_in(program).find { |c| c.name == :rotate }
        row = described_class.diagnostic("mem.rb", call,
                                         Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index_of(program)))

        expect([row.rule, row.severity, row.receiver_type, row.method_name, row.path, row.line, row.column]).to eq(
          [Rigor::Analysis::CheckRules::RULE_WRONG_ARITY, :error, "Array", "rotate", "mem.rb", 1, 5]
        )
      end

      it "is silent inside the envelope, at both ends" do
        expect([fired("[1].rotate\n"), fired("[1].rotate(1)\n")]).to eq([[], []])
      end

      it "is silent for an implicit-self call" do
        expect(fired("def t = rotate(1, 2)\n")).to eq([])
      end

      it "is silent under a refinement of the receiver's class that redefines the method" do
        source = "module R\n  refine Array do\n    def rotate(a, b) = self\n  end\nend\nusing R\n[1].rotate(1, 2)\n"

        expect(fired(source)).to eq([])
      end

      it "reports under a refinement of the class that does not touch the method" do
        source = "module R\n  refine Array do\n    def other = 1\n  end\nend\nusing R\n[1].rotate(1, 2)\n"

        expect(fired(source).map(&:first)).to eq([7])
      end

      it "is silent for a call with a splat argument" do
        expect(fired("a = [1]\n[1].rotate(*a, 2)\n")).to eq([])
      end

      it "is silent for a call passing keywords" do
        expect(fired("[1].rotate(1, k: 2)\n")).to eq([])
      end

      it "is silent for a call forwarding `...`" do
        expect(fired("def t(...) = [1].rotate(...)\n")).to eq([])
      end

      it "ignores a block argument when it counts the positionals" do
        expect(fired("[1].rotate(1, 2, &:x)\n").map(&:first)).to eq([1])
      end

      it "is silent when the receiver has no single class" do
        expect(fired("def t(x) = x.rotate(1, 2)\n")).to eq([])
      end
    end

    describe "a class-object receiver" do
      it "reports a module function called with too many arguments" do
        message = "wrong number of arguments to `sqrt' on Math (given 2, expected 1)"

        expect(fired("Math.sqrt(1, 2)\n")).to eq([[1, message]])
      end

      it "is silent for a chained `Struct.new(...).new`, whose anonymous subclass takes any count" do
        expect(fired("Struct.new(:a, :b).new(1, 2, 3)\n")).to eq([])
      end

      it "is silent for a class whose constructor no loaded RBS declares" do
        expect(fired("Gem::Specification.new(1, 2, 3)\n")).to eq([])
      end
    end

    describe ".plain_positional_call?" do
      def call_of(source)
        calls_in(Prism.parse(source).value).first
      end

      it "is true for no arguments, for plain positionals and for a block-pass (which Prism keeps off the arguments)" do
        sources = ["x.f", "x.f(1)", "x.f(1, 'a')", "x.f(&b)"]

        expect(sources.map { |s| described_class.plain_positional_call?(call_of(s)) }).to eq([true] * 4)
      end

      it "is false for a splat, keywords or forwarded arguments" do
        sources = ["x.f(*a)", "x.f(k: 1)", "x.f(1, k: 1)", "def t(...) = x.f(...)"]

        expect(sources.map { |s| described_class.plain_positional_call?(call_of(s)) }).to eq([false] * 4)
      end
    end

    it "keeps its helpers private" do
      names = %i[arity_report_withheld? arity_envelope_for source_lane_open? source_arity_envelope
                 project_module_class_receiver? project_module? undeclared_constructor? anonymous_struct_new_call?
                 simple_positional? compute_arity_envelope arity_eligible? build_arity_diagnostic]

      expect(names.map { |m| described_class.respond_to?(m) }).to eq([false] * 12)
    end
  end
end
