# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

# Issue #3205 — a `for` index binds as a block's parameters do. Ruby 4.0 binds a single target to the first
# yielded value (`yield 1, 2` binds `b = 1`), and a multi-target or splat index to all of them
# (`a = 1, c = 2`; `s = [1, 2]`). Rigor bound a single target to the whole yield as a tuple.
RSpec.describe "a `for` index over a multi-value yield (#3205)" do
  around do |example|
    Dir.mktmpdir("rigor-for-multi-yield-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:t) { Rigor::Type::Combinator }

  def post_scope(source, rbs: nil)
    if rbs
      FileUtils.mkdir_p("sig")
      File.write("sig/k.rbs", rbs)
    end
    environment = Rigor::Environment.for_project(signature_paths: rbs ? ["sig"] : [])
    Rigor::Scope.empty(environment: environment).evaluate(Prism.parse(source).value).last
  end

  # The index is nil-injected through the zero-iteration join; the members other than `nil` are the binding.
  def bound(source, name, rbs: nil)
    type = post_scope(source, rbs: rbs).local(name)
    members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
    members.reject { |member| member == t.constant_of(nil) }
  end

  describe "an `each` declared to yield two values" do
    let(:rbs) { "class K\n  def each: () { (Integer, String) -> void } -> void\nend\n" }
    let(:prefix) { "class K; def each = yield(1, 'a'); end\nk = K.new\n" }

    it "binds a single target to the first value" do
      expect(bound("#{prefix}for b in k; end", :b, rbs: rbs)).to eq([t.nominal_of("Integer")])
    end

    # Guard (#3205 does not change it): a multi-target or splat index takes every value.
    it "binds a multi-target index to each value" do
      source = "#{prefix}for a, c in k; end"
      expect(bound(source, :a, rbs: rbs)).to eq([t.nominal_of("Integer")])
      expect(bound(source, :c, rbs: rbs)).to eq([t.nominal_of("String")])
    end

    it "binds a splat index to all the values" do
      expect(bound("#{prefix}for *s in k; end", :s, rbs: rbs))
        .to eq([t.tuple_of(t.nominal_of("Integer"), t.nominal_of("String"))])
    end
  end

  describe "an Enumerator whose element is a tuple" do
    # `each_with_index` yields two values (`b == [1, 2]`), `Hash#each` one array (`b == [:k, 1]`); the
    # `Enumerator[[A, B]]` both answer does not tell them apart, so a single target binds neither guess.
    it "binds a single target to Dynamic[top]" do
      expect(bound("for b in [[1, 2]].each_with_index; end", :b)).to eq([t.untyped])
      expect(bound("for b in({ k: 1 }).each; end", :b)).to eq([t.untyped])
    end

    # Guard (#3205 does not change it): a multi-target index decomposes the tuple either way.
    it "still decomposes the tuple for a multi-target index" do
      source = "for a, c in [[1, 2]].each_with_index; end"
      expect(bound(source, :a)).to eq([t.tuple_of(t.constant_of(1), t.constant_of(2))])
      expect(bound(source, :c)).to eq([t.nominal_of("Integer")])
    end

    # Guard (#3205 does not change it): a splat index takes every value, which is the tuple either way.
    it "still binds a splat index to the tuple" do
      expect(bound("for *s in [[1, 2]].each_with_index; end", :s))
        .to eq([t.tuple_of(t.tuple_of(t.constant_of(1), t.constant_of(2)), t.nominal_of("Integer"))])
    end
  end

  # The floor reads `Enumerator`'s ancestry and the declared element, not the receiver's spelling.
  describe "a declared receiver" do
    let(:rbs) do
      <<~RBS
        class Holder
          def strs: () -> Array[String]
          def pairs: () -> Array[[String, Integer]]
          def table: () -> Hash[String, Integer]
          def singles: () -> Enumerator[[String], void]
          def my_enum: () -> MyEnum
          def sub2: () -> Sub2
        end
        class MyEnum < Enumerator[[String, Integer], void]
        end
        class Sub2 < Enumerator[[Integer, String], void]
          def each: () { ([Integer, String], Symbol) -> void } -> void
        end
      RBS
    end
    let(:prefix) { "h = Holder.new\newi = h.strs.each_with_index\n" }

    {
      "an Enumerator::Lazy" => "ewi.lazy",
      "an Enumerator::Chain from `+`" => "ewi + ewi",
      "an Enumerator::Chain from `chain`" => "ewi.chain(ewi)",
      "a declared subclass of Enumerator" => "h.my_enum"
    }.each do |label, collection|
      it "binds a single target over #{label} with a tuple element to Dynamic[top]" do
        expect(bound("#{prefix}for b in #{collection}; end", :b, rbs: rbs)).to eq([t.untyped])
      end
    end

    it "keeps the pair of an Array of pairs and of a Hash" do
      pair = t.tuple_of(t.nominal_of("String"), t.nominal_of("Integer"))
      expect(bound("#{prefix}for p in h.pairs; end", :p, rbs: rbs)).to eq([pair])
      expect(bound("#{prefix}for kv in h.table; end", :kv, rbs: rbs)).to eq([pair])
    end

    # A subclass's own `each` declared to yield several values binds the first, even when that value is a tuple.
    it "keeps the first declared value of an Enumerator subclass whose each yields several" do
      expect(bound("#{prefix}for b in h.sub2; end", :b, rbs: rbs))
        .to eq([t.tuple_of(t.nominal_of("Integer"), t.nominal_of("String"))])
    end

    it "keeps a one-slot tuple element of an Enumerator" do
      expect(bound("#{prefix}for s in h.singles; end", :s, rbs: rbs)).to eq([t.tuple_of(t.nominal_of("String"))])
    end
  end

  # Guard (#3205 does not change it): an Array or a Hash yields one value per element.
  describe "a collection that yields one value" do
    it "binds a single target to an Array's pair element" do
      expect(bound("for b in [[1, 2]]; end", :b)).to eq([t.tuple_of(t.constant_of(1), t.constant_of(2))])
    end

    it "binds a single target to a Hash's key-value pair" do
      expect(bound("for b in({ k: 1 }); end", :b)).to eq([t.tuple_of(t.constant_of(:k), t.constant_of(1))])
    end
  end
end
