# frozen_string_literal: true

require "spec_helper"

# A variable `&&=` stores its rvalue only when the target already holds a truthy value; on a falsey or unset target
# it returns that value without evaluating the rvalue. An UNBOUND target, one nothing the analyzer saw writes, is
# therefore no memo: an unset `@x &&= v` is `nil` at runtime, and whatever set it where the analyzer did not look
# decides the rest. Its value is `union(narrow_falsey(Dynamic[top]), rhs)`, the statement evaluator's reading of
# any unbound target. Read as the rvalue, `if (@x &&= 1)` folded always-truthy on a program that takes the else
# arm, and `@x &&= raise("b")` typed `bot` where the statement form read `Dynamic[top]`.
#
# Every unbound example is paired with a control that must keep its answer: a bound `&&=`, a condition over a bound
# truthy target, and the memoizing `||=`.
RSpec.describe "variable `&&=` value", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def flow_rules(source)
    analyze(source).diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  describe "an unbound target" do
    it "reads the unseen binding beside the rvalue, for every variable kind" do
      # Runtime: `nil` for the ivar, global and local; NameError for the class variable.
      expect(dumped_types(<<~RUBY)).to eq(["1 | Dynamic[top]"] * 4)
        class App
          def token = dump_type(@token &&= 1)
          def registry = dump_type(@@registry &&= 1)
          def logger = dump_type($app_logger &&= 1)
          def local = dump_type(conf &&= 1)
        end
      RUBY
    end

    it "reads a raising rvalue as the unseen binding, not bot" do
      # Runtime: `nil`; the `raise` runs only once something the analyzer did not see stored a truthy value.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"] * 2)
        class App
          def self.token = dump_type(@token &&= raise("b"))
          def logger = dump_type($app_logger &&= raise("b"))
        end
      RUBY
    end

    it "gives the statement form the same answer as the expression form" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]"])
        class App
          def self.token
            t = (@token &&= raise("b"))
            dump_type(t)
          end

          def self.other = dump_type(@other &&= raise("b"))
        end
      RUBY
    end

    it "does not fold a condition over the write" do
      # Runtime: every method returns `:no`.
      expect(flow_rules(<<~RUBY)).to be_empty
        class App
          def token
            if (@token &&= 1) then :yes else :no end
          end

          def logger
            if ($app_logger &&= 1) then :yes else :no end
          end

          def local
            if (conf &&= 1) then :yes else :no end
          end

          def registry
            if (@@registry &&= 1) then :yes else :no end
          end
        end
      RUBY
    end
  end

  describe "controls" do
    it "keeps a bound target's `&&=` as the value it stores" do
      # Runtime: `"refreshed"`, `1` and `2`.
      expect(dumped_types(<<~RUBY)).to eq([%("refreshed"), "1?", "2"])
        class App
          def initialize = (@token = "init")
          def refresh = dump_type(@token &&= "refreshed")

          def unset
            conf = nil
            dump_type(conf &&= 1)
          end

          def set
            conf = { a: 1 }
            dump_type(conf &&= 2)
          end
        end
      RUBY
    end

    it "keeps the `&&=` contribution to the class seed when the seeding write comes later" do
      # Runtime: `"init"` or `"refreshed"`, whichever method ran last.
      expect(dumped_types(<<~RUBY)).to eq([%("refreshed"), %("init" | "refreshed")])
        class App
          def refresh = dump_type(@token &&= "refreshed")
          def initialize = (@token = "init")
          def peek = dump_type(@token)
        end
      RUBY
    end

    it "keeps a later `+=` dispatching on the value an `&&=` stores" do
      # Runtime: prints, since `shrink` then `grow` leaves `@x` at `2.5`.
      expect(flow_rules(<<~RUBY)).to be_empty
        class Scale
          def initialize = (@x = 1)
          def shrink = (@x &&= 1.5)
          def grow = (@x += 1)

          def check
            x = @x
            puts "two and a half" if x.is_a?(Float) && x == 2.5
          end
        end
      RUBY
    end

    it "still folds a condition over a bound truthy target" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        class App
          def run
            @count = 1
            if (@count &&= 2) then :yes else :no end
          end
        end
      RUBY
    end

    it "keeps the memoizing `||=` on the rvalue" do
      expect(dumped_types(<<~RUBY)).to eq(["App"])
        class App
          def self.default = dump_type(@default ||= new)
        end
      RUBY
    end
  end
end
