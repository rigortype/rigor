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
