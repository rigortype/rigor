# frozen_string_literal: true

# Issue #2296 — a callee that mutates its parameter inside a block of its body (`def poke(acc) = 2.times { |i| acc[i]
# = "x" }`) left the caller's argument at its literal shape, so `acc = [7, 9]; poke(acc); acc[0].upcase` reported
# `undefined method 'upcase' for 7` on code Ruby runs to `"X"` (`XXH3#hash_long`, the instance behind #2104). The floor
# now counts that channel and keeps the element type beside the gradual arm (`Array[Dynamic[top] | Integer]`), not the
# bare carrier the escaping-block census answers. A Set argument grown through a Set-only adder (`add`, `merge`) is
# floored the same way, and only a Set: `Hash#merge` returns a new Hash.
#
# Ruby witnesses (`ruby -e '...'`, Ruby 4.0): the `poke` row prints `"X"`; `local_only` leaves `acc[0] + 1` at `8`; an
# uncalled stored lambda leaves it at `8`; `s = Set[1]; addit(s)` holds `[1, "a"]`; `h = { a: 1 }` under a block's
# `h.merge(b: 2)` is unchanged.
require "spec_helper"

RSpec.describe "a callee's block mutation floors the caller's argument (#2296)", type: :runner do
  def dumped(defs, source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{defs}\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def errors(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map(&:qualified_rule)
  end

  it "reports nothing on the issue's snippet" do
    expect(errors(<<~RUBY)).to eq([])
      def run
        acc = [7, 9]
        poke(acc)
        acc[0].upcase
      end

      def poke(acc) = 2.times { |i| acc[i] = "x" }
    RUBY
  end

  describe "the widened argument keeps its element type" do
    {
      "an Integer#times block" => ["def poke(acc) = 2.times { |i| acc[i] = \"x\" }",
                                   "acc = [7, 9]\npoke(acc)", "Array[Dynamic[top] | Integer]"],
      "a nested block" => ["def poke(acc) = [1].each { 2.times { |i| acc[i] = \"x\" } }",
                           "acc = [7, 9]\npoke(acc)", "Array[Dynamic[top] | Integer]"],
      "an each_with_index block" => ["def poke(acc) = acc.each_with_index { |_, i| acc[i] = \"x\" }",
                                     "acc = [7, 9]\npoke(acc)", "Array[Dynamic[top] | Integer]"],
      "a Hash index write" => ["def poke(h) = [1].each { |k| h[k] = \"s\" }",
                               "acc = { a: 1 }\npoke(acc)", "Hash[Dynamic[top] | Symbol, Dynamic[top] | Integer]"],
      "a value-pinned Hash nominal" => ["def poke(h) = [1].each { |k| h[\"k\"] = k }",
                                        "acc = {}\n%w[a b].each { |n| acc[n] = n.size }\npoke(acc)",
                                        "Hash[\"a\" | \"b\" | Dynamic[top], 1 | Dynamic[top]]"],
      "a nilable Array" => ["def poke(acc) = 2.times { |i| acc[i] = \"x\" if acc }",
                            "acc = ARGV.empty? ? [7, 9] : nil\npoke(acc)", "Array[Dynamic[top] | Integer]?"],
      "a String append" => ["def poke(s) = [1].each { s << \"c\" }", "acc = +\"ab\"\npoke(acc)", "String"],
      "a Set append" => ["def poke(s) = [1].each { s << \"c\" }", "acc = Set[1]\npoke(acc)",
                         "Set[Dynamic[top] | Integer]"]
    }.each do |label, (defs, source, expected)|
      it "floors through #{label}" do
        expect(dumped(defs, "#{source}\ndump_type(acc)")).to eq([expected])
      end
    end
  end

  describe "a callee that does not mutate the argument in a block" do
    # Guard: no line of the change names the copy; it pins that the census reads the parameter, not any local.
    it "keeps the literal when the block mutates only a block-local copy" do
      defs = "def local_only(acc) = 2.times { |i| t = [acc[i]]; t[0] = \"x\" }"
      expect(dumped(defs, "acc = [7, 9]\nlocal_only(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    it "keeps the literal when a block parameter shadows the parameter" do
      defs = "def shadow(acc) = [1].each { |acc| acc << \"x\" }"
      expect(dumped(defs, "acc = [7, 9]\nshadow(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    # Guard: a lambda body is not run by the call, and this channel does not enter it; the existing handling of a
    # stored lambda is unchanged.
    it "keeps the literal when the mutation is in a stored, uncalled lambda" do
      defs = "def stash(acc) = (@blk = -> { acc[0] = \"x\" })"
      expect(dumped(defs, "acc = [7, 9]\nstash(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    # Guard against the #2295 regression: the bare-carrier floor read this `Hash[untyped, untyped]`, which is what
    # moved sig-gen's `ScopeIndexer.finalize_constant_writes`.
    it "leaves a class-level nominal alone (the finalize_constant_writes shape)" do
      defs = "def fill(sources) = [1].each { |k| sources[\"k\#{k}\"] = \"v\".chars.to_set }"
      source = "acc = {}\nARGV.each { |n| acc[n] = n.chars.to_set }\nfill(acc)\ndump_type(acc)"
      expect(dumped(defs, source)).to eq(["Hash[String, Set[String]]"])
    end
  end

  describe "a Set-only adder" do
    {
      "add in a block" => "def grow(s) = [1].each { s.add(\"a\") }",
      "add in the body" => "def grow(s) = s.add(\"a\")",
      "merge in a block" => "def grow(s) = [1].each { s.merge([\"a\"]) }"
    }.each do |label, defs|
      it "floors a Set argument through #{label}" do
        expect(dumped(defs, "acc = Set[1]\ngrow(acc)\ndump_type(acc)")).to eq(["Set[Dynamic[top] | Integer]"])
      end
    end

    it "does not floor a Set argument when a block parameter shadows the parameter" do
      defs = "def grow(s) = [Set[]].each { |s| s.add(\"a\") }"
      expect(dumped(defs, "acc = Set[1]\ngrow(acc)\ndump_type(acc)")).to eq(["Set[1]"])
    end

    # Guard: fails if the Set-only names join the block census, whose floor would widen the Hash.
    it "does not floor a Hash argument through a non-mutating Hash#merge" do
      defs = "def nomerge(h) = [1].each { h.merge(b: 2) }"
      expect(dumped(defs, "acc = { a: 1 }\nnomerge(acc)\ndump_type(acc)")).to eq(["{ a: 1 }"])
    end

    it "reports nothing on a String use of the grown Set's element" do
      expect(errors(<<~RUBY)).to eq([])
        def addit(s) = [1].each { s.add("a") }
        s = Set[1]
        addit(s)
        s.to_a.last.upcase
      RUBY
    end
  end

  describe "a callee that rebinds the parameter first" do
    {
      "in a block" => "acc = acc.dup\n  acc.each_index { |i| acc[i] = 0 }",
      "in the method body" => "acc = acc.dup\n  acc[0] = 0",
      "in an endless def" => nil,
      "in an escaping block" => "acc = acc.dup\n  @hook = proc { acc[0] = 0 }"
    }.each do |label, body|
      it "leaves the caller's literal when the copy is mutated #{label}" do
        defs = body ? "def copy(acc)\n  #{body}\n  acc\nend" : "def copy(acc) = (acc = acc.dup; acc[0] = 0; acc)"
        expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
      end
    end

    it "leaves the caller's literal when the rebind is a fresh copier on the parameter" do
      defs = "def copy(acc)\n  acc = acc.map { |v| v }\n  acc[0] = \"x\"\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    it "leaves the caller's literal when the rebind is an operator write that builds a new Array" do
      defs = "def copy(acc)\n  acc += [1]\n  acc[0] = \"x\"\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    # A rebind to a value that may be the same object (`to_a`, `to_s`, a project `X.new`) is no rebind, and a
    # `rescue` / `ensure` clause runs with whichever binding the raise left, so each of these mutates the caller's
    # object.
    {
      "a self-returning to_a" => "def via_to_a(acc)\n  acc = acc.to_a\n  acc[0] = \"x\"\nend\n" \
                                 "acc = [7, 9]\nvia_to_a(acc)",
      "a rescue clause" => "def may_raise! = nil\ndef resc_flat(acc)\n  may_raise!\n  acc = acc.dup\n  acc[0] = 0\n" \
                           "rescue StandardError\n  acc[0] = \"x\"\nend\nacc = [7, 9]\nresc_flat(acc)",
      "an ensure clause" => "def ens_flat(acc)\n  acc = acc.dup\n  acc[0] = 0\nensure\n  acc[0] = \"x\"\nend\n" \
                            "acc = [7, 9]\nens_flat(acc)",
      # A project class's `new` is no fresh rebind: it may wrap its argument and write through it, or hand it back.
      "a wrapping project constructor" =>
        "class Wrap\n  def initialize(items) = @items = items\n  def []=(i, v)\n    @items[i] = v\n  end\nend\n" \
        "def fill_flat(acc)\n  acc = Wrap.new(acc)\n  acc[0] = \"x\"\nend\nacc = [7, 9]\nfill_flat(acc)",
      "a project constructor returning its argument" =>
        "class Ident\n  def self.new(items) = items\nend\n" \
        "def fill_ident(acc)\n  acc = Ident.new(acc)\n  acc[0] = \"x\"\nend\nacc = [7, 9]\nfill_ident(acc)"
    }.each do |label, source|
      it "reports nothing on the caller's String use after #{label}" do
        expect(errors("#{source}\nacc[0].upcase")).to eq([])
      end
    end

    it "leaves the caller's literal when the rebind is a rooted ::Array.new" do
      defs = "def copy(acc)\n  acc = ::Array.new(acc.size, 0)\n  acc[0] = 1\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["[7, 9]"])
    end

    # A bare `Array` may name a namespace's own class, which the AST-only census cannot rule out.
    it "floors the caller's argument after a bare Array.new rebind" do
      defs = "def copy(acc)\n  acc = Array.new(acc.size, 0)\n  acc[0] = 1\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["Array[Dynamic[top]]"])
    end

    it "reports nothing when a namespace's own Array wraps the argument" do
      expect(errors(<<~RUBY)).to eq([])
        module M
          class Array
            def initialize(items) = @items = items

            def []=(i, v)
              @items[i] = v
            end
          end

          class C
            def fill(acc)
              acc = Array.new(acc)
              acc[0] = "x"
            end

            def t4
              acc = [7, 9]
              fill(acc)
              acc[0].upcase
            end
          end
        end
      RUBY
    end

    it "floors the caller's argument when the copier is called on another local" do
      defs = "def copy(acc, other)\n  acc = other.map { |v| v }\n  acc[0] = \"x\"\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc, [1])\ndump_type(acc)")).to eq(["Array[Dynamic[top]]"])
    end

    it "floors the caller's argument after an operator write other than + and -" do
      defs = "def copy(acc)\n  acc *= 1\n  acc[0] = \"x\"\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["Array[Dynamic[top]]"])
    end

    it "floors the caller's String after a self-returning to_s" do
      defs = "def via_str(s)\n  s = s.to_s\n  s << \"!\"\nend"
      expect(dumped(defs, "acc = +\"ab\"\nvia_str(acc)\ndump_type(acc)")).to eq(["String"])
    end

    it "still floors the caller's argument when the mutation runs before the rebind" do
      defs = "def copy(acc)\n  acc[0] = 0\n  acc = acc.dup\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["Array[Dynamic[top]]"])
    end

    it "still floors the caller's argument when the rebind is conditional" do
      defs = "def copy(acc)\n  acc = acc.dup if acc.frozen?\n  acc[0] = 0\nend"
      expect(dumped(defs, "acc = [7, 9]\ncopy(acc)\ndump_type(acc)")).to eq(["Array[Dynamic[top]]"])
    end
  end

  # `def.return-type-mismatch` against a declared tuple: a floored Array's unknown length and gradual elements cannot
  # prove the tuple wrong, but a known element no tuple slot overlaps still can.
  describe "a floored argument returned against a declared tuple" do
    def mismatches(body, rbs)
      result = analyze(<<~RUBY, sig: { "p.rbs" => "class P\n  def norm: (untyped) -> untyped\n  #{rbs}\nend\n" })
        class P
          def norm(acc) = acc.each_index { |i| acc[i] = acc[i].abs }

        #{body.gsub(/^/, '  ')}
        end
      RUBY
      result.diagnostics.select { |d| d.rule == "def.return-type-mismatch" }.map(&:message)
    end

    let(:floored) { "def pair\n  acc = [-7, 9]\n  norm(acc)\n  acc\nend" }

    it "is silent when every known element overlaps a tuple slot" do
      expect(mismatches(floored, "def pair: () -> [Integer, Integer]")).to eq([])
    end

    it "reports when a known element overlaps no tuple slot" do
      expect(mismatches(floored, "def pair: () -> [String, String]")).to eq(
        ["return-type mismatch on `pair': declared [String, String], inferred Array[Dynamic[top] | Integer]"]
      )
    end

    it "keeps reporting an Array with no gradual element" do
      expect(mismatches("def pair(xs) = xs.map(&:to_i)", "def pair: (Array[String]) -> [Integer, Integer]")).to eq(
        ["return-type mismatch on `pair': declared [Integer, Integer], inferred Array[Integer]"]
      )
    end

    it "is silent when the callee mutates only its own copy" do
      body = "def copy(acc)\n  acc = acc.dup\n  acc.each_index { |i| acc[i] = 0 }\n  acc\nend\n" \
             "def pair\n  acc = [1, 2]\n  copy(acc)\n  acc\nend"
      expect(mismatches(body, "def copy: (untyped) -> untyped\n  def pair: () -> [Integer, Integer]")).to eq([])
    end
  end

  # The incremental session re-checks a callee's dependents when this surface moves, so a block or Set-only mutation
  # has to be on it.
  it "lists a parameter mutated in a block or through a Set-only adder on the effects surface" do
    def_node = Prism.parse(<<~RUBY).value.statements.body.first
      def fill(a, b, s, h)
        2.times { |i| a[i] = 1 }
        s.add(1)
        [1].each { |b| b << 1 }
        h.size
      end
    RUBY
    evaluator = Rigor::Inference::StatementEvaluator.new(scope: Rigor::Scope.empty)
    expect(evaluator.content_mutated_parameter_positions(def_node)).to eq([0, 2])
  end

  # The XXH3#hash_long shape: a frozen literal's dup handed down a chain whose last callee mutates in a block, from
  # a call in the caller's own block and from one at the top of its body.
  it "reports nothing on the XXH3#hash_long shape" do
    expect(errors(<<~RUBY)).to eq([])
      class X
        ACC_NB = 2
        INIT_ACC = [7, 9].freeze

        def hash_long(nb)
          acc = INIT_ACC.dup
          nb.times { |n| stripes(acc, n) }
          acc[0].upcase
        end

        def tail(nb)
          acc = INIT_ACC.dup
          stripes(acc, nb)
          acc[0].upcase
        end

        def stripes(acc, nb) = nb.times { |s| accumulate_512(acc, s) }

        def accumulate_512(acc, off)
          ACC_NB.times { |i| acc[i] = "x\#{off}" }
        end
      end
    RUBY
  end
end
