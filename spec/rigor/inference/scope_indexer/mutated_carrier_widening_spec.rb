# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::MutatedCarrierWidening` gives a constant or class variable a file mutates
# in place the type its readers may still rely on (#540). The examples hand its four public functions tables and
# types built with the combinator and read what comes back: nothing is parsed, apart from the two examples that pin
# the callers. `spec/rigor/inference/mutated_constant_census_spec.rb` and the "#540" groups of
# `scope_indexer_spec.rb` pin the read side, through `ScopeIndexer.index`.
RSpec.describe Rigor::Inference::ScopeIndexer::MutatedCarrierWidening do
  let(:indexer) { Rigor::Inference::ScopeIndexer }
  let(:element_census) { indexer::MutatedElementCensus }
  let(:combinator) { Rigor::Type::Combinator }
  let(:one) { combinator.constant_of(1) }
  let(:letter) { combinator.constant_of("a") }
  let(:pair) { combinator.tuple_of(one, combinator.constant_of(2)) }
  let(:shape) { combinator.hash_shape_of({ a: one }) }

  def integer = combinator.nominal_of("Integer")

  # What a mutated tuple is read as.
  def floored_array = "Dynamic[Array[Dynamic[top]]]"

  def array_of(*args) = combinator.nominal_of("Array", type_args: args)

  def described(table) = table.transform_values(&:describe)

  describe ".census_mutated_type" do
    def mutated(type) = described_class.census_mutated_type(type).describe

    it "floors a literal shape to an untyped Hash and a tuple to an untyped Array, under Dynamic" do
      expect(mutated(shape)).to eq("Dynamic[Hash[Dynamic[top], Dynamic[top]]]")
      expect(mutated(pair)).to eq(floored_array)
    end

    it "floors a String literal to String, and leaves any other literal as it is" do
      expect(mutated(letter)).to eq("Dynamic[String]")
      expect([mutated(one), mutated(combinator.constant_of(:sym))]).to eq(["Dynamic[1]", "Dynamic[:sym]"])
    end

    it "gives a value-pinned Array or Hash nominal a Dynamic arm, and leaves a class-level one alone" do
      expect(mutated(array_of(combinator.union(one, combinator.constant_of(2)))))
        .to eq("Dynamic[Array[1 | 2 | Dynamic[top]]]")
      expect(mutated(array_of(integer))).to eq("Dynamic[Array[Integer]]")
      expect(mutated(combinator.nominal_of("Hash", type_args: [combinator.untyped, integer])))
        .to eq("Dynamic[Hash[Dynamic[top], Integer]]")
      expect(mutated(integer)).to eq("Dynamic[Integer]")
    end

    # The pin is read before the content is floored: `Array["a"]` floors to `Array[String]`, which is class-level.
    it "tests the pin of a nominal before it floors what the nominal holds" do
      expect(mutated(array_of(letter))).to eq("Dynamic[Array[Dynamic[top] | String]]")
      expect(mutated(array_of(combinator.tuple_of(one)))).to eq("Dynamic[Array[Array[Dynamic[top]]]]")
    end

    it "unpins each member of a union" do
      expect(mutated(combinator.union(pair, combinator.constant_of(nil)))).to eq("Dynamic[Array[Dynamic[top]]?]")
    end

    it "unpins the facet of an entry that is already Dynamic" do
      expect(mutated(combinator.dynamic(pair))).to eq(floored_array)
      expect(mutated(combinator.dynamic(combinator.union(pair, letter)))).to eq("Dynamic[Array[Dynamic[top]] | String]")
      expect(mutated(combinator.untyped)).to eq("Dynamic[top]")
    end

    # `clear` empties a `non-empty-array`, so the removal is not kept. What is left is an ordinary nominal: a
    # value-pinned element gains the arm, and a class-level one keeps its claim.
    it "drops a removal a mutation can falsify, and unpins what is left as a nominal" do
      pinned = combinator.non_empty_array(combinator.constant_of(1))
      classed = combinator.non_empty_array(combinator.nominal_of("Integer"))

      expect(described_class.census_mutated_type(pinned).describe).to eq("Dynamic[Array[1 | Dynamic[top]]]")
      expect(described_class.census_mutated_type(classed).describe).to eq("Dynamic[Array[Integer]]")
    end

    it "drops a refinement to its base, as it drops a removal" do
      refined = combinator.lowercase_string

      expect(refined).to be_a(Rigor::Type::Refined)
      expect(mutated(refined)).to eq("Dynamic[String]")
    end
  end

  describe ".census_unpinned_content" do
    def unpinned(type) = described_class.census_unpinned_content(type)

    it "floors each tuple, shape and String literal an Array or Hash nominal holds, at any depth" do
      nested = combinator.nominal_of("Hash", type_args: [letter, array_of(combinator.tuple_of(one))])

      expect(unpinned(array_of(combinator.tuple_of(one))).describe).to eq("Array[Array[Dynamic[top]]]")
      expect(unpinned(array_of(shape)).describe).to eq("Array[Hash[Dynamic[top], Dynamic[top]]]")
      expect(unpinned(array_of(letter)).describe).to eq("Array[String]")
      expect(unpinned(nested).describe).to eq("Hash[String, Array[Array[Dynamic[top]]]]")
    end

    it "floors the members of a union argument, and leaves the other members as they are" do
      expect(unpinned(array_of(combinator.union(combinator.tuple_of(one), integer))).describe)
        .to eq("Array[Array[Dynamic[top]] | Integer]")
    end

    it "answers the nominal it was handed when nothing in it is such a carrier" do
      union = array_of(combinator.union(integer, combinator.nominal_of("String")))
      [array_of(integer), array_of(one), union, array_of(combinator.dynamic(combinator.tuple_of(one))),
       array_of(array_of(integer))].each { |nominal| expect(unpinned(nominal)).to equal(nominal) }
    end

    it "answers a nominal of another class, or one with no type argument, as it is" do
      set = combinator.nominal_of("Set", type_args: [combinator.tuple_of(one)])
      bare = combinator.nominal_of("Array")

      expect(unpinned(set)).to equal(set)
      expect(unpinned(bare)).to equal(bare)
    end
  end

  describe ".widen_mutated_constants" do
    let(:table) { { "A" => pair, "B" => letter, "C" => array_of(integer) }.freeze }

    it "widens each mutated name the table holds, in a frozen copy, and leaves the table it was handed" do
      widened = described_class.widen_mutated_constants(table, Set["A", "Missing"])

      expect(described(widened)).to eq("A" => floored_array, "B" => '"a"', "C" => "Array[Integer]")
      expect(widened).to be_frozen
      expect(described(table)).to eq("A" => "[1, 2]", "B" => '"a"', "C" => "Array[Integer]")
    end

    it "answers the table it was handed when no name and no element is mutated" do
      expect(described_class.widen_mutated_constants(table, Set[])).to equal(table)
      expect(described_class.widen_mutated_constants(table, Set[], Set[])).to equal(table)
    end

    it "widens the element a `[name, steps]` pair reaches, and keeps the slots it does not" do
      nested = { "A" => combinator.tuple_of(combinator.tuple_of(letter), letter), "B" => letter }.freeze
      widened = described_class.widen_mutated_constants(nested, Set[], Set[["A", [0, 0]], ["Missing", [0]]])

      expect(described(widened)).to eq("A" => '[[Dynamic[String]], "a"]', "B" => '"a"')
      expect(widened).to be_frozen
    end

    it "widens a whole name before the elements of it" do
      nested = { "A" => combinator.tuple_of(combinator.tuple_of(letter)) }.freeze

      expect(described(described_class.widen_mutated_constants(nested, Set["A"], Set[["A", [0, 0]]])))
        .to eq("A" => floored_array)
    end

    it "answers a frozen copy, the entries as they were, when the pairs reach nothing widenable" do
      widened = described_class.widen_mutated_constants(table, Set[], Set[["A", [0]], ["A", [5]]])

      expect(widened).to eq(table)
      expect(widened).to be_frozen
    end

    # The order is `MutatedElementCensus.ordered`'s, shallowest first. No two orders of pairs were found to reach
    # different tables, so the example pins who is asked rather than what the order changes.
    it "applies the pairs `MutatedElementCensus.ordered` answers, in the order it answers them" do
      nested = { "A" => combinator.tuple_of(letter, letter) }.freeze
      pairs = Set[["A", [0]], ["A", [1]]]
      allow(element_census).to receive(:ordered).and_return([["A", [1]]])

      expect(described(described_class.widen_mutated_constants(nested, Set[], pairs)))
        .to eq("A" => '["a", Dynamic[String]]')
      expect(element_census).to have_received(:ordered).with(pairs)
    end
  end

  describe ".widen_mutated_cvars" do
    let(:table) do
      { "K" => { :@@a => pair, :@@b => letter }.freeze, "L" => { :@@c => combinator.tuple_of(letter) }.freeze }.freeze
    end

    def described_classes(cvars) = cvars.transform_values { |entries| described(entries) }

    it "widens each mutated class variable the table holds, each table a frozen copy, and no other class" do
      widened = described_class.widen_mutated_cvars(table, { "K" => Set[:@@a, :@@missing], "Gone" => Set[:@@a] })

      expect(described_classes(widened)).to eq("K" => { :@@a => floored_array, :@@b => '"a"' },
                                               "L" => { :@@c => '["a"]' })
      expect([widened, widened.fetch("K")]).to all(be_frozen)
      expect(widened.fetch("L")).to equal(table.fetch("L"))
      expect(described(table.fetch("K"))).to eq(:@@a => "[1, 2]", :@@b => '"a"')
    end

    it "answers the table it was handed when no class variable and no element is mutated" do
      expect(described_class.widen_mutated_cvars(table, {})).to equal(table)
      expect(described_class.widen_mutated_cvars(table, {}, {})).to equal(table)
    end

    it "widens the element a pair reaches in a class no whole name is mutated in" do
      widened = described_class.widen_mutated_cvars(table, {}, { "L" => Set[[:@@c, [0]]], "Gone" => Set[[:@@c, [0]]] })

      expect(described_classes(widened)).to eq("K" => { :@@a => "[1, 2]", :@@b => '"a"' },
                                               "L" => { :@@c => "[Dynamic[String]]" })
      expect([widened, widened.fetch("L")]).to all(be_frozen)
    end

    it "widens the whole names of a class before the elements of it" do
      widened = described_class.widen_mutated_cvars(table, { "L" => Set[:@@c] }, { "L" => Set[[:@@c, [0]]] })

      expect(described(widened.fetch("L"))).to eq(:@@c => floored_array)
    end
  end

  # What another file of `lib/` calls: `ScopeIndexer.index` the two wideners, `ConstantIvarValue` the first of
  # them, `MutatedElementCensus` the two type functions. A fifth name here is a new way into the module.
  it "exposes the four functions another file calls, and its three constants" do
    expect(described_class.singleton_methods(false).sort)
      .to eq(%i[census_mutated_type census_unpinned_content widen_mutated_constants widen_mutated_cvars])
    expect(described_class.constants(false).sort)
      .to eq(%i[CENSUS_CONTENT_CLASSES NO_CVAR_ELEMENT_MUTATIONS NO_ELEMENT_MUTATIONS])
    expect(described_class.constants(false).map { |name| described_class.const_get(name) }).to all(be_frozen)
  end

  it "leaves none of its 7 functions and none of its constants on ScopeIndexer" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(7)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
    expect(described_class.constants(false).select { |name| indexer.const_defined?(name, false) }).to eq([])
  end

  it "calls nothing of the indexer" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/mutated_carrier_widening.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq([])
  end

  # The callers, each through what it builds: the two tables of `ScopeIndexer.index`, the constant table
  # `ConstantIvarValue` types an ivar write under, and the element `MutatedElementCensus.widen` reaches.
  it "is what `ScopeIndexer.index` widens its constant and class-variable tables with" do
    root = Prism.parse("T = [1]\nclass K; def init = (@@v = { a: 1 }); def w = (@@v[:b] = 2); end\nT << 2\n").value
    scope = indexer.index(root, default_scope: Rigor::Scope.empty)[root]

    expect(scope.in_source_constants.fetch("T").describe).to eq(floored_array)
    expect(scope.class_cvars_for("K").fetch(:@@v).describe).to eq("Dynamic[Hash[Dynamic[top], Dynamic[top]]]")
  end

  it "is what `ConstantIvarValue` and `MutatedElementCensus` ask" do
    root = Prism.parse("LIT = [1]\nLIT << 2\n").value
    value = indexer::ConstantIvarValue.new(root, Rigor::Scope.empty)
    read = Prism.parse("LIT").value.statements.body.first

    expect(value.type_of(read, Rigor::Scope.empty).describe).to eq(floored_array)
    expect(element_census.widen(combinator.tuple_of(letter), [0]).describe).to eq("[Dynamic[String]]")
    expect(element_census.widen(array_of(combinator.tuple_of(one)), [0]).describe).to eq("Array[Array[Dynamic[top]]]")
  end

  # The module reads none of the indexer's constants and calls none of its functions: with what it requires, it
  # answers.
  it "loads and answers without the indexer" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/mutated_carrier_widening"
      widening = Rigor::Inference::ScopeIndexer::MutatedCarrierWidening
      combinator = Rigor::Type::Combinator
      letter = combinator.constant_of("a")
      table = { "A" => combinator.tuple_of(combinator.tuple_of(letter)), "B" => combinator.nominal_of("Array", type_args: [letter]) }
      whole = widening.widen_mutated_constants(table, ["B"]).transform_values(&:describe)
      element = widening.widen_mutated_constants(table, [], [["A", [0, 0]]]).transform_values(&:describe)
      cvars = widening.widen_mutated_cvars({ "K" => { :@@a => letter } }, { "K" => [:@@a] })
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), whole, element, cvars["K"][:@@a].describe].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, {"A" => "[[\\"a\\"]]", "B" => "Dynamic[Array[Dynamic[top] | String]]"}, ' \
                      '{"A" => "[[Dynamic[String]]]", "B" => "Array[\\"a\\"]"}, "Dynamic[String]"]')
  end
end
