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
  # A tuple element a mutation reached, floored as a mutated constant is.
  def wide = "Dynamic[Array[Dynamic[top]]]"

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

    # Issue #1297 — the floor: the literal's known values are not kept beside the arm (the projection is not keyed, so
    # they answered every key's), while the unmutated twin keeps its exact per-key answers.
    it "floors every read to untyped, and keeps the unmutated twin exact" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]", "nil", "1"])
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

    it "floors every read to untyped, and keeps the unmutated twin exact" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "1"])
        A = [1]
        A << 2
        dump_type(A.last)

        K = [1]
        dump_type(K.last)
      RUBY
    end
  end

  # Issue #1297 — a read of a mutated constant answered the literal's known values beside the `Dynamic[top]` arm, and
  # the projection is not keyed, so `STATUS[:name]` answered `:active`'s `false` too. A method declared `-> String`
  # returning it drew `def.return-type-mismatch` although `set` can store anything under either key. The census floors
  # the literal to its gradual nominal instead, as ADR-58's ivar census does.
  describe "a declared return of a mutated constant's read" do
    def return_mismatches(source, sig)
      analyze(source, sig: { "st.rbs" => sig }).diagnostics.filter_map do |diagnostic|
        next unless diagnostic.rule.to_s == "def.return-type-mismatch"

        [diagnostic.line, diagnostic.message.delete_prefix("return-type mismatch on ")]
      end
    end

    it "does not report a read of a hash a sibling method stores into, and still reports the unmutated twin" do
      expect(return_mismatches(<<~RUBY, <<~RBS)).to eq([[12, "`kname': declared String, inferred nil"]])
        module St
          STATUS = { active: false, name: nil }
          KSTATUS = { name: nil }

          def self.set(v)
            STATUS[:active] = v
            STATUS[:name] = "x"
          end

          def self.active? = STATUS[:active]
          def self.name = STATUS[:name]
          def self.kname = KSTATUS[:name]
        end
      RUBY
        module St
          def self.active?: () -> bool
          def self.set: (bool) -> void
          def self.name: () -> String
          def self.kname: () -> String
        end
      RBS
    end

    it "does not report a read of a hash a `merge!` rewrote, and still reports the unmutated twin" do
      expect(return_mismatches(<<~RUBY, <<~RBS)).to eq([[10, "`kport': declared String, inferred 30"]])
        module Conf
          DEFAULTS = { host: "localhost", port: 30 }
          KDEFAULTS = { host: "localhost", port: 30 }

          def self.configure(opts)
            DEFAULTS.merge!(opts)
          end

          def self.host = DEFAULTS[:host]
          def self.kport = KDEFAULTS[:port]
        end
      RUBY
        module Conf
          def self.configure: (Hash[Symbol, untyped]) -> void
          def self.host: () -> String
          def self.kport: () -> String
        end
      RBS
    end

    it "does not report a read of an array a sibling method appends to, and still reports the unmutated twin" do
      expect(return_mismatches(<<~RUBY, <<~RBS)).to eq([[8, "`kfirst': declared String, inferred 1"]])
        module Seq
          ITEMS = [1]
          KITEMS = [1]

          def self.add(v) = ITEMS << v

          def self.first = ITEMS[0]
          def self.kfirst = KITEMS[0]
        end
      RUBY
        module Seq
          def self.add: (String) -> void
          def self.first: () -> String
          def self.kfirst: () -> String
        end
      RBS
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

  # Issue #3243 — a method that mutates an ELEMENT read off a constant (`S[0] << "b"`) mutates no name the census saw:
  # the receiver of `<<` is the read `S[0]`, so `S[0] == "a"` folded always-truthy on a program that stores `"ab"`
  # there. The census records the read's root and steps and widens only the element they reach, so the outer tuple's
  # arity and every untouched slot keep their pins.
  describe "an element of a constant" do
    it "does not fold the issue's reproduction" do
      expect(rules(<<~RUBY)).to eq([])
        S = [+"a"].freeze
        NESTED = [[1]].freeze

        def grow
          S[0] << "b"
          NESTED[0] << 2
        end

        grow
        puts "same" if S[0] == "a"
        puts "same" if NESTED[0].last == 1
      RUBY
    end

    it "keeps the outer arity, an untouched sibling slot and an unmutated twin" do
      expected = [[4, "flow.always-truthy-condition"], [5, "call.undefined-method"],
                  [7, "flow.always-truthy-condition"]]
      expect(rules(<<~RUBY).sort).to eq(expected)
        PAIR = [+"a", 1].freeze
        KEPT = [+"a"].freeze
        def grow = PAIR[0] << "b"
        puts "two" if PAIR.size == 2
        PAIR[1].upcase
        puts "same" if PAIR[0] == "a"
        puts "same" if KEPT[0] == "a"
      RUBY
    end

    it "does not fold an element a straight-line top-level mutation changed" do
      expect(rules(<<~RUBY)).to eq([[5, "flow.always-truthy-condition"]])
        S = [+"a"].freeze
        S[0] << "b"
        puts "same" if S[0] == "a"
        K = [+"a"].freeze
        puts "same" if K[0] == "a"
      RUBY
    end

    it "widens the slot a position, `first`, `last` or a nested read reaches, and only that slot" do
      expected = ["[#{wide}, [2]]", "[[1], #{wide}]", "[[1], #{wide}]", "[[#{wide}], [2]]", "[[1], [2]]",
                  "[[1]] | [[2], #{wide}]"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        A = [[1], [2]].freeze
        B = [[1], [2]].freeze
        C = [[1], [2]].freeze
        D = [[[1]], [2]].freeze
        L = [[1], [2]].freeze
        V = ENV["X"] ? [[1]] : [[2], [3]]
        def grow
          A.first << 3
          B.last << 3
          C[-1] << 3
          D[0][0] << 3
          L[5] << 3
          V[1] << 3
        end
        dump_type(A); dump_type(B); dump_type(C); dump_type(D); dump_type(L); dump_type(V)
      RUBY
    end

    it "widens the slot `dig`, `at`, `fetch`, a safe-navigated or parenthesised read or an unknown index reaches" do
      expected = ["[[1], [#{wide}]]", "[#{wide}, [2]]", "[#{wide}, [2]]", "[[1], #{wide}]", "[#{wide}, [2]]",
                  "[#{wide}, [2]]", "[#{wide}, #{wide}]"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        E = [[1], [[2]]].freeze
        F = [[1], [2]].freeze
        G = [[1], [2]].freeze
        GB = [[1], [2]].freeze
        J = [[1], [2]].freeze
        P = [[1], [2]].freeze
        I = [[1], [2]].freeze
        def grow(i)
          E.dig(1, 0) << 3
          F.at(0) << 3
          G.fetch(0, []) << 3
          GB.fetch(1) { [] } << 3
          J&.[](0)&.<<(3)
          (P[0]) << 3
          I[i] << 3
        end
        dump_type(E); dump_type(F); dump_type(G); dump_type(GB); dump_type(J); dump_type(P); dump_type(I)
      RUBY
    end

    it "widens the element an index write, an operator write, a String mutator or a writer reaches" do
      expected = ["[#{wide}]", "[#{wide}]", "[#{wide}]", "[Dynamic[String]]",
                  "{ a: Dynamic[Hash[Dynamic[top], Dynamic[top]]] }"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        W1 = [[1]].freeze
        W2 = [[1]].freeze
        W3 = [[nil]].freeze
        S = [+"a"].freeze
        HD = { a: {} }.freeze
        def grow
          W1[0][0] = 2
          W2[0][0] += 1
          W3[0][0] ||= 2
          S[0].sub!("a", "b")
          HD[:a].default = 0
        end
        dump_type(W1); dump_type(W2); dump_type(W3); dump_type(S); dump_type(HD)
      RUBY
    end

    # A `HashShape` step names a key: a Symbol, a String or an Integer one. `first` reads a fresh `[key, value]` pair,
    # so only a read through the pair's value (`[1]`) reaches the shape, and it reaches every value.
    it "widens the value a key reaches, and keeps every sibling key exact" do
      expected = [
        '{ a: Dynamic[String], b: "y" }', '{ "a" => Dynamic[String], "b" => "y" }',
        '{ 1 => Dynamic[String], 2 => "y" }', "{ a: #{wide}, b: [2] }", "{ a: #{wide}, b: #{wide} }",
        "{ a: [1] }"
      ]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        H = { a: +"x", b: +"y" }.freeze
        HS = { "a" => +"x", "b" => +"y" }.freeze
        HI = { 1 => +"x", 2 => +"y" }.freeze
        HF = { a: [1], b: [2] }.freeze
        HP = { a: [1], b: [2] }.freeze
        HN = { a: [1] }.freeze
        def grow
          H[:a] << "z"
          HS["a"] << "z"
          HI[1] << "z"
          HF.fetch(:a) << 2
          HP.first[1] << 2
          HN.first << 2
        end
        dump_type(H); dump_type(HS); dump_type(HI); dump_type(HF); dump_type(HP); dump_type(HN)
      RUBY
    end

    # The candidates are the ones a whole-name mutation takes: every lexical rung, #708's rooted header keeping the
    # enclosing one, and for a rooted path (#703) the top-level constant alone.
    it "resolves a namespaced and a rooted-header root through every lexical rung" do
      expect(dumped_types(<<~RUBY)).to eq(["[#{wide}]", "[[1]]", "[#{wide}]"])
        module Admin
          T = [[1]].freeze
          U = [[1]].freeze
          def self.grow = T[0] << 2
        end
        module Outer
          T = [[1]].freeze
          class ::Rooted
            def self.grow = T[0] << 2
          end
        end
        dump_type(Admin::T); dump_type(Admin::U); dump_type(Outer::T)
      RUBY
    end

    it "resolves a rooted-path root to the top-level constant alone" do
      expect(dumped_types(<<~RUBY)).to eq(["[[1]]", "[#{wide}]"])
        module Admin
          module Table
            ROWS = [[1]].freeze
          end
          def self.fill = ::Table::ROWS[0] << 2
        end
        module Table
          ROWS = [[1]].freeze
        end
        dump_type(Admin::Table::ROWS); dump_type(Table::ROWS)
      RUBY
    end

    it "widens the element of a class variable, and keeps an unmutated twin" do
      expect(dumped_types(<<~RUBY)).to eq(["[#{wide}]", "[Dynamic[String]]", "[[1]]"])
        class Cv
          def init = (@@n = [[1]].freeze) && (@@s = [+"a"].freeze) && (@@k = [[1]].freeze)

          def grow
            @@n[0] << 2
            @@s[0] << "b"
          end

          def check
            dump_type(@@n); dump_type(@@s); dump_type(@@k)
          end
        end
      RUBY
    end

    it "hands an instance variable bound to the constant the widened element" do
      expect(dumped_types(<<~RUBY)).to eq(["[#{wide}]", "[[1]]"])
        NESTED = [[1]].freeze
        KEPT = [[1]].freeze
        class Holder
          def initialize
            @n = NESTED
            @k = KEPT
          end

          def check
            dump_type(@n); dump_type(@k)
          end
        end
        def grow = NESTED[0] << 2
      RUBY
    end

    # A nominal names no position, so a mutation through any of its elements, or of the nominal itself, unpins the
    # literal its type argument holds.
    it "unpins the literal an Array nominal's element type holds" do
      expect(rules(<<~RUBY)).to eq([[10, "flow.always-truthy-condition"]])
        SHUF = [[1]].shuffle
        GROWN = [[1]].shuffle
        KEPT = [[1]].shuffle
        def grow
          SHUF[0] << 2
          GROWN << [2]
        end
        puts "one" if SHUF[0].last == 1
        puts "one" if GROWN[0].last == 1
        puts "one" if KEPT[0].last == 1
      RUBY
    end

    it "reaches the same table whichever order a whole-name and an element mutation, or two depths, appear in" do
      expect(dumped_types(<<~RUBY)).to eq([wide, wide, "[#{wide}]", "[#{wide}]"])
        C1 = [[1]].freeze
        C2 = [[1]].freeze
        D1 = [[[1]]].freeze
        D2 = [[[1]]].freeze
        def grow
          C1 << [2]
          C1[0] << 3
          C2[0] << 3
          C2 << [2]
          D1[0] << [3]
          D1[0][0] << 2
          D2[0][0] << 2
          D2[0] << [3]
        end
        dump_type(C1); dump_type(C2); dump_type(D1); dump_type(D2)
      RUBY
    end

    # `Integer#<<` shifts, and the non-mutating reads and self-returners change nothing, so each keeps its pin.
    it "keeps the pin of an element a read, a self-returner or an Integer shift leaves unchanged" do
      expect(dumped_types(<<~RUBY)).to eq(['["a"]', "[[1]]", "[[1]]", "[1, 2]"])
        S = [+"a"].freeze
        N = [[1]].freeze
        FZ = [[1]].freeze
        INTS = [1, 2].freeze
        def look
          S[0].upcase
          N[0].last
          FZ[0].freeze
          FZ[0].dup
          INTS[0] << 3
        end
        dump_type(S); dump_type(N); dump_type(FZ); dump_type(INTS)
      RUBY
    end
  end
end
