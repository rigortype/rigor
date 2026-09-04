# frozen_string_literal: true

require "spec_helper"
require "rigor/analysis/reachability/graph"
require "rigor/analysis/reachability/scan"
require "rigor/reflection"

# ADR-102 — Graph resolution mirrors `Reflection.resolve_constant_type`'s candidate order.
# The two walks are separate implementations (this one is name-level and needs no types), so
# this spec pins them to the same answers on shared fixtures (#625).
RSpec.describe Rigor::Analysis::Reachability::Graph do
  def make_decl(fqn, path: "lib/decl.rb", line: 1, superclass: nil, includes: [])
    Rigor::Analysis::Reachability::Scan::Declaration.new(
      fqn: fqn, path: path, line: line, superclass: superclass, includes: includes
    )
  end

  def make_graph(declarations, references: [], roots: [])
    described_class.new(declarations: declarations, references: references, root_fqns: roots)
  end

  describe "#resolve" do
    it "resolves a bare name through lexical nesting innermost first" do
      decls = [make_decl("A::B::C"), make_decl("A::C"), make_decl("C")]
      graph = make_graph(decls)
      expect(graph.send(:resolve, "C", %w[A B])).to eq("A::B::C")
      expect(graph.send(:resolve, "C", ["A"])).to eq("A::C")
      expect(graph.send(:resolve, "C", [])).to eq("C")
    end

    it "resolves through ancestor scopes before bare name" do
      decls = [
        make_decl("Sub", superclass: "Base"),
        make_decl("Base"),
        make_decl("Base::KEY"),
        make_decl("KEY")
      ]
      graph = make_graph(decls)
      expect(graph.send(:resolve, "KEY", ["Sub"])).to eq("Base::KEY")
    end

    it "peels member constants when resolving" do
      decls = [make_decl("Holder")]
      graph = make_graph(decls)
      expect(graph.send(:resolve, "Holder::EMPTY", [])).to eq("Holder")
    end

    describe "rooted references (#625)" do
      it "skips lexical nesting and resolves to the top-level declaration" do
        decls = [make_decl("Foo"), make_decl("MyApp::Foo")]
        graph = make_graph(decls)

        expect(graph.send(:resolve, "Foo", ["MyApp"], rooted: true)).to eq("Foo")
        expect(graph.send(:resolve, "Foo", ["MyApp"], rooted: false)).to eq("MyApp::Foo")
      end

      it "skips ancestor scopes when rooted" do
        decls = [
          make_decl("Sub", superclass: "Base"),
          make_decl("Base"),
          make_decl("Base::KEY")
        ]
        graph = make_graph(decls)

        expect(graph.send(:resolve, "KEY", ["Sub"], rooted: true)).to be_nil
        expect(graph.send(:resolve, "KEY", ["Sub"], rooted: false)).to eq("Base::KEY")
      end

      it "returns nil when only the nested shadow exists" do
        decls = [make_decl("MyApp::Foo")]
        graph = make_graph(decls)

        expect(graph.send(:resolve, "Foo", ["MyApp"], rooted: true)).to be_nil
        expect(graph.send(:resolve, "Foo", ["MyApp"], rooted: false)).to eq("MyApp::Foo")
      end

      it "peels member segments when rooted" do
        decls = [make_decl("Foo"), make_decl("MyApp::Foo")]
        graph = make_graph(decls)

        expect(graph.send(:resolve, "Foo::BAR", ["MyApp"], rooted: true)).to eq("Foo")
      end
    end
  end

  describe "agreement with Reflection.resolve_constant_type pin (#625)" do
    # Mirrors the fixtures in spec/rigor/reflection_spec.rb "rooted references (#614)"
    def shadowed_reflection_scope
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        in_source_constants: {
          "Rails" => Rigor::Type::Combinator.constant_of(:toplevel),
          "MyApp::Rails" => Rigor::Type::Combinator.constant_of(:nested)
        }
      )
      Rigor::Scope.empty
                  .with_self_type(Rigor::Type::Combinator.nominal_of("MyApp"))
                  .with_discovery(index)
    end

    def shadowed_graph
      decls = [make_decl("Rails"), make_decl("MyApp::Rails"), make_decl("MyApp")]
      make_graph(decls)
    end

    it "both agree that rooted resolves to top-level Rails inside MyApp" do
      reflection_hit = Rigor::Reflection.resolve_constant_type("Rails", scope: shadowed_reflection_scope, rooted: true)
      expect(reflection_hit).to eq(Rigor::Type::Combinator.constant_of(:toplevel))

      graph_hit = shadowed_graph.send(:resolve, "Rails", ["MyApp"], rooted: true)
      expect(graph_hit).to eq("Rails")
    end

    it "both agree that unrooted resolves to the shadow MyApp::Rails inside MyApp" do
      reflection_hit = Rigor::Reflection.resolve_constant_type("Rails", scope: shadowed_reflection_scope, rooted: false)
      expect(reflection_hit).to eq(Rigor::Type::Combinator.constant_of(:nested))

      graph_hit = shadowed_graph.send(:resolve, "Rails", ["MyApp"], rooted: false)
      expect(graph_hit).to eq("MyApp::Rails")
    end

    it "both agree that rooted returns nil when only the shadow exists" do
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        in_source_constants: { "MyApp::Rails" => Rigor::Type::Combinator.constant_of(:nested) }
      )
      scope = Rigor::Scope.empty
                          .with_self_type(Rigor::Type::Combinator.nominal_of("MyApp"))
                          .with_discovery(index)
      expect(Rigor::Reflection.resolve_constant_type("Rails", scope: scope, rooted: true)).to be_nil

      graph = make_graph([make_decl("MyApp::Rails"), make_decl("MyApp")])
      expect(graph.send(:resolve, "Rails", ["MyApp"], rooted: true)).to be_nil
    end

    def inheriting_reflection_scope(in_source)
      discovered = {
        "Sub" => Rigor::Type::Combinator.singleton_of("Sub"),
        "Base" => Rigor::Type::Combinator.singleton_of("Base")
      }
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        in_source_constants: in_source,
        discovered_classes: discovered,
        discovered_superclasses: { "Sub" => "Base" }
      )
      Rigor::Scope.empty
                  .with_self_type(Rigor::Type::Combinator.nominal_of("Sub"))
                  .with_discovery(index)
    end

    def inheriting_graph(extra_decls = [])
      decls = [
        make_decl("Sub", superclass: "Base"),
        make_decl("Base")
      ] + extra_decls
      make_graph(decls)
    end

    it "both agree on skipping ancestor constants when rooted" do
      pinned = Rigor::Type::Combinator.constant_of(42)
      scope = inheriting_reflection_scope({ "Base::KEY" => pinned })
      expect(Rigor::Reflection.resolve_constant_type("KEY", scope: scope, rooted: true)).to be_nil
      expect(Rigor::Reflection.resolve_constant_type("KEY", scope: scope)).to eq(pinned)

      graph = inheriting_graph([make_decl("Base::KEY")])
      expect(graph.send(:resolve, "KEY", ["Sub"], rooted: true)).to be_nil
      expect(graph.send(:resolve, "KEY", ["Sub"], rooted: false)).to eq("Base::KEY")
    end

    it "both agree on resolving genuinely top-level-only constants" do
      pinned = Rigor::Type::Combinator.constant_of("top-level")
      scope = inheriting_reflection_scope({ "ONLY_TOPLEVEL" => pinned })
      expect(Rigor::Reflection.resolve_constant_type("ONLY_TOPLEVEL", scope: scope, rooted: true)).to eq(pinned)
      expect(Rigor::Reflection.resolve_constant_type("ONLY_TOPLEVEL", scope: scope)).to eq(pinned)

      graph = inheriting_graph([make_decl("ONLY_TOPLEVEL")])
      expect(graph.send(:resolve, "ONLY_TOPLEVEL", ["Sub"], rooted: true)).to eq("ONLY_TOPLEVEL")
      expect(graph.send(:resolve, "ONLY_TOPLEVEL", ["Sub"], rooted: false)).to eq("ONLY_TOPLEVEL")
    end
  end

  describe "reachability report with rooted references (#625)" do
    it "attributes a rooted reference to the top-level declaration instead of the shadow" do
      declarations = [
        make_decl("Foo", path: "lib/foo.rb"),
        make_decl("MyApp", path: "lib/myapp.rb"),
        make_decl("MyApp::Foo", path: "lib/myapp/foo.rb"),
        make_decl("MyApp::Caller", path: "lib/myapp/caller.rb")
      ]
      reference = Rigor::Analysis::Reachability::Scan::Reference.new(
        as_written: "Foo", nesting: %w[MyApp Caller].freeze, from: "MyApp::Caller",
        role: :production, path: "lib/myapp/caller.rb", line: 2, rooted: true
      )
      report = make_graph(declarations, references: [reference], roots: ["MyApp::Caller"]).report

      # Top-level Foo is reached via ::Foo
      expect(report.candidates.map(&:fqn)).not_to include("Foo")
      # Shadowed MyApp::Foo is unreached and therefore reported as candidate
      expect(report.candidates.map(&:fqn)).to include("MyApp::Foo")
    end
  end
end
