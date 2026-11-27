# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::CensusScope` is the scope a census pre-pass types a body's rvalues under.
# The examples hand its two functions a scope and the prefix a census walk threads, and read the scope and the chain
# back. Three censuses ask for it: the class ivar index, the class-variable census and the typed constant walk, and
# the last three examples pin each of them through it.
RSpec.describe Rigor::Inference::ScopeIndexer::CensusScope do
  let(:combinator) { Rigor::Type::Combinator }
  let(:empty) { Rigor::Scope.empty }
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  # Issue #681 — a census walk never enters a body through `StatementEvaluator`, so nothing stamps the declaration's
  # `Module.nesting` on the scope it builds. The prefix the walk threads is the chain.
  describe ".census_body_scope" do
    it "answers a scope with the self type it is handed and the chain its prefix stands for" do
      instance = combinator.nominal_of("Admin::Census")
      nested = described_class.census_body_scope(empty, %w[Admin Census], instance)
      compact = described_class.census_body_scope(empty, %w[Admin::Census], instance)

      expect([nested.self_type, nested.lexical_nesting]).to eq([instance, %w[Admin::Census Admin]])
      expect([compact.self_type, compact.lexical_nesting]).to eq([instance, %w[Admin::Census]])
    end

    it "keeps the chain the scope already carries, which a header's entry threaded" do
      entered = empty.with_lexical_nesting(%w[X::Y])
      scope = described_class.census_body_scope(entered, %w[Admin Census], combinator.singleton_of("Admin::Census"))

      expect([scope.self_type.describe, scope.lexical_nesting]).to eq(["singleton(Admin::Census)", %w[X::Y]])
    end

    it "leaves the scope it is handed as it was" do
      scope = described_class.census_body_scope(empty, %w[A], combinator.nominal_of("A"))

      expect([scope.equal?(empty), empty.self_type, empty.lexical_nesting]).to eq([false, nil, nil])
    end
  end

  describe ".census_nesting" do
    it "answers the scope's own chain, and the prefix's for a scope with none and for no scope" do
      expect(described_class.census_nesting(empty.with_lexical_nesting(%w[X::Y]), %w[A B])).to eq(%w[X::Y])
      expect(described_class.census_nesting(empty, %w[A B])).to eq(%w[A::B A])
      expect(described_class.census_nesting(nil, %w[A B])).to eq(%w[A::B A])
    end

    it "reads a prefix one entry a header: a compact header is one, and no header is none" do
      expect(described_class.census_nesting(empty, %w[A::B C])).to eq(%w[A::B::C A::B])
      expect(described_class.census_nesting(empty, [])).to eq([])
    end
  end

  # What another file of `lib/` calls: the three censuses the first, the typed constant walk the second too.
  it "exposes its two functions, and no constant" do
    expect(described_class.singleton_methods(false).sort).to eq(%i[census_body_scope census_nesting])
    expect(described_class.constants(false)).to eq([])
  end

  it "leaves neither of its functions on ScopeIndexer" do
    functions = described_class.private_instance_methods(false)

    expect(functions.sort).to eq(%i[census_body_scope census_nesting])
    expect(functions.select { |name| indexer.respond_to?(name, true) }).to eq([])
  end

  # The #3318 cut-off counts the functions a moved cluster calls back in what stays. This one calls none: it asks
  # the declaration-context rules alone.
  it "calls nothing of the indexer, and one rule of the walk" do
    path = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor/inference/scope_indexer/census_scope.rb")
    calls = DeclarationFactSources.each_node(Prism.parse_file(path).value).filter_map do |node|
      receiver = DeclarationFactSources.constant_name(node.receiver) if node.is_a?(Prism::CallNode)
      [receiver, node.name] if receiver
    end

    expect(calls).to eq([["DeclarationWalk::Rules", :lexical_nesting_for_prefix]])
  end

  # The file names the rules alone and requires their file, so it answers alone as it does with the indexer loaded.
  # The scope it is handed here answers what the module asks of one and nothing else.
  it "loads without the indexer, with what it names, and answers as it does with it" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/census_scope"
      indexer = Rigor::Inference::ScopeIndexer
      scope = Struct.new(:self_type, :lexical_nesting) do
        def with_self_type(type) = self.class.new(type, lexical_nesting)
        def with_lexical_nesting(nesting) = self.class.new(self_type, nesting)
      end
      body = indexer::CensusScope.census_body_scope(scope.new(nil, nil), %w[A B], :self)
      print [indexer.respond_to?(:index), defined?(Rigor::Inference::DeclarationWalk::Rules), body.to_a,
             indexer::CensusScope.census_nesting(scope.new(nil, %w[X]), %w[A]),
             indexer::CensusScope.census_nesting(nil, [])].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, "constant", [:self, ["A::B", "A"]], ["X"], []]')
  end

  describe "its callers" do
    def parse(source) = Prism.parse(source).value

    # A scope that knows `Bar` at two depths, so a `Bar.new` rvalue says which chain it was typed under, and `M::C`,
    # so a path write through `C` says which chain its namespace was resolved through.
    def bars
      classes = %w[Bar M::Bar M::C].to_h { |name| [name, combinator.singleton_of(name)] }
      empty.with_discovery(empty.discovery.with(discovered_classes: classes))
    end

    def described(table) = table.transform_values { |entries| entries.transform_values(&:describe) }

    let(:source) do
      "module M\n  class C\n    def a; @a = Bar.new; @@a = Bar.new; end\n    A = Bar.new\n  end\nend\n" \
        "class M::D\n  def b; @b = Bar.new; @@b = Bar.new; end\n  B = Bar.new\nend\n"
    end

    it "is the scope the class ivar index types a def body under" do
      expect(described(indexer::ClassIvarIndex.build_class_ivar_index(parse(source), bars)))
        .to eq("M::C" => { :@a => "M::Bar" }, "M::D" => { :@b => "Bar" })
    end

    it "is the scope the class-variable census types a def body under" do
      expect(described(indexer::ClassCvarCensus.build_class_cvar_index(parse(source), bars)))
        .to eq("M::C" => { :@@a => "M::Bar" }, "M::D" => { :@@b => "Bar" })
    end

    it "is the scope the typed constant walk types a write under, and the chain it resolves a path write through" do
      table = indexer::ConstantTables.build_in_source_constants(parse("#{source}module M\n  C::X = 1\nend\n"), bars)

      expect(table.transform_values(&:describe)).to eq("M::C::A" => "M::Bar", "M::D::B" => "Bar", "M::C::X" => "1")
    end

    # Issue #3437 — the #667 instance-variable census is the fourth: it asks the truthiness guard about an rvalue
    # under the scope the class-ivar index typed it under.
    it "is called by those three modules and the published-constant ivar census alone, at nine sites" do
      root = File.join(DeclarationFactSources::REPO_ROOT, "lib/rigor")
      sites = Dir.glob("**/*.rb", base: root).sort.to_h do |path|
        calls = DeclarationFactSources.each_node(Prism.parse_file(File.join(root, path)).value).filter_map do |node|
          receiver = DeclarationFactSources.constant_name(node.receiver) if node.is_a?(Prism::CallNode)
          node.name if receiver == "CensusScope"
        end
        [path, calls]
      end

      expect(sites.reject { |_path, calls| calls.empty? }).to eq(
        "inference/scope_indexer/class_cvar_census.rb" => %i[census_body_scope census_body_scope],
        "inference/scope_indexer/class_ivar_index.rb" => %i[census_body_scope] * 4,
        "inference/scope_indexer/constant_tables.rb" => %i[census_body_scope census_nesting],
        "inference/scope_indexer/published_constant_ivars.rb" => %i[census_body_scope]
      )
    end
  end
end
