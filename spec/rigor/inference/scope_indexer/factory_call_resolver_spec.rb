# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::FactoryCallResolver` unwinds an expression to the `Data.define` or
# `Struct.new` call it creates a class from. The examples hand `resolve_meta_factory_call` the one statement of a
# parsed snippet and compare what it answers with a node of that statement, by identity: nothing is indexed and
# nothing evaluated. `shared_walk_tables_spec.rb` and `scope_indexer_spec.rb` pin what its callers make of the answer.
RSpec.describe Rigor::Inference::ScopeIndexer::FactoryCallResolver do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  def statement(source) = Prism.parse(source).value.statements.body.first

  def resolve(node, **) = described_class.resolve_meta_factory_call(node, **)

  # The source of what each snippet unwinds to, or nil.
  def resolved(*sources, **)
    sources.map { |source| resolve(statement(source), **)&.slice }
  end

  describe "a factory call" do
    it "is answered as it is, the node it was handed" do
      [statement("Data.define(:a)"), statement("Struct.new(:a)"), statement("::Struct.new(:a, keyword_init: true)")]
        .each { |node| expect(resolve(node)).to equal(node) }
    end

    it "is nil for any other call or node" do
      expect(resolved("foo(1)", "Module.new", "Hash.new(:a)", "Struct.new", "x = 1")).to all(be_nil)
    end
  end

  describe "a `Class.new` wrapper" do
    it "unwinds to the factory call that is its one parent, through any number of wrappers" do
      wrapped = statement("Class.new(Struct.new(:a))")
      twice = statement("Class.new(Class.new(Data.define(:a)))")

      expect(resolve(wrapped)).to equal(wrapped.arguments.arguments.first)
      expect(resolve(twice)).to equal(twice.arguments.arguments.first.arguments.arguments.first)
    end

    it "is nil with no parent, with more than one, or with a parent that is no factory call" do
      expect(resolved("Class.new", "Class.new(Struct.new(:a), B)", "Class.new(Parent)", "Class.new(*parents)",
                      "Class.new(Class.new)")).to all(be_nil)
    end
  end

  describe "a block" do
    it "is allowed on the outermost call, and on that one alone" do
      expect(resolved("Struct.new(:a) { }", "Class.new(Struct.new(:a)) { }", "Struct.new(:a, &blk)"))
        .to eq(["Struct.new(:a) { }", "Struct.new(:a)", "Struct.new(:a, &blk)"])
      expect(resolved("Class.new(Struct.new(:a) { })", "Class.new(Class.new(Struct.new(:a)) { })",
                      "Class.new(Class.new(Struct.new(:a) { }))", "Class.new(Struct.new(:a, &blk))")).to all(be_nil)
    end

    it "is allowed on no call when the caller declines the outermost one's" do
      expect(resolved("Struct.new(:a) { }", "Class.new(Struct.new(:a)) { }", "Class.new(Struct.new(:a), &blk)",
                      "Class.new(Struct.new(:a) { })", allow_outer_block: false)).to all(be_nil)
      expect(resolved("Struct.new(:a)", "Class.new(Data.define(:a))", allow_outer_block: false))
        .to eq(["Struct.new(:a)", "Data.define(:a)"])
    end
  end

  # What another file of `lib/` calls: `scope_indexer.rb` and `shared_walk_tables.rb`, at two sites each. A second
  # name here is a new way into the module.
  it "exposes the resolver alone, and no constant" do
    expect(described_class.singleton_methods(false)).to eq([:resolve_meta_factory_call])
    expect(described_class.constants(false)).to eq([])
  end

  it "leaves none of its 3 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(3)
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
  end

  it "calls nothing of the indexer" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/factory_call_resolver.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      node.name if node.is_a?(Prism::CallNode) && DeclarationFactSources.constant_name(node.receiver) == "ScopeIndexer"
    end

    expect(calls).to eq([])
  end

  # The four sites that call it, each through the table it feeds: the reader a member gets in the methods table
  # (`ScopeIndexer.record_meta_members`), the class a wrapped factory declares
  # (`ScopeIndexer.record_meta_new_constant?`), and the two member layouts (`SharedWalkTables`).
  it "is what the methods table, the declaration artifacts and the two layout tables ask" do
    root = Prism.parse("K = Class.new(Struct.new(:a))\nD = Class.new(Data.define(:b))\n").value
    scope = indexer.index(root, default_scope: Rigor::Scope.empty)[root]

    expect(indexer.build_methods_and_def_nodes(root).first.transform_values(&:keys)).to eq("K" => [:a], "D" => [:b])
    expect(scope.discovered_classes.keys).to eq(%w[K D])
    expect(scope.struct_member_layouts).to eq("K" => { members: [:a], keyword_init: false })
    expect(scope.data_member_layouts).to eq("D" => [:b])
  end

  # The module names `DeclarationWalk::Rules` and nothing of the indexer: with what it requires, it answers.
  it "loads and answers without the indexer" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/factory_call_resolver"
      resolver = Rigor::Inference::ScopeIndexer::FactoryCallResolver
      answers = ["Class.new(Struct.new(:a))", "Class.new(Struct.new(:a) { })", "foo"].map do |source|
        resolver.resolve_meta_factory_call(Prism.parse(source).value.statements.body.first)&.slice
      end
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), answers].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, ["Struct.new(:a)", nil, nil]]')
  end
end
