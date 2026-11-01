# frozen_string_literal: true

require "spec_helper"

# A mutator whose ARGUMENTS do not describe what it stores — `map!`, `collect!`, a block-form `fill`, `flatten!`,
# `transform_values!`, `transform_keys!`, `merge!` / `update`, `Hash#replace` — rewrites the parameter it stores
# into with values nothing typed. The straight-line seam used to widen the literal shape and keep the seed's element
# types, so `a = [1]; a.map!(&:to_s)` read `Array[Integer]` and `a.first.upcase` drew a false
# `call.undefined-method`; an empty-witness refinement (`if ys.any?; ys.map!(&:to_sym)`) declined outright and kept
# `non-empty-array[String]`.
#
# Every "does not fire" example is paired with a value-preserving control (`sort!`, `reverse!`, `compact!`) in the
# same position that must still fire — without it, a seam that stopped typing the receiver at all would pass too.
RSpec.describe "unknown-store mutator widening", type: :runner do
  def diagnostics(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix, sig: {})
    diagnostics(source, sig: sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix)
    end
  end

  def undefined_method_rules(source) = rules(source, "call.undefined-method")

  describe "the straight-line seam on a literal Array" do
    it "replaces `map!`'s rewritten element with the gradual type" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
        a = [1]
        a.map!(&:to_s)
        dump_type(a)
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        a = [1]
        a.map!(&:to_s)
        a.first.upcase
      RUBY
    end

    it "does not fold a comparison against the rewritten element, and still folds one after `sort!`" do
      expect(rules(<<~RUBY, "flow.")).to be_empty
        a = [1]
        a.map!(&:succ)
        puts "two" if a[0] == 2
      RUBY
      expect(rules(<<~RUBY, "flow.")).to eq(["flow.always-truthy-condition"]) # the rule id names both polarities
        a = [1]
        a.sort!
        puts "two" if a[0] == 2
      RUBY
    end

    it "keeps the seed's element under a value-preserving mutator in the same position" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        a = [1]
        a.sort!
        a.first.upcase
      RUBY
    end

    it "treats `collect!` and a block-form `fill` the same way" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        c = [1]
        c.collect! { |x| x.to_s }
        c.first.upcase

        b = [1, 2]
        b.fill { |i| i.to_s }
        b.first.upcase
      RUBY
    end

    # A union of tuples dispatches quietly, so this pair compares the carriers rather than a diagnostic.
    it "replaces `flatten!`'s element, and keeps `reverse!`'s" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Array[[1] | [2]]"])
        f = [[1], [2]]
        f.flatten!
        dump_type(f)

        g = [[1], [2]]
        g.reverse!
        dump_type(g)
      RUBY
    end

    it "widens an instance variable the same way" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        class Rewriter
          def run
            @a = [1]
            @a.map!(&:to_s)
            @a.first.upcase
          end
        end
      RUBY
    end
  end

  describe "the straight-line seam on an empty-witness refinement" do
    it "gives the refinement's rewritten element the gradual arm" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        ys = gets.to_s.split(",")
        if ys.any?
          ys.map!(&:to_sym)
          ys.first.to_proc
        end
      RUBY
    end

    it "keeps the refinement's element under a value-preserving mutator" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        ys = gets.to_s.split(",")
        if ys.any?
          ys.sort!
          ys.first.to_proc
        end
      RUBY
    end

    # The #1253 review's probe, through the `unless … empty?` narrowing. A rewrite cannot empty the receiver, so
    # the witness stays and only the element goes; a reorder changes neither, so the binding must not move at all.
    # Since issue #2427 the element is the block's: `to_sym` on each `ENV.keys` String answers a Symbol.
    it "keeps the witness and replaces the element under `map!` and `collect!`" do
      expect(dumped_types(<<~RUBY)).to eq(["non-empty-array[Symbol]"] * 2)
        ys = ENV.keys
        unless ys.empty?
          ys.map!(&:to_sym)
          dump_type(ys)
        end
        zs = ENV.keys
        unless zs.empty?
          zs.collect! { |z| z.to_sym }
          dump_type(zs)
        end
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        ys = ENV.keys
        unless ys.empty?
          ys.map!(&:to_sym)
          ys.first.to_proc
        end
      RUBY
    end

    it "leaves the refinement exactly as it was under `sort!` and `reverse!`" do
      expect(dumped_types(<<~RUBY)).to eq(["non-empty-array[String]"] * 2)
        ys = ENV.keys
        unless ys.empty?
          ys.sort!
          dump_type(ys)
          ys.reverse!
          dump_type(ys)
        end
      RUBY
    end
  end

  describe "the straight-line seam on a literal Hash" do
    it "replaces `transform_values!`'s value side, and only it" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, Dynamic[top]]"])
        h = { a: 1 }
        h.transform_values!(&:to_s)
        dump_type(h)
      RUBY
    end

    it "replaces `transform_keys!`'s key side, and only it" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Dynamic[top], 1]"])
        h = { a: 1 }
        h.transform_keys!(&:to_s)
        dump_type(h)
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        h = { a: 1 }
        h.transform_keys!(&:to_s)
        h.keys.first.bytesize
      RUBY
    end

    it "keeps the seed's key under `compact!`" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        h = { a: 1 }
        h.compact!
        h.keys.first.bytesize
      RUBY
    end

    # `merge!` / `update` keep every key the argument lacks, so they join; `replace` keeps nothing.
    it "joins the gradual arm into both sides under `merge!` / `update`, and replaces both under `replace`" do
      expected = (["Hash[Dynamic[top] | Symbol, 1 | Dynamic[top]]"] * 3) + ["Hash[Dynamic[top], Dynamic[top]]"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        h = { a: 1 }
        h.merge!({ a: 2 }) { |_k, o, _n| o.to_s }
        dump_type(h)

        i = { a: 1 }
        i.merge!(b: "s")
        dump_type(i)

        j = { a: 1 }
        j.update("k" => 2)
        dump_type(j)

        k = { a: 1 }
        k.replace({ "x" => "s" })
        dump_type(k)
      RUBY
    end

    # `Hash.new(0)` proves its value side, and an ADDER's re-join keeps that proof (#580's
    # `keep_precise_parameters`); a rewriter falsifies it, so the side it rewrites goes gradual.
    it "replaces a re-opened carrier's proven value side under `transform_values!`" do
      expected = ["Hash[Dynamic[top] | Symbol, Dynamic[top]]", "Hash[Dynamic[top] | Symbol, Integer]"]
      expect(dumped_types(<<~RUBY)).to eq(expected)
        h = Hash.new(0)
        h[:x] += 1
        h.transform_values!(&:to_s)
        dump_type(h)

        g = Hash.new(0)
        g[:x] += 1
        g.compact!
        dump_type(g)
      RUBY
    end
  end

  describe "the block-capture seam" do
    it "gives a captured literal's rewritten element the gradual arm" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        a = [1]
        [0].each { a.map!(&:to_s) }
        a.first.upcase
      RUBY
    end

    # The slice-C join rebuilds the capture from its seed to add `"x"`, which dropped the rewrite.
    it "keeps the rewrite when the same block also appends, and does not fold on it" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Array[\"x\" | 1]"])
        a = [1]
        [0].each { a.map!(&:to_s); a << "x" }
        dump_type(a)

        b = [1]
        [0].each { b.sort!; b << "x" }
        dump_type(b)
      RUBY
      expect(rules(<<~RUBY, "flow.")).to be_empty
        a = [1]
        [0].each { a.map!(&:to_s); a << "x" }
        puts "one" if a[0] == "1"
      RUBY
    end

    it "keeps the captured literal's element under a value-preserving mutator" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        a = [1]
        [0].each { a.sort! }
        a.first.upcase
      RUBY
    end
  end

  describe "the loop seam" do
    it "keeps the rewrite when the same loop body also appends" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top]]", "Array[\"x\" | 1]"])
        a = [1]
        i = 0
        while i < 2
          a.map!(&:to_s)
          a << "x"
          i += 1
        end
        dump_type(a)

        b = [1]
        j = 0
        while j < 2
          b.sort!
          b << "x"
          j += 1
        end
        dump_type(b)
      RUBY
    end
  end

  # The #561 boundary. A precise nominal's element set is a claim a declaration made, so the rewrite does not
  # grow it (RBS's own `map!` is `{ (Elem) -> Elem } -> self`). What a rewrite leaves on a literal seed must stay
  # accepted by a hand-written return type: gradual where the old values are gone, the seed kept beside the arm
  # (haml's `-> Array[:multi]`) where they may survive.
  describe "the signature boundary" do
    def return_rules(body, sig_line)
      sig = { "maker.rbs" => "class Maker\n  def call: () -> #{sig_line}\nend\n" }
      rules("class Maker\n  def call\n#{body.gsub(/^/, '    ')}  end\nend\n", "def.", sig: sig)
    end

    it "leaves a precise nominal as it is" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[String]"])
        s = gets.to_s.split(",")
        s.map!(&:strip)
        dump_type(s)
      RUBY
    end

    it "accepts a literal a class-changing rewrite turned into the declared element" do
      expect(return_rules("a = [1, 2]\na.map!(&:to_s)\na\n", "Array[String]")).to be_empty
      expect(return_rules("a = [1, 2]\na.replace([\"x\"])\na\n", "Array[String]")).to be_empty
      expect(return_rules("h = { a: 1 }\nh.transform_values!(&:to_s)\nh\n", "Hash[Symbol, String]")).to be_empty
      expect(return_rules("h = { a: 1 }\nh.transform_keys!(&:to_s)\nh\n", "Hash[String, Integer]")).to be_empty
    end

    it "still rejects the literal under a value-preserving mutator in the same position" do
      expect(return_rules("a = [1, 2]\na.sort!\na\n", "Array[String]")).to eq(["def.return-type-mismatch"])
      expect(return_rules("h = { a: 1 }\nh.compact!\nh\n", "Hash[String, Integer]"))
        .to eq(["def.return-type-mismatch"])
    end

    it "keeps a partially rewritten literal's pinning, which the hand-written type accepts" do
      expect(return_rules("t = [:multi, :multi]\nt.fill(:multi, 1)\nt\n", "Array[:multi]")).to be_empty
      expect(return_rules("t = [:other]\nt.fill(:multi, 1)\nt\n", "Array[:multi]")).to eq(["def.return-type-mismatch"])
    end
  end

  # Issue #2555 L3 — the `:synthesised` construction fact. A local the engine built itself (a collection literal, or
  # a core `Array.new` / `Hash.new` / `Set.new` / `Set[...]` constructor) re-grows precisely at the straight-line
  # seam, with no `Dynamic[top]` floor; a carrier whose binding does not carry the fact keeps today's #561 answer.
  # Each example pairs the stamped binding with an unstamped control in the same position.
  describe "the :synthesised construction fact (issue #2555)" do
    def return_rules(body, sig_line)
      sig = { "maker.rbs" => "class Maker\n  def call: () -> #{sig_line}\n  def helper: () -> #{sig_line}\nend\n" }
      rules("class Maker\n  def helper = []\n  def call\n#{body.gsub(/^/, '    ')}  end\nend\n", "def.", sig: sig)
    end

    # Issue #1119.
    it "re-grows a constructor-seeded Array with the stored element and no floor" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Integer | String]", "Array[Integer | String]"])
        n = gets.to_i
        a = Array.new(n, 0)
        a << "s"
        dump_type(a)
        b = Array.new(n) { 0 }
        b[0] = "s"
        dump_type(b)
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        n = gets.to_i
        a = Array.new(n, 0)
        a << "s"
        a.last.upcase
      RUBY
    end

    it "keeps the floor on a precise carrier a signature declared" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top] | String]"])
        s = gets.to_s.split(",")
        s << 1
        dump_type(s)
      RUBY
    end

    # Issue #1289 — a literal closed by a value-preserving mutator.
    it "lets a Hash literal closed by `delete` take a later rewrite" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        g = { a: 1 }
        g.delete(:b)
        g.transform_values!(&:to_s)
        g[:a].upcase
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(["Hash[Symbol, Dynamic[top]]"])
        g = { a: 1 }
        g.delete(:b)
        g.transform_values!(&:to_s)
        dump_type(g)
      RUBY
    end

    # The control: an alias copy carries no fact (issue #2335), so the rewrite through it is declined as before.
    it "declines the same rewrite through an alias copy, which carries no fact" do
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        g = { a: 1 }
        g.delete(:b)
        h = g
        h.transform_values!(&:to_s)
        h[:a].upcase
      RUBY
    end

    it "joins an adder's store into a literal closed by `sort!`" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[1 | 2 | String]", "Array[1 | 2 | Dynamic[top]]"])
        a = [1, 2]
        a.sort!
        a << "s"
        dump_type(a)
        c = [1, 2]
        c.sort!
        d = c
        d << "s"
        dump_type(d)
      RUBY
    end

    it "widens a block-captured rewrite of a closed literal honestly" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        a = [1, 2]
        [0].each { a.sort!; a.map!(&:to_s) }
        a.first.upcase
      RUBY
    end

    it "lets a Hash literal built as a nominal take a rewrite, and keeps its value under `compact!`" do
      expect(undefined_method_rules(<<~RUBY)).to be_empty
        h = { ENV["A"].to_s => 1 }
        h.transform_values!(&:to_s)
        h.each_value { |v| v.upcase }
      RUBY
      expect(undefined_method_rules(<<~RUBY)).to eq(["call.undefined-method"])
        h = { ENV["A"].to_s => 1 }
        h.compact!
        h.each_value { |v| v.upcase }
      RUBY
    end

    # The straight-line seam types a store's arguments only for a receiver it will join into, so a precise Hash
    # counts as one when its binding carries the fact.
    it "joins a stored pair into a Hash literal built as a nominal" do
      expect(dumped_types(<<~RUBY)).to eq(["Hash[String, Integer | String]"])
        h = { ENV["A"].to_s => 1 }
        h["k"] = "v"
        dump_type(h)
      RUBY
    end

    # A constructor-shaped call on anything but the core class is a declared return, not a construction.
    it "gives no fact to a `[]` whose receiver is not the core class" do
      sig = { "maker.rbs" => "module Maker\n  def self.[]: () -> Array[Integer]\nend\n" }
      source = "module Maker\n  def self.[] = [1]\nend\na = Maker[]\na << \"s\"\ndump_type(a)\n"
      dumped = diagnostics(source, sig: sig).filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
      expect(dumped).to eq(["Array[Dynamic[top] | Integer]"])
    end

    # The #561 boundary on a declared carrier: a foreign store joins as the floor, so the declared return accepts it.
    it "keeps a declared carrier's foreign store behind the floor, and the declared return accepting it" do
      expect(return_rules("t = helper\nt << [:static, \"x\"]\nt\n", "Array[:multi]")).to be_empty
    end

    def fact_free_sig
      "class F\n  def push: (Array[Integer] xs) -> untyped\n  " \
        "def pick: (bool c, Array[Integer] param) -> untyped\n  " \
        "def rebind: (Array[Integer] param) -> untyped\nend\n"
    end

    def fact_free_source
      <<~RUBY
        class F
          def push(xs)
            xs << "s"
            dump_type(xs)
          end

          def pick(c, param)
            if c
              a = [1]
              a.sort!
            else
              a = param
            end
            a << "s"
            dump_type(a)
          end

          def rebind(param)
            a = [1]
            a.sort!
            a = param
            a << "s"
            dump_type(a)
          end
        end
      RUBY
    end

    it "gives no fact to a parameter, a merge with an unstamped arm, or a rebind" do
      dumped = diagnostics(fact_free_source, sig: { "f.rbs" => fact_free_sig }).filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
      expect(dumped).to eq(["Array[Dynamic[top] | Integer]",
                            "Array[1 | Dynamic[top]] | Array[Dynamic[top] | Integer]",
                            "Array[Dynamic[top] | Integer]"])
    end

    it "keeps the fact through a merge both arms establish" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[1 | String] | Array[2 | String]"])
        if gets
          a = [1]
        else
          a = [2]
        end
        a.sort!
        a << "s"
        dump_type(a)
      RUBY
    end

    # Review round 1 — a remover or filter can take a stored member out again, and nothing narrows the carrier
    # back, so on a carrier a store has grown it restores the reading the carrier has without the fact: the floor,
    # with the stored `nil` gone, and no fact from then on.
    {
      "Array#compact!" => "p = Array.new(n, \"a\")\np << (gets ? nil : \"b\")\np.compact!\np.each { |s| s.upcase }",
      "Array#compact! after an untyped store" =>
        "def f(n, x)\n  p = Array.new(n, \"a\")\n  p << (x.empty? ? nil : x)\n  " \
        "p.compact!\n  p.each { |s| s.upcase }\nend",
      "Array#delete" => "p = Array.new(n, \"a\")\np << nil\np.delete(nil)\np.each { |s| s.upcase }",
      "Array#reject!" => "p = Array.new(n, \"a\")\np << nil\np.reject!(&:nil?)\np.each { |s| s.upcase }",
      "Array#select!" => "p = Array.new(n, \"a\")\np << nil\np.select! { |e| e }\np.each { |s| s.upcase }",
      "Array#pop" => "p = %w[b a]\np.sort!\np << nil\np.pop\np.each { |s| s.upcase }",
      "Hash#delete" => "h = { ENV[\"A\"].to_s => \"x\" }\nh[\"k\"] = nil\n" \
                       "h.delete(\"k\")\nh.each_value { |v| v.upcase }",
      "Hash#reject!" => "h = { a: \"x\" }\nh.delete(:zz)\nh[:k] = nil\nh.reject! { |_, v| v.nil? }\n" \
                        "h.each_value { |v| v.upcase }",
      "Hash#compact!" => "h = { ENV[\"A\"].to_s => \"x\" }\nh[\"k\"] = nil\nh.compact!\nh.each_value { |v| v.upcase }",
      "Set#delete" => "s = Set[\"a\"]\ns << nil\ns.delete(nil)\ns.each { |v| v.upcase }"
    }.each do |remover, body|
      it "floors a grown synthesised carrier under #{remover}" do
        expect(rules("n = gets.to_i\n#{body}\n", "call.")).to be_empty
      end
    end

    it "keeps a remover with no prior store on today's answer, and drops the fact after a floored remover" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[String]", "Array[1 | 2]", "Array[Dynamic[top] | Integer | String]"])
        n = gets.to_i
        a = Array.new(n, "a")
        a.compact!
        dump_type(a)
        b = [1, 2]
        b.sort!
        b.delete(1)
        dump_type(b)
        c = Array.new(n, "a")
        c << nil
        c.compact!
        c << 1
        dump_type(c)
      RUBY
    end

    # Review round 1 — a store through another holder of the object is one the seam never sees, so a local that may
    # escape anywhere in its body carries no fact and answers as a carrier without one.
    {
      "an alias" => "b = a\nb << \"s\"",
      "a tap block" => "a.tap { |arr| arr << \"s\" }",
      "itself" => "x = a.itself\nx << \"s\"",
      "an array element" => "[a].each { |y| y << \"s\" }",
      "a hash value" => "h = { k: a }\nh[:k] << \"s\"",
      "an instance variable" => "@a = a\n@a << \"s\"",
      "public_send" => "a.public_send(:<<, \"s\")",
      "send" => "a.send(:push, \"s\")",
      "a method object" => "a.method(:<<).call(\"s\")",
      "instance_exec" => "a.instance_exec { self << \"s\" }",
      "binding" => "binding.local_variable_set(:a, [\"s\"])",
      "eval" => "eval(\"a << 's'\")",
      "a lambda" => "pr = -> { a << \"s\"; nil }\npr.call",
      "a chained <<" => "a << :y << \"s\"",
      "a chained push" => "a.push(:y).push(\"s\")",
      "a chained rewrite" => "a.unshift(:y).map!(&:to_s)",
      "a chained tap" => "a.push(:y).tap { |z| z << \"s\" }",
      "a storing argument" => "list = []\nlist << a\nlist.last << \"s\""
    }.each do |escape, body|
      it "gives no fact to a local that escapes through #{escape}" do
        dumped = dumped_types("n = gets.to_i\na = Array.new(n, 0)\na << :x\n#{body}\ndump_type(a)\n")
        expect(dumped.last).to include("Dynamic[top]")
      end
    end

    it "gives no fact through a chained write, and keeps it for a plain statement-position store" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Dynamic[top] | Integer]", "Array[Integer | String]"])
        n = gets.to_i
        a = b = Array.new(n, 0)
        b << "s"
        dump_type(b)
        c = Array.new(n, 0)
        c << "s"
        dump_type(c)
      RUBY
    end

    # A read in the body's value position (`return a`) hands the object on only once nothing in the body runs.
    it "keeps the fact across an early `return a`" do
      expect(dumped_types(<<~RUBY)).to eq(["Array[Integer | String]"])
        def early(n)
          a = Array.new(n, 0)
          return a if n.zero?

          a << "s"
          dump_type(a)
        end
      RUBY
    end

    it "floors a local a user method mutates through its argument, as before" do
      dumped = dumped_types(<<~RUBY)
        def add_label(arr) = arr << "label"
        n = gets.to_i
        a = Array.new(n, 0)
        a << :x
        add_label(a)
        dump_type(a)
      RUBY
      expect(dumped.last).to include("Dynamic[top]")
    end

    it "joins a store into a merged union of synthesised hashes, and drops a slot write's value pin" do
      merged = "Hash[String, Integer | String] | Hash[String, String | Symbol]"
      expect(dumped_types(<<~RUBY)).to eq([merged, "Array[Integer]"])
        if gets
          h = { ENV["A"].to_s => 1 }
        else
          h = { ENV["B"].to_s => :x }
        end
        h["k"] = "v"
        dump_type(h)
        a = [1, 2]
        a.sort!
        a[0] = 5
        dump_type(a)
      RUBY
    end

    # Issue #2534 — the Set floor came off, so a member read reports what the member class does not answer. A
    # union of two classes stays silent by the diagnostic policy, so the true positive needs a same-class store.
    it "reports a Set member read once the synthesised Set grows without a floor" do
      expect(undefined_method_rules(<<~RUBY)).to eq(%w[call.undefined-method call.undefined-method])
        s = Set[1]
        s << 2
        s.to_a.first.upcase
        t = Set.new([1])
        t << 2
        t.to_a.first.upcase
      RUBY
      expect(dumped_types(<<~RUBY)).to eq(["Set[Integer | String]", "Set[Dynamic[top] | String]"])
        s = Set[1]
        s << "a"
        dump_type(s)
        u = ARGV.to_set
        u << 1
        dump_type(u)
      RUBY
    end
  end
end
