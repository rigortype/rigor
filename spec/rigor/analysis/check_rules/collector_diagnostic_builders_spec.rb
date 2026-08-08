# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# First observation spec for the collector-diagnostic-builder block of `check_rules.rb` (~L1887-2077):
# `build_always_truthy_condition_diagnostic`, `build_unreachable_clause_diagnostic` (+
# `unreachable_clause_message`), `build_void_value_use_diagnostic`, `build_shadowed_rescue_diagnostic` (+
# `shadowed_rescue_message`), `build_dead_assignment_diagnostic`, `build_duplicate_hash_key_diagnostic`,
# `build_return_in_ensure_diagnostic`, `build_ivar_write_mismatch_diagnostic`, `unreachable_branch_for`, and
# `build_unreachable_branch_diagnostic`. Every one of these builders was an unexecuted mutation survivor
# (#135 checkbox 1 recon): the 7 pre-existing per-topic specs under this directory never drive any of the
# nine built-in `RuleWalk` collectors these builders serve. Organised per BUILDER (PR #289 precedent), not
# per surviving mutant — each `Diagnostic.from_node` / `from_name_loc` / `from_location` call is a distinct
# location convention, and the survivors are all `undefined_method` mutations of that one call per builder.
RSpec.describe "collector diagnostic builders" do
  def diagnostics_for(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
  end

  def rule_diagnostics(source, rule)
    diagnostics_for(source).select { |d| d.rule == rule }
  end

  describe "build_always_truthy_condition_diagnostic" do
    # `Diagnostic.from_node(predicate_node, ...)` — the squiggle lands on the PREDICATE expression itself
    # (`x`, column 4), not the enclosing `if` keyword (column 1) or the whole `if x` node. Pins the exact
    # column so an `undefined_method` mutation on this `from_node` call (which would raise instead of
    # returning a Diagnostic, since nothing downstream substitutes a location) cannot survive silently.
    it "fires on an inferred-constant truthy predicate, pointing at the predicate node" do
      source = <<~RUBY
        x = 1
        if x
          puts "yes"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.always-truthy-condition")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2)
      expect(diagnostic.column).to eq(4) # the `x` predicate, not the `if` keyword at column 1
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        "condition is always truthy (the surrounding flow proves it folds to a constant)"
      )
    end

    it "threads the falsey polarity into the message on an inferred-constant falsey predicate" do
      source = <<~RUBY
        x = nil
        unless x
          puts "no"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.always-truthy-condition")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2)
      expect(diagnostic.column).to eq(8) # the `x` predicate, after the `unless ` keyword
      expect(diagnostic.message).to start_with("condition is always falsey")
    end
  end

  describe "build_unreachable_clause_diagnostic and unreachable_clause_message" do
    # `Diagnostic.from_node(result.body, ...)` — the squiggle lands on the dead CLAUSE BODY (`puts "dead"`,
    # line 6) rather than on the `when String` clause head (line 5) or the `case` node itself. Pinning the
    # body's line, distinct from the clause head one line above, is what an `undefined_method` mutation on
    # this `from_node` call would otherwise let slip past an assertion that only checked "some diagnostic
    # fired somewhere in the case".
    it "fires with :prior_exhaustion phrasing when an earlier when-clause already exhausts the subject" do
      source = <<~RUBY
        x = 1
        case x
        when Integer
          puts "live"
        when String
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-clause")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(6) # the dead clause's body, not line 5's `when String` head
      expect(diagnostic.column).to eq(3)
      expect(diagnostic.severity).to eq(:info)
      expect(diagnostic.message).to eq(
        "unreachable `when String': `x' is already covered by an earlier `when' clause"
      )
    end

    it "fires with :disjoint phrasing when the clause's own condition can never match the subject" do
      source = <<~RUBY
        x = 1
        case x
        when String
          puts "dead"
        end
      RUBY

      messages = rule_diagnostics(source, "flow.unreachable-clause").map(&:message)
      expect(messages).to contain_exactly(
        "unreachable `when String': `x' can never be String here (the flow proves the subject disjoint)"
      )
    end

    it "fires with :exhausted_else phrasing when every when-clause already covers the subject" do
      source = <<~RUBY
        y = :sym
        case y
        when Symbol
          puts "live"
        else
          puts "dead else"
        end
      RUBY

      messages = rule_diagnostics(source, "flow.unreachable-clause").map(&:message)
      expect(messages).to contain_exactly(
        "unreachable `else': the `when' clauses already cover every value `y' can take here"
      )
    end

    it "fires on a case/in prior-exhaustion clause with the `in` keyword threaded through" do
      source = <<~RUBY
        x = 1
        case x
        in Integer
          puts "live"
        in String
          puts "dead"
        end
      RUBY

      messages = rule_diagnostics(source, "flow.unreachable-clause").map(&:message)
      expect(messages).to contain_exactly(
        "unreachable `in String': `x' is already covered by an earlier `in' clause"
      )
    end
  end

  describe "build_void_value_use_diagnostic" do
    def config(bleeding_edge:)
      settings = Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[app.rb], "signature_paths" => %w[sig], "bleeding_edge" => bleeding_edge
      )
      Rigor::Configuration.new(settings)
    end

    def void_diagnostics(rbs:, source:, bleeding_edge:)
      Dir.mktmpdir("collector-diagnostic-builders-") do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("sig")
          File.write(File.join("sig", "void_box.rbs"), rbs)
          File.write("app.rb", source)
          result = Rigor::Analysis::Runner.new(configuration: config(bleeding_edge: bleeding_edge), cache_store: nil)
                                          .run(%w[app.rb])
          result.diagnostics.select { |d| d.rule == "static.value-use.void" }
        end
      end
    end

    # `Diagnostic.from_node(result.void_node, ...)` — `void_node` is the `l.log("assign")` CallNode, so the
    # squiggle starts at the RECEIVER (`l`, column 12), not at `from_name_loc`'s method-name span (`log`,
    # which would land several columns later) — the one builder in this block where a `from_node`/
    # `from_name_loc` swap would actually move the reported column, so this pins it precisely.
    it "fires at the call node's own location (receiver start), not the message/name location" do
      diagnostics = void_diagnostics(
        rbs: <<~RBS,
          class VoidBox
            def log: (String) -> void
          end
        RBS
        source: <<~RUBY,
          l = VoidBox.new
          assigned = l.log("assign")
        RUBY
        bleeding_edge: ["use-of-void-value"]
      )

      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2)
      expect(diagnostic.column).to eq(12) # `l`, the receiver — not `log`'s column further right
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to include("VoidBox#log", "-> void")
    end
  end

  describe "build_shadowed_rescue_diagnostic and shadowed_rescue_message" do
    # `Diagnostic.from_node(result.clause, ...)` — the squiggle lands on the shadowed `rescue` CLAUSE
    # (line 6, the `rescue E` keyword), not on the class constant it names or the earlier clause it cites.
    it "fires on a single earlier-clause shadow, singular clause wording" do
      source = <<~RUBY
        module M
          class E < StandardError; end
          def self.go
            work
          rescue StandardError
          rescue E
          end
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.shadowed-rescue-clause")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(6) # the shadowed `rescue E` clause, not line 5's earlier clause
      expect(diagnostic.column).to eq(3)
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        "shadowed `rescue E': every exception class it names is already caught by the earlier " \
        "`rescue StandardError' (line 5) clause, so this clause can never run"
      )
    end

    it "joins multiple earlier clauses with 'and' and pluralises 'clauses' in the message" do
      source = <<~RUBY
        def go
          work
        rescue TypeError
        rescue ArgumentError
        rescue TypeError, ArgumentError
        end
      RUBY

      messages = rule_diagnostics(source, "flow.shadowed-rescue-clause").map(&:message)
      expect(messages).to contain_exactly(
        "shadowed `rescue TypeError, ArgumentError': every exception class it names is already caught by " \
        "the earlier `rescue TypeError' (line 3) and `rescue ArgumentError' (line 4) clauses, so this " \
        "clause can never run"
      )
    end
  end

  describe "build_dead_assignment_diagnostic" do
    # `Diagnostic.from_name_loc(write_node, ...)` — for a plain `LocalVariableWriteNode` the name span and
    # the whole-node span happen to share the same start position (`dead = 1` begins with `dead` either
    # way), so this assertion cannot distinguish `from_name_loc` from a hypothetical `from_node` swap by
    # column alone. It still fully observes the builder: an `undefined_method` mutation on the call removes
    # the diagnostic (or raises) rather than merely relocating it, and this kills that.
    it "fires on a local written in a def body but never read, naming the local and the enclosing def" do
      source = <<~RUBY
        def with_dead
          dead = 1
          live = 2
          puts live
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.dead-assignment")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2)
      expect(diagnostic.column).to eq(3)
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq("local `dead' assigned in `with_dead' but never read")
    end
  end

  describe "build_duplicate_hash_key_diagnostic" do
    # `Diagnostic.from_node(result[:key_node], ...)` — the squiggle lands on the LATER (overwriting) key
    # occurrence, column 19 (the second `a:`), not the first `a:` at column 7 whose line number is instead
    # folded into the message text.
    it "fires on the later duplicate key occurrence, citing the first occurrence's line in the message" do
      source = %(h = { a: 1, b: 2, a: 3 }\n)

      diagnostics = rule_diagnostics(source, "flow.duplicate-hash-key")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(1)
      expect(diagnostic.column).to eq(19) # the second (overwriting) `a:`, not the first at column 7
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        "duplicate hash key `:a' in the same literal; this entry overwrites the value first set at line 1"
      )
    end
  end

  describe "build_return_in_ensure_diagnostic" do
    # `Diagnostic.from_location(return_node.keyword_loc, ...)` — the one builder in this block passed an
    # explicit `Location`, not a node, to a `Diagnostic.from_*` call. An `undefined_method` mutation here
    # would raise (nothing downstream tolerates a missing location argument), so any firing example kills it;
    # the line/column pin additionally nails down that the location is the `return` keyword itself.
    it "fires on an explicit return lexically inside a def's ensure clause" do
      source = <<~RUBY
        def in_def
          compute
        ensure
          return 1
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.return-in-ensure")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(4)
      expect(diagnostic.column).to eq(3) # the `return` keyword
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        "`return' inside `ensure' discards the method's in-flight return value and swallows any " \
        "in-flight exception"
      )
    end
  end

  describe "build_ivar_write_mismatch_diagnostic" do
    # `Diagnostic.from_name_loc(node, ...)` — like the dead-assignment builder, an `InstanceVariableWriteNode`'s
    # name span and whole-node span share the same start (`@a = "two"` begins with `@a` either way), so this
    # cannot distinguish `from_name_loc` from a `from_node` swap by column alone; it still observes the
    # builder's presence, class-name/ivar-name/first-class/other-class message threading, and severity.
    it "fires on a second ivar write whose class disagrees with the first write's class" do
      source = <<~RUBY
        class Widget
          def set
            @a = 1
            @a = "two"
          end
        end
      RUBY

      diagnostics = rule_diagnostics(source, "def.ivar-write-mismatch")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(4) # the second (mismatching) write, not the first at line 3
      expect(diagnostic.column).to eq(5)
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.message).to eq(
        "instance variable `@a' on Widget was previously assigned Integer; this write assigns String"
      )
    end
  end

  describe "unreachable_branch_for" do
    # Pure dead-branch selector, only reachable (per the method's driving-through-a-public-entry preference)
    # via `unreachable_branch_diagnostic`'s firing. Each example below pins which of `IfNode#subsequent` /
    # `IfNode#statements` / `UnlessNode#statements` / `UnlessNode#else_clause` the survivor recon flagged —
    # observed here as the reported diagnostic's location, which differs branch-to-branch.
    it "selects IfNode#subsequent (the else branch) as dead when the predicate is always truthy" do
      source = <<~RUBY
        if true
          puts "live"
        else
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-branch")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(3) # the `else` clause (IfNode#subsequent), not the live then-branch
      expect(diagnostic.column).to eq(1)
      expect(diagnostic.message).to eq("unreachable branch: literal predicate is always truthy")
    end

    it "selects IfNode#statements (the then branch) as dead when the predicate is always falsey" do
      source = <<~RUBY
        if false
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-branch")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2) # the then-branch body (IfNode#statements)
      expect(diagnostic.column).to eq(3)
      expect(diagnostic.message).to eq("unreachable branch: literal predicate is always falsey")
    end

    it "selects UnlessNode#statements (the body) as dead when the predicate is always truthy" do
      source = <<~RUBY
        unless true
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-branch")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(2) # the unless body (UnlessNode#statements)
      expect(diagnostic.column).to eq(3)
      expect(diagnostic.message).to eq("unreachable branch: literal predicate is always truthy")
    end

    it "selects UnlessNode#else_clause as dead when the predicate is always falsey" do
      source = <<~RUBY
        unless false
          puts "live"
        else
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-branch")
      expect(diagnostics.size).to eq(1)
      diagnostic = diagnostics.first
      expect(diagnostic.line).to eq(3) # the `else` clause (UnlessNode#else_clause)
      expect(diagnostic.column).to eq(1)
      expect(diagnostic.message).to eq("unreachable branch: literal predicate is always falsey")
    end
  end

  describe "build_unreachable_branch_diagnostic" do
    # `Diagnostic.from_node(dead_branch, ...)` — this builder is a thin wrapper around whichever node
    # `unreachable_branch_for` selected; the case above already pins its location per dead-branch shape, so
    # this example additionally pins severity — the field the per-shape examples above do not repeat.
    it "fires at :warning severity regardless of dead-branch shape" do
      source = <<~RUBY
        if false
          puts "dead"
        end
      RUBY

      diagnostics = rule_diagnostics(source, "flow.unreachable-branch")
      expect(diagnostics.size).to eq(1)
      expect(diagnostics.first.severity).to eq(:warning)
    end
  end
end
