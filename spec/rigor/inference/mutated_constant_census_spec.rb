# frozen_string_literal: true

require "spec_helper"

# The #540 mutation census records a constant (or a class variable) that some call mutates by NAME only, and wraps the
# literal it holds as `Dynamic[literal]` whatever the call was. A read through that wrapper resolves on the static
# facet's RBS projection, so a closed `HashShape` answered its known values for any key and a `Tuple` its known
# elements for any index: `H = { a: 1 }; H.default = 0` read `H[:b]` as `1`, and `H[:b] == 0` folded always-falsey on
# code Ruby prints "zero" for. The census cannot say what the mutation stored, so the facet has to stop claiming it
# knows.
#
# Every example is paired with an unmutated twin in the same source that must keep its precise answer — without it, a
# census that stopped folding every constant would pass the mutated half too.
RSpec.describe "Mutated constant census widening", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # `[line, rule]` for the flow folds and call errors a stale read produces, lines counted in `source`; the harness's
  # own `include` / `dump_type` draw `call.unresolved-toplevel`, which says nothing about the read.
  def rules(source)
    diagnostics(source).filter_map do |diagnostic|
      rule = diagnostic.rule.to_s
      [diagnostic.line - 2, rule] if rule.start_with?("flow.", "call.") && rule != "call.unresolved-toplevel"
    end
  end

  describe "a constant Hash" do
    it "does not fold a missing key to a known value after `default=`" do
      expect(rules(<<~RUBY)).to eq([[6, "flow.always-truthy-condition"]])
        H = { a: 1 }
        H.default = 0
        puts "zero" if H[:b] == 0

        K = { a: 1 }
        puts "zero" if K[:b] == 0
      RUBY
    end

    it "does not fold a key a mutation stored" do
      expect(rules(<<~RUBY)).to eq([[10, "flow.always-truthy-condition"]])
        T = { a: 1 }
        T[:b] = 2
        puts "two" if T[:b] == 2

        U = { a: 1 }
        U.store(:b, 2)
        puts "two" if U[:b] == 2

        K = { a: 1 }
        puts "two" if K[:b] == 2
      RUBY
    end

    it "does not fold a present key a mutation rewrote" do
      expect(rules(<<~RUBY)).to eq([[7, "flow.always-truthy-condition"]])
        T = { a: 1 }
        T[:a] = 2
        puts "two" if T[:a] == 2
        puts "two" if T.fetch(:a) == 2

        K = { a: 1 }
        puts "two" if K[:a] == 2
      RUBY
    end

    # The error-level face of the same stale read: the seed's value answered a method the stored one has.
    it "does not draw an undefined-method error on a value a mutation replaced" do
      expect(rules(<<~RUBY)).to eq([[5, "call.undefined-method"]])
        T = { a: 1 }
        T[:a] = "x"
        puts T[:a].upcase
        K = { a: 1 }
        puts K[:a].upcase
      RUBY
    end

    # A class-level nominal seed makes a claim a store of the same class keeps, so the census leaves it as the
    # unknown-store seam does, and a genuine error on it still fires.
    it "keeps a class-level nominal seed's value claim, so a genuine error still fires" do
      expect(rules(<<~RUBY)).to eq([[3, "call.undefined-method"]])
        COUNTS = Hash.new(0)
        def hit(key) = COUNTS[key] += 1
        puts COUNTS[:a].upcase
      RUBY
    end

    # Issue #1238's reproduction: the store sits in the class's own `[]=`, and both reads go through its `[]`.
    it "does not fold a read through a project `[]` of a constant its `[]=` stores into" do
      expect(rules(<<~RUBY)).to eq([[24, "flow.always-truthy-condition"]])
        class Table
          DATA = { a: 1, b: 2 }
          def [](k) = DATA[k]
          def []=(k, v)
            DATA[k] = v
          end
        end

        class Counter
          def initialize(table) = @table = table
          def bump(k) = (@table[k] += 10)
        end

        t = Table.new
        Counter.new(t).bump(:a)
        x = (t[:a] += 1)
        puts "twelve" if x == 12
        puts "plain" if t[:a] == 12

        class Frozen
          DATA = { a: 1, b: 2 }
          def [](k) = DATA[k]
        end
        puts "plain" if Frozen.new[:a] == 12
      RUBY
    end

    # The census's own shape: the mutation sits in a method body, where no straight-line seam reaches the read.
    it "does not fold a key a sibling method stores" do
      expect(rules(<<~RUBY)).to eq([[12, "flow.always-truthy-condition"]])
        module Registry
          TABLE = { a: 1 }
          FROZEN = { a: 1 }

          def self.put(key, value) = TABLE[key] = value

          def self.check
            puts "two" if TABLE[:b] == 2
          end

          def self.control
            puts "two" if FROZEN[:b] == 2
          end
        end
      RUBY
    end

    it "keeps the known values beside an untyped arm, and the unmutated twin exact" do
      expect(dumped_types(<<~RUBY)).to eq(["1 | Dynamic[top]", "1 | Dynamic[top]", "nil", "1"])
        T = { a: 1 }
        T[:b] = 2
        dump_type(T[:b])
        dump_type(T[:a])

        K = { a: 1 }
        dump_type(K[:b])
        dump_type(K[:a])
      RUBY
    end
  end

  describe "a constant Array" do
    it "does not fold an element a mutation added" do
      expect(rules(<<~RUBY)).to eq([[7, "flow.always-truthy-condition"]])
        A = [1]
        A << 2
        puts "two" if A[1] == 2
        puts "two" if A.last == 2

        K = [1]
        puts "two" if K.last == 2
      RUBY
      expect(rules(<<~RUBY)).to eq([[5, "call.undefined-method"]])
        A = [1]
        A[0] = "x"
        puts A.first.upcase
        K = [1]
        puts K.first.upcase
      RUBY
    end

    # A nominal seed whose element type is value-pinned (`shuffle` answers `Array[1 | 2]`) makes the literal's claim.
    it "does not fold an element a mutation added to a value-pinned nominal seed" do
      expect(rules(<<~RUBY)).to eq([[6, "flow.always-truthy-condition"]])
        P = [1, 2].shuffle
        P << 3
        puts "three" if P.last == 3

        K = [1, 2].shuffle
        puts "three" if K.last == 3
      RUBY
    end

    it "keeps a class-level nominal seed's element claim, so a genuine error still fires" do
      expect(rules(<<~RUBY)).to eq([[3, "call.undefined-method"]])
        NAMES = ENV.fetch("NAMES", "").split(",")
        def add(name) = NAMES << name
        puts NAMES.last.lenght
      RUBY
    end

    it "keeps the known elements beside an untyped arm, and the unmutated twin exact" do
      expect(dumped_types(<<~RUBY)).to eq(["1 | Dynamic[top]", "1"])
        A = [1]
        A << 2
        dump_type(A.last)

        K = [1]
        dump_type(K.last)
      RUBY
    end
  end

  # `build_class_cvar_index` records the writes a `def` body makes, so the seed is written in one.
  describe "a class variable" do
    it "does not fold a missing key after a sibling method sets a default or stores" do
      expect(rules(<<~RUBY)).to eq([[23, "flow.always-truthy-condition"]])
        class Defaulted
          def init = (@@h = { a: 1 })
          def mutate = @@h.default = 0

          def check
            puts "zero" if @@h[:b] == 0
          end
        end

        class Stored
          def init = (@@t = { a: 1 })
          def mutate = @@t[:b] = 2

          def check
            puts "two" if @@t[:b] == 2
          end
        end

        class Kept
          def init = (@@k = { a: 1 })

          def check
            puts "two" if @@k[:b] == 2
          end
        end
      RUBY
    end
  end
end
