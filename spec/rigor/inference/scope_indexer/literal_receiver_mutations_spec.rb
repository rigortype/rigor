# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (U2) — `ScopeIndexer::LiteralReceiverMutations` is the #540 mutation census of one file. The examples
# hand `collect_literal_receiver_mutations` a parsed snippet and read the census back: no index is built and no
# scope evaluated, so the walk alone decides each row. What the two wideners make of the census is pinned in
# `scope_indexer_spec.rb` and `mutated_constant_census_spec.rb`, through `ScopeIndexer.index` and a run.
RSpec.describe Rigor::Inference::ScopeIndexer::LiteralReceiverMutations do
  def parse(source) = Prism.parse(source).value

  define_method(:census) { |source| described_class.collect_literal_receiver_mutations(parse(source)) }

  # The census with its empty tables left out, as plain Arrays.
  def recorded(source)
    census(source).reject { |_, table| table.empty? }.transform_values do |table|
      table.is_a?(Hash) ? table.transform_values(&:to_a) : table.to_a
    end
  end

  describe "the census" do
    it "answers four tables, each empty for a file that mutates nothing" do
      result = census("x = 1\n")

      expect(result).to eq({ constants: Set[], cvars: {}, constant_elements: Set[], cvar_elements: {} })
    end

    it "answers the same for a root that is no node" do
      expect(described_class.collect_literal_receiver_mutations(nil))
        .to eq({ constants: Set[], cvars: {}, constant_elements: Set[], cvar_elements: {} })
    end

    it "answers an empty set for a class neither class-variable table names" do
      result = census("x = 1\n")

      expect([result[:cvars]["Absent"], result[:cvar_elements]["Absent"]]).to eq([Set[], Set[]])
    end
  end

  describe "what counts as a mutation" do
    it "records an index write in each form, an attribute write and a call of an in-place mutator" do
      source = "T[k] ||= 1\nU[k] &&= 1\nV[k] += 1\nW.name = 1\nX[k] = 1\nY << 1\nZ.push(1)\n"

      expect(recorded(source)).to eq(constants: %w[T U V W X Y Z])
    end

    it "records nothing for a read, an argument, a call that mutates nothing or a call with no receiver" do
      expect(recorded("T.size\nT[k]\nfoo(T)\nT.freeze\nx = T\npush(1)\n")).to eq({})
    end

    it "finds a mutation wherever it is written: an argument, an element, a value" do
      expect(recorded("foo(T << 1)\n[U << 2]\nx = (V << 3)\n")).to eq(constants: %w[T U V])
    end
  end

  # #708 review — the mutation census's two arms key on DIFFERENT TABLES. A `@@x` keys on the declaration
  # prefix because that is the join key with `ClassCvarCensus.build_class_cvar_index`, which derives its own
  # from the same `declaration_prefix`; a constant name resolves through the whole `Module.nesting` ladder,
  # whose outer rungs a rooted header drops from the prefix while Ruby keeps them. (The innermost entry is the
  # same value either way — the tables are what differ.) Threading one value for both is how the cvar arm
  # came to reference a parameter that no longer existed — a NameError
  # inside the discovery pre-pass, which the runner converts into a single `internal analyzer error` and
  # DISCARDS every real diagnostic in the file. Nothing in this repository mutates a `@@` receiver, so the
  # whole suite, the self-check and the corpus were all green over it.
  describe ".collect_literal_receiver_mutations" do
    it "records a class-variable index write under the class that owns it" do
      result = census("class A\n  @@t = {}\n  def self.put(k) = @@t[k] = 1\nend\n")
      expect(result[:cvars]).to eq({ "A" => Set[:@@t] })
    end

    it "records a class-variable shovel under a nested class" do
      result = census("module M\n  class A\n    @@l = []\n    def self.add(v) = @@l << v\n  end\nend\n")
      expect(result[:cvars]).to eq({ "M::A" => Set[:@@l] })
    end

    # The rooted arm, and the reason the two facts cannot share a parameter: the cvar keys by the RESET
    # class name while the constant below keys through the UNRESET nesting, from the same body.
    it "keys a rooted class's cvar by its reset name while its constant reaches the enclosing nesting" do
      result = census("module Outer\n  TABLE = {}\n  class ::Rooted\n    @@seen = {}\n    " \
                      "def self.fill(k) = @@seen[k] = 1\n    def self.mark(k) = TABLE[k] = 1\n  end\nend\n")
      expect(result[:cvars]).to eq({ "Rooted" => Set[:@@seen] })
      expect(result[:constants]).to include("Outer::TABLE")
    end

    it "records nothing for a class variable mutated at the top level" do
      expect(census("@@t = {}\n@@t[:k] = 1\n")[:cvars]).to be_empty
    end

    # #703 — the third arm of the alignment #690 made on the write side. `::Table::ROWS` names the top
    # level unconditionally, so the `Admin::Table::ROWS` a bare spelling would also reach is a different
    # constant and keeps its empty-shape fold. The two spellings are indistinguishable by name alone —
    # the strict render they share drops the root marker — so the exemption has to be taken from the
    # node, exactly as `constant_path_write_key` takes it.
    it "records only the rooted candidate for a rooted path receiver" do
      result = census("module Admin\n  def self.fill(k) = ::Table::ROWS[k] = 1\nend\n")
      expect(result[:constants]).to eq(Set["Table::ROWS"])
    end

    # Must-still-record: the unrooted spelling from the same body reaches every lexical candidate, which
    # is what the arm above may not be allowed to have taken away.
    it "still records every lexical candidate for an unrooted path receiver" do
      result = census("module Admin\n  def self.fill(k) = Table::ROWS[k] = 1\nend\n")
      expect(result[:constants]).to eq(Set["Admin::Table::ROWS", "Table::ROWS"])
    end

    # #3243 — a mutation of an element read off a constant or class variable records the read's root under the same
    # candidates, with its steps, and leaves the whole-name sets alone.
    it "records an element mutation's root and steps apart from the whole-name sets" do
      result = census("module Admin\n  def self.grow(i) = T.dig(0, :k).first[i] << 1\nend\n")
      key = Rigor::Inference::ScopeIndexer::MutatedElementCensus::KeyStep.new(:k)
      expect(result[:constant_elements]).to eq(Set[["Admin::T", [0, key, :first, :all]], ["T", [0, key, :first, :all]]])
      expect(result[:constants]).to be_empty
    end

    it "records a class variable's element mutation under its class, and none at the top level" do
      result = census("class A\n  def self.grow = @@n[0][-1] << 2\nend\n@@t[0] << 2\n")
      expect(result[:cvar_elements]).to eq({ "A" => Set[[:@@n, [0, -1]]] })
      expect(result[:cvars]).to be_empty
    end
  end

  describe "the candidates of a constant receiver" do
    it "names a bare constant under every entry of the nesting, innermost first, and then bare" do
      expect(recorded("module A; module B; def self.f = T << 1; end; end\n")).to eq(constants: %w[A::B::T A::T T])
    end

    it "gives a compact header one nesting entry, and keeps the entries around a rooted one" do
      expect(recorded("module A; class B::C; T << 1; end; end\n")).to eq(constants: %w[A::B::C::T A::T T])
      expect(recorded("module A; class ::R; T << 1; end; end\n")).to eq(constants: %w[R::T A::T T])
    end

    it "records nothing for a path it cannot render, whole or by element" do
      expect(recorded("foo::T << 1\nfoo::T[0] << 1\n")).to eq({})
    end

    it "records an element mutation of a path under its candidates, and of a rooted path under its name alone" do
      expect(recorded("module A; H::T[0] << 1; ::U[1] << 2; end\n"))
        .to eq(constant_elements: [["A::H::T", [0]], ["H::T", [0]], ["U", [1]]])
    end
  end

  describe "a class variable receiver" do
    it "records an attribute write, an index write and an or-write under the class" do
      expect(recorded("class C; @@c.name = 1; @@d[0] = 1; @@e[k] ||= 1; end\n"))
        .to eq(cvars: { "C" => %i[@@c @@d @@e] })
    end

    it "keys on the class around a method body, instance or singleton" do
      expect(recorded("class C; def m = @@v << 1; def self.s = @@w << 1; end\n")).to eq(cvars: { "C" => %i[@@v @@w] })
    end
  end

  describe "a `class <<` body" do
    it "keeps the class's prefix and nesting, and leaves a bare header beneath it ownerless" do
      source = <<~RUBY
        class C
          class << self
            T << 1
            @@v << 1
            class Hidden; @@w << 1; U << 1; end
            class ::Ro; @@r << 1; class In; @@i << 1; end; end
          end
        end
      RUBY

      expect(recorded(source))
        .to eq(constants: %w[C::T T C::U U], cvars: { "C" => [:@@v], "Ro" => [:@@r], "Ro::In" => [:@@i] })
    end

    it "walks the expression in the enclosing context" do
      expect(recorded("class C; class << (T << 1; self); end; end\n")).to eq(constants: %w[C::T T])
    end

    it "declines a `self::` header in an eval block of its own self" do
      expect(recorded("class C; class << self; class_eval { class self::D; @@v << 1; end }; end; end\n")).to eq({})
    end

    it "keeps its cref below an eval block: a bare header there is ownerless, a `self::` one is the receiver's" do
      source = <<~RUBY
        class C
          class << self
            X.class_eval { class E; @@e << 1; end; class self::D; @@d << 1; end }
          end
        end
      RUBY

      expect(recorded(source)).to eq(cvars: { "X::D" => [:@@d] })
    end

    it "declines an eval call's `self::` receiver below a bare header" do
      source = <<~RUBY
        class C
          class << self
            class Hidden; self::T.class_eval { class self::D; @@v << 1; end }; end
          end
        end
      RUBY

      expect(recorded(source)).to eq({})
    end
  end

  describe "an eval-family block" do
    it "anchors a `self::` header on the receiver: the class variable's key, and one entry on top of the nesting" do
      expect(recorded("module M; X.class_eval { class self::D; T << 1; @@v << 1; end }; end\n"))
        .to eq(constants: %w[X::D::T M::T T], cvars: { "X::D" => [:@@v] })
    end

    it "leaves the block of any other call the self around it" do
      expect(recorded("class C; foo { class self::D; @@v << 1; end }; end\n")).to eq(cvars: { "C::D" => [:@@v] })
    end

    it "leaves a mutation written straight in the block lexical" do
      expect(recorded("class C; X.class_eval { T << 1; @@v << 1 }; end\n"))
        .to eq(constants: %w[C::T T], cvars: { "C" => [:@@v] })
    end

    it "keeps the enclosing self for a bare receiver, and declines a `self::` header under a receiver it cannot name" do
      expect(recorded("class C; class_eval { class self::D; @@v << 1; end }; end\n")).to eq(cvars: { "C::D" => [:@@v] })
      expect(recorded("class C; foo.class_eval { class self::D; @@v << 1; end; @@c << 1 }; end\n"))
        .to eq(cvars: { "C" => [:@@c] })
    end

    it "walks the receiver and the arguments in the enclosing context" do
      expect(recorded("(T << 1).class_eval((U << 2)) { }\n")).to eq(constants: %w[T U])
    end
  end

  describe "a constant write that creates a class" do
    it "gives the block the class the write names as its self, and leaves its own mutations lexical" do
      source = "module W; K = Class.new { class self::D; @@v << 1; end; T << 1; @@k << 1 }; end\n"

      expect(recorded(source)).to eq(constants: %w[W::T T], cvars: { "W::K::D" => [:@@v], "W" => [:@@k] })
    end

    it "inside an eval block, anchors the block of a `self::` target on the receiver" do
      expect(recorded("X.class_eval { self::S = Class.new { class self::D; @@v << 1; end } }\n"))
        .to eq(cvars: { "X::S::D" => [:@@v] })
    end

    it "does so in each spelling of the write" do
      source = "K ||= Class.new { class self::D; @@a << 1; end }\nP::Q = Class.new { class self::D; @@b << 1; end }\n" \
               "P::R ||= Class.new { class self::D; @@c << 1; end }\n"

      expect(recorded(source)).to eq(cvars: { "K::D" => [:@@a], "P::Q::D" => [:@@b], "P::R::D" => [:@@c] })
    end

    it "walks the factory call's arguments in the enclosing context" do
      expect(recorded("K = Class.new((T << 1)) { }\n")).to eq(constants: %w[T])
    end

    it "under `class <<`, gives the block of a bare write a self nothing names, and of a rooted path write its name" do
      source = <<~RUBY
        class C
          class << self
            K = Class.new { class self::I; @@k << 1; end }
            ::R = Class.new { class self::J; @@j << 1; end; class Bare; @@b << 1; end }
          end
        end
      RUBY

      expect(recorded(source)).to eq(cvars: { "R::J" => [:@@j] })
    end
  end

  describe "a factory call that is written to no constant" do
    it "gives the block a self nothing names" do
      expect(recorded("Class.new { class self::D; @@v << 1; end }\n")).to eq({})
      expect(recorded("Struct.new(:a) { class self::D; @@v << 1; end }\n")).to eq({})
    end

    it "keeps the `class <<` cref below its block: a bare header there is ownerless" do
      expect(recorded("class C; class << self; Class.new { class E; @@e << 1; end }; end; end\n")).to eq({})
    end

    it "walks one with no block as any other call" do
      expect(recorded("Class.new((T << 1))\nx = Struct.new(:a)\n")).to eq(constants: %w[T])
    end

    it "walks its arguments and its block's own mutations in the enclosing context" do
      expect(recorded("class C; Class.new((T << 1)) { U << 1; @@u << 1 }; end\n"))
        .to eq(constants: %w[C::T T C::U U], cvars: { "C" => [:@@u] })
    end
  end

  it "exposes the census alone, and no constant of its own" do
    expect(described_class.singleton_methods(false)).to eq([:collect_literal_receiver_mutations])
    expect(described_class.constants).to be_empty
  end

  it "leaves none of its 11 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(11)
    expect(functions.select { |name| Rigor::Inference::ScopeIndexer.respond_to?(name, true) }).to eq([])
  end

  # The module reads `EMPTY_NESTING` through `ScopeIndexer`'s own name, which `scope_indexer.rb` binds: the file
  # requires what else it names, and its entry answers only once the indexer has loaded.
  it "loads without the indexer, with what it names, and cannot answer until the indexer binds the empty nesting" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/literal_receiver_mutations"
      indexer = Rigor::Inference::ScopeIndexer
      named = [defined?(Rigor::Inference::MutationWidening::SHAPE_MUTATORS), defined?(indexer::MutatedElementCensus),
               defined?(Rigor::Inference::DeclarationWalk::Rules), defined?(Rigor::Source::ConstantPath),
               Prism::ProgramNode.method_defined?(:rigor_each_child)]
      answer = begin
        indexer::LiteralReceiverMutations.collect_literal_receiver_mutations(Prism.parse("T << 1").value)
      rescue NameError => e
        e.name
      end
      print [indexer.respond_to?(:index), named, answer].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, ["constant", "constant", "constant", "constant", true], :EMPTY_NESTING]')
  end
end
