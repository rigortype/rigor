# frozen_string_literal: true

require "spec_helper"

# Issue #2608 — a collection remover or filter narrows its receiver's element (Hash key / value) type by what Ruby
# guarantees it removed. Every narrowing example has a control in the same position: a remover that cannot say what
# it removed (`sort!`, `pop`, a non-literal `delete`, an unknown predicate), which must keep today's reading.
RSpec.describe "collection remover narrowing", type: :runner do
  def diagnostics(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source, sig: {})
    diagnostics(source, sig: sig).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  # Elements that are `1` / `"s"` or `nil` at runtime, which a literal alone cannot spell.
  def maybe_one = "def mk = gets ? 1 : nil\ndef ms = gets ? \"s\" : nil\n"

  def rules(source, prefix = "call.", sig: {})
    diagnostics(source, sig: sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix)
    end
  end

  describe "the issue's gradual Hash" do
    # `pp(h)` hands the Hash on, so it carries no #2555 construction fact (whose remover floor would drop the nil on
    # its own): this is the gradual carrier the issue reports on.
    def issue_source(remover)
      <<~RUBY
        def key = gets.to_s
        h = {}
        h[key] = 1
        h[key] = nil
        #{remover}
        h.each_value { |v| v + 1 }
        pp(h)
      RUBY
    end

    it "drops the stored nil under `compact!`" do
      expect(rules(issue_source("h.compact!"))).to be_empty
    end

    it "keeps it with no remover (control)" do
      expect(rules(issue_source("nil"))).to eq(["call.possible-nil-receiver"])
    end
  end

  describe "Array#compact!" do
    it "reads a literal's surviving element without nil, and `first` keeps its optimistic reading" do
      expect(dumped_types("a = [1, nil]\na.compact!\ndump_type(a.dup)\ndump_type(a.first)\n"))
        .to eq(%w[Array[Integer] 1])
      expect(rules("a = [1, nil]\na.compact!\na.first + 1\n")).to be_empty
    end

    it "keeps the nil under a value-preserving mutator (control)" do
      expect(dumped_types("a = [1, nil]\na.sort!\ndump_type(a.dup)\n")).to eq(["Array[Integer?]"])
    end

    it "narrows inside a branch, and the join reads the union of the arms" do
      expect(dumped_types("#{maybe_one}a = [mk, 2]\na.compact! if gets\ndump_type(a)\n"))
        .to eq(["Array[1 | 2] | [1?, 2]"])
    end

    # Guard: the loop's join already reads the stored arm back.
    it "keeps the arm a loop stores again after the remover (guard)" do
      expect(dumped_types("#{maybe_one}a = [mk, 2]\nwhile gets\n  a.compact!\n  a << nil\nend\ndump_type(a)\n"))
        .to eq(["Array[1 | 2 | nil]"])
    end

    it "narrows an instance variable" do
      expect(dumped_types("#{maybe_one}@a = [mk, 2]\n@a.compact!\ndump_type(@a)\n")).to eq(["Array[1 | 2]"])
    end

    # Review round 1 of #2621 — a write through another holder after the call would outlive the narrowing, so a
    # receiver the body may write that way keeps the ordinary reading. Each pairs with a control that narrows.
    describe "a receiver another holder may write" do
      # The reading right after the filter. A narrowed one holds neither `nil` nor `Dynamic` (`is_a?` narrows a
      # gradual element to `Integer` too); the ordinary one keeps whichever the binding carried.
      def narrowed(prefix, suffix = "")
        filter = "l.select! { |x| x.is_a?(Integer) }"
        dumped_types("#{maybe_one}l = [mk, 2]\n#{prefix}\n#{filter}\ndump_type(l)\n#{suffix}\n").first
      end

      it "narrows with no other holder (control)" do
        expect(narrowed("nil")).to eq("Array[1 | 2]")
      end

      {
        "a copy into another local" => ["al = l", ""],
        "a copy made from the receiver's alias" => ["al = l\nl = al", ""],
        "a multiple assignment" => ["al, x = l, 1", ""],
        "an instance-variable copy" => ["@k = l", ""],
        "a proc created earlier" => ["pr = proc { l << nil }", "pr.call"],
        "a lambda created later" => ["", "pr = -> { l << nil }\npr.call"],
        "a block a non-iterator keeps" => ["define_singleton_method(:f) { l << nil }", ""],
        "send" => ["", "l.send(:<<, nil)"],
        "instance_eval" => ["", "l.instance_eval { push(nil) }"],
        "tap" => ["", "l.tap { |t| t << nil }"],
        "binding" => ["", "binding"]
      }.each do |holder, (prefix, suffix)|
        it "keeps the ordinary reading under #{holder}" do
          expect(narrowed(prefix, suffix)).to match(/nil|Dynamic/)
        end
      end

      it "still narrows a local only an iterator block reads (control)" do
        expect(narrowed("[1].each { l.size }")).to eq("Array[1 | 2]")
      end

      it "keeps the ordinary reading of both names of an alias" do
        expect(dumped_types("#{maybe_one}a = [mk, 2]\nb = a\nb.compact!\ndump_type(a)\ndump_type(b)\n"))
          .to eq(["[1?, 2]", "Array[1 | 2 | nil]"])
      end
    end

    it "narrows no candidate of a receiver that selects among bindings" do
      expect(dumped_types("#{maybe_one}a = [mk, 2]\n(gets ? a : [3]).compact!\ndump_type(a)\n"))
        .to eq(["Array[1 | 2 | nil]"])
    end

    it "narrows a declared parameter's binding in its body, and not the caller's argument" do
      source = <<~RUBY
        class C
          def f(xs)
            xs.compact!
            dump_type(xs)
            xs.first + 1
          end

          def g(ys)
            f(ys)
            dump_type(ys)
          end
        end
      RUBY
      sig = { "c.rbs" => "class C\n  def f: (Array[Integer?]) -> Integer\n  def g: (Array[Integer?]) -> void\nend\n" }
      expect(dumped_types(source, sig: sig)).to eq(["Array[Integer]", "Array[Integer?]"])
      expect(rules(source, sig: sig)).to be_empty
    end
  end

  # Guard: a call that narrows nothing answers the scope it was given, so a rebind does not drop the binding's
  # origins and facts the way a write would.
  it "answers the same scope when the narrowing changes nothing (guard)" do
    program = Prism.parse("a = []\na.compact!").value
    call = program.statements.body.last
    integers = Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])
    scope = Rigor::Scope.empty.with_match_frame(program.statements).with_local(:a, integers)
    expect(Rigor::Inference::MutationWidening.narrow_remover_receiver(call, scope, [])).to equal(scope)
  end

  describe "a nil-test block" do
    {
      "reject!(&:nil?)" => ["a.reject!(&:nil?)", "Array[1 | 2]"],
      "select!(&:nil?)" => ["a.select!(&:nil?)", "Array[nil]"],
      "reject! { |x| x.nil? }" => ["a.reject! { |x| x.nil? }", "Array[1 | 2]"],
      "select! { |x| !x.nil? }" => ["a.select! { |x| !x.nil? }", "Array[1 | 2]"],
      "filter! { |x| x }" => ["a.filter! { |x| x }", "Array[1 | 2]"],
      "delete_if { |x| !x }" => ["a.delete_if { |x| !x }", "Array[1 | 2]"],
      "keep_if { |x| x.is_a?(Integer) }" => ["a.keep_if { |x| x.is_a?(Integer) }", "Array[1 | 2]"],
      "select! { |x| Integer === x }" => ["a.select! { |x| Integer === x }", "Array[1 | 2]"],
      "select! { |x| x.instance_of?(Integer) }" => ["a.select! { |x| x.instance_of?(Integer) }", "Array[1 | 2]"]
    }.each do |form, (call, expected)|
      it "narrows like the matching guard under #{form}" do
        expect(dumped_types("#{maybe_one}a = [mk, 2]\n#{call}\ndump_type(a)\n")).to eq([expected])
      end
    end

    {
      "an unknown predicate" => "a.reject! { |x| foo(x) }",
      "a side effect before the predicate" => "a.reject! { |x| puts x; x.nil? }",
      "a predicate on another variable" => "y = mk\na.reject! { |_x| y.nil? }",
      "a numbered parameter" => "a.reject! { _1.nil? }",
      "a rebound parameter" => "a.reject! { |x| (x = 1).nil? }"
    }.each do |form, call|
      it "does not narrow under #{form} (guard)" do
        source = "#{maybe_one}def foo(_x) = gets ? true : false\na = [mk, 2]\n#{call}\ndump_type(a)\n"
        expect(dumped_types(source)).to eq(["Array[1 | 2 | nil]"])
      end
    end

    # Guard: a filter that keeps nothing says the carrier is empty, which is left to today's reading rather than
    # spelled `Array[bot]`.
    it "keeps today's reading when the kept edge is empty (guard)" do
      expect(dumped_types("a = [1, 2]\na.select! { |x| x.nil? }\ndump_type(a)\n")).to eq(["Array[1 | 2]"])
    end

    # Guard: a block with a rest or optional parameter splats an Array element, so its first parameter is not the
    # element.
    {
      "a rest parameter" => "a.reject! { |x, *r| x.nil? }",
      "an optional parameter" => "a.reject! { |x, y = 1| x.nil? }"
    }.each do |form, call|
      it "does not narrow a block with #{form} (guard)" do
        expect(dumped_types("#{maybe_one}a = [mk, 2]\n#{call}\ndump_type(a)\n")).to eq(["Array[1 | 2 | nil]"])
      end
    end

    it "narrows past a block-local variable, which cannot rebind the parameter" do
      expect(dumped_types("#{maybe_one}a = [mk, 2]\na.reject! { |x; y| x.nil? }\ndump_type(a)\n"))
        .to eq(["Array[1 | 2]"])
    end

    it "narrows a Hash value under the `|k, v|` form" do
      expect(dumped_types("#{maybe_one}h = { a: mk, b: 2 }\nh.reject! { |_k, v| v.nil? }\ndump_type(h)\n"))
        .to eq(["Hash[Symbol, 1 | 2]"])
      expect(dumped_types("#{maybe_one}h = { a: mk, b: 2 }\nh.select! { |_k, v| v }\ndump_type(h)\n"))
        .to eq(["Hash[Symbol, 1 | 2]"])
    end

    it "does not narrow a Hash under a one-parameter block, which receives the pair (control)" do
      expect(dumped_types("#{maybe_one}h = { a: mk, b: 2 }\nh.reject! { |pair| pair.nil? }\ndump_type(h)\n"))
        .to eq(["Hash[Symbol, 1 | 2 | nil]"])
    end

    it "narrows a Set element" do
      expect(dumped_types("#{maybe_one}s = Set[ms, \"t\"]\ns.reject! { |x| x.nil? }\ndump_type(s)\n"))
        .to eq(["Set[Dynamic[top] | String]"])
    end
  end

  describe "a literal-nil delete" do
    it "drops nil from an Array element, and a non-literal argument keeps it (control)" do
      expect(dumped_types("#{maybe_one}a = [mk, 2]\na.delete(nil)\ndump_type(a)\n")).to eq(["Array[1 | 2]"])
      expect(dumped_types("#{maybe_one}a = [mk, 2]\na.delete(mk)\ndump_type(a)\n")).to eq(["Array[1 | 2 | nil]"])
    end

    it "drops nil from a Set element under `delete` and `delete?`" do
      expect(dumped_types("#{maybe_one}s = Set[ms, \"t\"]\ns.delete(nil)\ndump_type(s)\n"))
        .to eq(["Set[Dynamic[top] | String]"])
      expect(dumped_types("#{maybe_one}s = Set[ms, \"t\"]\ns.delete?(nil)\ndump_type(s)\n"))
        .to eq(["Set[Dynamic[top] | String]"])
    end

    it "drops nil from a Hash key, and leaves the value alone" do
      source = "#{maybe_one}h = { ms => mk }\nh.delete(nil)\ndump_type(h)\n"
      expect(dumped_types(source)).to eq(["Hash[\"s\", 1?]"])
    end
  end

  describe "Hash#compact!" do
    it "drops nil from the value, and a value-preserving `rehash` keeps it (control)" do
      expect(dumped_types("#{maybe_one}h = { a: mk, b: 2 }\nh.compact!\ndump_type(h)\n"))
        .to eq(["Hash[Symbol, 1 | 2]"])
      expect(dumped_types("#{maybe_one}h = { a: mk, b: 2 }\nh.rehash\ndump_type(h)\n"))
        .to eq(["{ a: 1?, b: 2 }"])
    end
  end

  describe "a closed HashShape under a literal-key delete" do
    it "drops the key it names" do
      expect(dumped_types("h = { a: 1, b: 2 }\nh.delete(:a)\ndump_type(h)\n")).to eq(["{ b: 2 }"])
    end

    it "keeps the shape when the key is absent" do
      expect(dumped_types("h = { a: 1 }\nh.delete(:z)\ndump_type(h)\n")).to eq(["{ a: 1 }"])
    end

    it "drops the key under the block form, which still deletes it" do
      expect(dumped_types("h = { a: 1, b: 2 }\nh.delete(:a) { 0 }\ndump_type(h)\n")).to eq(["{ b: 2 }"])
    end

    # Under `compare_by_identity` an equal String need not be the stored key, so only a Symbol key narrows.
    it "erases the shape under a String key (guard)" do
      expect(dumped_types("h = { \"a\" => 1, \"b\" => 2 }\nh.delete(\"a\")\ndump_type(h)\n"))
        .to eq(["Hash[String, 1 | 2]"])
    end

    # Guard: a read-only entry cannot be written through the shape; no source spelling builds one, so the seam is
    # asked directly.
    it "answers nothing for a read-only key (guard)" do
      shape = Rigor::Type::Combinator.hash_shape_of(
        { a: Rigor::Type::Combinator.constant_of(1) }, read_only_keys: [:a]
      )
      call = Prism.parse("h.delete(:a)").value.statements.body.first
      expect(Rigor::Inference::RemoverNarrowing.narrow_shape(shape, call)).to be_nil
      writable = Rigor::Type::Combinator.hash_shape_of({ a: Rigor::Type::Combinator.constant_of(1) })
      expect(Rigor::Inference::RemoverNarrowing.narrow_shape(writable, call)).not_to be_nil
    end

    it "erases the shape under a key nothing types (control)" do
      expect(dumped_types("h = { a: 1, b: 2 }\nh.delete(gets.to_s.to_sym)\ndump_type(h)\n"))
        .to eq(["Hash[Symbol, 1 | 2]"])
    end
  end

  # Labelled guards: which member a positional remover, `subtract` or a non-literal delete takes is not provable, so
  # each keeps today's reading.
  describe "removers that cannot narrow" do
    {
      "pop" => "a.pop", "shift" => "a.shift", "slice!" => "a.slice!(0)", "clear" => "a.clear"
    }.each do |remover, call|
      it "keeps the nil arm under Array##{remover} (guard)" do
        expect(dumped_types("#{maybe_one}a = [mk, 2]\n#{call}\ndump_type(a)\n")).to eq(["Array[1 | 2 | nil]"])
      end
    end

    it "keeps the nil arm under Set#subtract (guard)" do
      expect(dumped_types("#{maybe_one}s = Set[ms, \"t\"]\ns.subtract([\"t\"])\ndump_type(s)\n"))
        .to eq(["Set[Dynamic[top] | String | nil]"])
    end
  end

  # Issue #2555's remover floor stays only where nothing narrows: an exact remover on a grown synthesised carrier
  # answers the precise narrowed reading.
  describe "a synthesised carrier a store has grown" do
    {
      "Array#compact!" => ["a = Array.new(n, \"a\")\na << ms\na.compact!", "Array[String]"],
      "Array#delete(nil)" => ["a = Array.new(n, \"a\")\na << nil\na.delete(nil)", "Array[String]"],
      "Array#reject!(&:nil?)" => ["a = Array.new(n, \"a\")\na << nil\na.reject!(&:nil?)", "Array[String]"],
      "Array#select!" => ["a = Array.new(n, \"a\")\na << nil\na.select! { |e| e }", "Array[String]"],
      "Hash#compact!" => ["a = { ENV[\"A\"].to_s => \"x\" }\na[\"k\"] = nil\na.compact!", "Hash[String, String]"],
      "Set#delete(nil)" => ["a = Set[\"a\"]\na << nil\na.delete(nil)", "Set[String]"]
    }.each do |remover, (body, expected)|
      it "reads the precise narrowed carrier under #{remover}" do
        expect(dumped_types("#{maybe_one}n = gets.to_i\n#{body}\ndump_type(a.dup)\n")).to eq([expected])
      end
    end

    it "keeps the floored reading under a block whose predicate it cannot read (control)" do
      source = "#{maybe_one}def foo(_x) = gets ? true : false\nn = gets.to_i\na = Array.new(n, \"a\")\na << ms\n" \
               "a.reject! { |x| foo(x) }\ndump_type(a.dup)\n"
      expect(dumped_types(source)).to eq(["Array[Dynamic[top] | String]"])
    end

    it "keeps the floored reading under a positional remover (control)" do
      expect(dumped_types("#{maybe_one}n = gets.to_i\na = Array.new(n, \"a\")\na << ms\na.pop\ndump_type(a.dup)\n"))
        .to eq(["Array[Dynamic[top] | String]"])
    end

    it "keeps reporting a stored nil a non-nil delete leaves (the #2606 true positive)" do
      expect(rules("s = Set[1]\ns << nil\ns.delete(1)\ns.each { |v| v + 1 }\n"))
        .to eq(["call.possible-nil-receiver"])
    end
  end
end
