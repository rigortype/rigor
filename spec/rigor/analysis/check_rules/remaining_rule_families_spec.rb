# frozen_string_literal: true

require "spec_helper"

# #135 checkbox-1 wave 2 — the SMALL remaining mutation-recon survivor families in `check_rules.rb`, after wave 1
# (PRs #309/#310/#311) closed wrong-arity, the collector-diagnostic builders, suppression, union-receiver and
# safe-navigation undefined-method, and refined-receiver dispatch. Six families, one `describe` each:
#
# - nil_receiver / safe navigation (L1272 `nil_bearing_union_witnesses?`, L1307 `safe_navigation_receiver`, L1357
#   `nil_class_has_method?`) — `safe_navigation_undefined_method_spec.rb` and `union_undefined_method_spec.rb`
#   already cover the N3 silence and the multi-class union path; this closes the `possible-nil-receiver` witness
#   chain those two leave unobserved.
# - undefined_method family (L811 `unresolved_toplevel_diagnostic`, L1051 `build_self_undefined_method_diagnostic`,
#   L1068 `lookup_method`'s singleton branch) — `union_undefined_method_spec.rb`, `refined_receiver_dispatch_spec.rb`
#   and `safe_navigation_undefined_method_spec.rb` cover the scalar/union/refined receiver paths; none of them
#   drive an implicit-self toplevel call, a self-undefined-method miss, or a class(singleton)-level dispatch.
# - always_raises (the Integer zero-division half of L1576 `integer_rooted_for_diagnostic?` and L1586
#   `build_always_raises_diagnostic`) — `raise_non_exception_spec.rb` is the best-covered family in this
#   directory but only exercises the OTHER half (`raise` operand legality); this adds the Integer-division half.
# - dump_type / assert_type (L1440 `dump_type_diagnostic`, L1512 `build_assert_type_diagnostic`) — the
#   `Rigor::Testing` debug helpers; previously exercised only from `runner_spec.rb`, not from this directory.
# - visibility_mismatch (L1860 `build_visibility_mismatch_diagnostic`) — unobserved anywhere in the suite.
# - pipeline/orchestration — of 5 raw survivors clustered under `run_node_collectors`, one (L193, the
#   `collectors.values` call feeding `RuleWalk.run`) is a real, reachable gap: `Runner#run_source` always threads
#   `node_collectors:` (ADR-53 B4's converged walk), so the standalone branch only runs from a direct
#   `CheckRules.diagnose` caller (`FixtureHarness`, `budget_trace_spec.rb`). The other four (L194 x2 on the
#   `ENV["RIGOR_SHADOW_RULE_WALK"]` key/value, L215 x2 inside `comparable`) are reachable only from the
#   `RIGOR_SHADOW_RULE_WALK=1` shadow-verify oracle path (`rule_walk_equivalence_spec.rb`'s doc comment names it
#   as the corpus-scale companion to that spec, not something a curated unit example should flip on — turning it
#   on makes any divergence `raise`, which is a harness invariant, not example-shaped behaviour). Declared decline
#   — no examples written for L194 / L215, mirroring how PR #289 recorded the Ractor-backend cluster as
#   out-of-scope for `pool_coordinator_spec.rb`'s curated examples rather than forcing the backend on in a unit
#   test.
RSpec.describe "remaining check_rules.rb rule families (#135 wave 2)" do
  def diagnostics_for(source)
    runner = Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
    guarded_run_source(runner, source: source, path: "mem.rb").diagnostics
  end

  def rule_diagnostics(source, rule)
    diagnostics_for(source).select { |d| d.rule == rule }
  end

  describe "nil_receiver / safe navigation" do
    # nil_inject / type_swap on the `"NilClass"` argument to `Reflection.rbs_class_known?` (L1272) would make
    # the RBS-availability gate always fail, silencing `possible-nil-receiver` outright — this positive fire
    # is the kill: it only passes when that gate genuinely resolves "NilClass" as known.
    it "fires call.possible-nil-receiver on a `T | nil` local calling a method present on T but absent on NilClass" do
      source = <<~RUBY
        def f(x)
          y = x ? "s" : nil
          y.upcase
        end
      RUBY
      diags = rule_diagnostics(source, "call.possible-nil-receiver")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.message).to eq("possible nil receiver: `upcase' is undefined on NilClass")
      expect(diagnostic.line).to eq(3)
    end

    # nil_inject / type_swap on the `"NilClass"` argument to `Reflection.instance_definition` inside
    # `nil_class_has_method?` (L1357) would make it report "NilClass never defines this method" universally,
    # turning this decline into a false-positive firing. Adjacent to the firing case above (same union shape,
    # method changed from `upcase` — absent on NilClass — to `to_s` — present on NilClass).
    it "stays silent when the method is also present on NilClass (nil_class_has_method? true)" do
      source = <<~RUBY
        def f(x)
          y = x ? "s" : nil
          y.to_s
        end
      RUBY
      expect(rule_diagnostics(source, "call.possible-nil-receiver")).to be_empty
    end

    # undefined_method mutation on `Type::Combinator.bot` (L1307) would raise inside `safe_navigation_receiver`.
    # A rule-scoped assertion (as `safe_navigation_undefined_method_spec.rb` uses) cannot see that: the per-file
    # `rescue StandardError` in `Runner` swallows the raise into an unrelated "internal analyzer error"
    # diagnostic — the ONE diagnostic shape with a nil `rule` (every real rule sets one; see
    # `Diagnostic#initialize`'s `rule: nil` default) — which a `.select { d.rule == "call.undefined-method" }`
    # filter never surfaces. So the kill is "no diagnostic carries a nil rule".
    #
    # That assertion alone would pass VACUOUSLY if the fixture ever stopped reaching
    # `safe_navigation_receiver` (an empty diagnostic list satisfies it, and so does a list that happens to
    # be non-empty only because of an unrelated environment `:info` such as `rbs.coverage.missing-gem`). The
    # `dump_type` line is the non-vacuity anchor: it fires `dump.type` only when the engine actually types
    # that safe-navigation call, so the example cannot silently stop exercising the path it guards.
    it "raises no internal-analyzer-error diagnostic for a `&.` call on a receiver that types as exactly nil" do
      source = <<~RUBY
        class T
          def initialize
            @t = nil
          end

          def alive
            dump_type(@t&.alive?)
          end
        end
      RUBY

      diagnostics = diagnostics_for(source)
      expect(diagnostics.map(&:rule)).to all(be_a(String))
      expect(diagnostics.map(&:rule)).to include("dump.type")
    end
  end

  describe "undefined_method family" do
    it "fires call.unresolved-toplevel on an undefined implicit-self toplevel call" do
      diags = rule_diagnostics("totally_undefined_toplevel_call_zzz\n", "call.unresolved-toplevel")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include("unresolved toplevel call to `totally_undefined_toplevel_call_zzz`")
    end

    # nil_inject / type_swap on the `"Object"` argument to `Reflection.instance_method_definition` (L811) would
    # break this lookup, turning a legitimate Kernel call into a false-positive unresolved-toplevel firing.
    # Adjacent to the firing case above (same implicit-self toplevel shape, real vs. undefined method name).
    it "declines on a real Kernel/Object private method at toplevel (pins the \"Object\" lookup argument)" do
      expect(rule_diagnostics(%(puts "hi"\n), "call.unresolved-toplevel")).to be_empty
    end

    # undefined_method mutation on `Diagnostic.new` (L1051) would raise inside the builder; the rule ships
    # `:off` by default (ADR-24 slice 4), so this opts in via `severity_overrides:` the same way
    # `self_undefined_method_rule_spec.rb` does.
    it "fires call.self-undefined-method on a typo'd sibling call, pinning the Diagnostic.new construction" do
      config = Rigor::Configuration.new("paths" => [],
                                        "severity_overrides" => { "call.self-undefined-method" => "warning" })
      source = <<~RUBY
        class Widget
          def price
            compute_totl
          end

          def compute_total
            100
          end
        end
      RUBY
      runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
      diags = guarded_run_source(runner, source: source, path: "mem.rb")
              .diagnostics.select { |d| d.rule == "call.self-undefined-method" }
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.method_name).to eq(:compute_totl)
      expect(diagnostic.message).to include("implicit-self call to `compute_totl` resolves to no method on `Widget`")
      expect(diagnostic.line).to eq(3)
    end

    # `lookup_method`'s singleton branch (L1068, `Reflection.singleton_method_definition`) is the class-object
    # dispatch path — every other spec in this directory exercises only instance receivers.
    it "fires call.undefined-method for an undefined class(singleton)-level method" do
      diags = rule_diagnostics("Array.no_such_singleton_method_zzz\n", "call.undefined-method")
      expect(diags.size).to eq(1)
      expect(diags.first.message).to include("undefined method `no_such_singleton_method_zzz' for singleton(Array)")
    end

    it "declines on a real Array singleton method (adjacent to the firing case above)" do
      expect(rule_diagnostics("Array.new\n", "call.undefined-method")).to be_empty
    end
  end

  describe "always_raises (Integer zero-division half)" do
    # `rand(100)` types as a non-constant `Type::Nominal["Integer"]` (as opposed to a literal `Constant[5]`), so
    # this exercises the `when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?` arm of
    # `integer_rooted_for_diagnostic?` (L1576) rather than the `Constant` arm the `5 / 0` shape hits. An
    # `undefined_method` mutation on either `.class_name` or `.type_args` there, or on `Diagnostic.from_message_loc`
    # inside `build_always_raises_diagnostic` (L1586), raises and the firing assertion below goes empty.
    it "fires flow.always-raises through the Type::Nominal[Integer] branch (a non-constant Integer receiver)" do
      diags = rule_diagnostics("rand(100) / 0\n", "flow.always-raises")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.message).to eq("always raises ZeroDivisionError: `/' by zero on Integer receiver")
      expect(diagnostic.line).to eq(1)
    end

    it "declines when the divisor is not a literal zero (adjacent to the firing case above)" do
      expect(rule_diagnostics("rand(100) / 1\n", "flow.always-raises")).to be_empty
    end
  end

  describe "dump_type / assert_type" do
    # undefined_method mutation on `Diagnostic.from_message_loc` (L1440) inside `dump_type_diagnostic` raises;
    # this pins severity, exact message and location together so no substitute location/message slips through.
    it "emits an info dump.type diagnostic, pinning the Diagnostic.from_message_loc construction" do
      source = <<~RUBY
        require "rigor/testing"
        include Rigor::Testing
        n = 4
        dump_type(n)
      RUBY
      diags = rule_diagnostics(source, "dump.type")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to eq("dump_type: 4")
      expect(diagnostic.line).to eq(4)
    end

    # Same construction call, the `build_assert_type_diagnostic` builder (L1512).
    it "emits an error assert.type-mismatch diagnostic on a mismatched assert_type" do
      source = <<~RUBY
        require "rigor/testing"
        include Rigor::Testing
        x = 1
        assert_type("String", x)
      RUBY
      diags = rule_diagnostics(source, "assert.type-mismatch")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.message).to eq('assert_type mismatch: expected "String", got "1"')
      expect(diagnostic.line).to eq(4)
    end

    it "stays silent on a matching assert_type (adjacent to the firing case above)" do
      source = <<~RUBY
        require "rigor/testing"
        include Rigor::Testing
        x = 1
        assert_type("1", x)
      RUBY
      expect(rule_diagnostics(source, "assert.type-mismatch")).to be_empty
    end
  end

  describe "visibility_mismatch" do
    # undefined_method mutation on `Diagnostic.from_message_loc` (L1860) inside `build_visibility_mismatch_diagnostic`
    # raises; unobserved by any other spec in the suite before this one.
    it "fires def.method-visibility-mismatch, pinning the Diagnostic.from_message_loc construction" do
      source = <<~RUBY
        class Box
          def open
            42
          end

          private

          def secret
            42
          end
        end

        Box.new.secret
      RUBY
      diags = rule_diagnostics(source, "def.method-visibility-mismatch")
      expect(diags.size).to eq(1)
      diagnostic = diags.first
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.message).to eq("private method `secret' called on Box receiver")
      expect(diagnostic.line).to eq(13)
    end

    it "declines on a public method call (adjacent to the firing case above)" do
      source = <<~RUBY
        class Box
          def open
            42
          end
        end

        Box.new.open
      RUBY
      expect(rule_diagnostics(source, "def.method-visibility-mismatch")).to be_empty
    end
  end

  describe "pipeline/orchestration: run_node_collectors" do
    def parse_and_index(source)
      parsed = Prism.parse(source)
      root = parsed.value
      scope = Rigor::Scope.empty(environment: Rigor::Environment.default)
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: scope)
      [root, index, parsed.comments]
    end

    # `Runner#run_source` always builds and threads `node_collectors:` (ADR-53 B4's converged walk), so it never
    # exercises the standalone branch at L193 (`RuleWalk.run(root, collectors.values)`) — every example above this
    # `describe` block goes through the converged path instead. Only a direct `CheckRules.diagnose` caller
    # (the integration `FixtureHarness`, `budget_trace_spec.rb`) reaches it. An `undefined_method` mutation on
    # `collectors.values` would raise inside `RuleWalk.run`; calling `diagnose` directly here (no per-file rescue
    # in the way, unlike a `Runner`-based caller) means that raise surfaces immediately as a spec failure instead
    # of being swallowed into an unrelated diagnostic.
    it "drives the shared RuleWalk directly via CheckRules.diagnose with no node_collectors: kwarg" do
      root, index, comments = parse_and_index("no_such_method_zzz\n")
      diagnostics = Rigor::Analysis::CheckRules.diagnose(
        path: "mem.rb", root: root, scope_index: index, comments: comments
      )
      expect(diagnostics.map(&:rule)).to include("call.unresolved-toplevel")
    end
  end
end
