# frozen_string_literal: true

require "spec_helper"
require "delegate"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (U3) — `ScopeIndexer::PublishedConstantIvars` is the #667 census of the instance variables whose seed
# is a copy of a constant the project published. The examples hand `seed_published_constant_ivars` a parsed snippet
# and a scope whose discovery index already names the published constants and the class-ivar seeds, as it does when
# `ScopeIndexer.index` reaches this pass, and read the table off the scope it answers: no index is built and no body
# evaluated. `spec/rigor/analysis/cross_file_value_constant_spec.rb` pins what a run makes of the table.
RSpec.describe Rigor::Inference::ScopeIndexer::PublishedConstantIvars do
  let(:combinator) { Rigor::Type::Combinator }
  # A class-ivar table that seeds every ivar asked of it with a constant.
  let(:any_constant) { Hash.new(combinator.constant_of(:production)) }

  def scope_with(published: Set["MODE"], ivars: {})
    scope = Rigor::Scope.empty
    scope.with_discovery(scope.discovery.with(published_constant_names: published, class_ivars: ivars))
  end

  def seed(source, scope) = described_class.seed_published_constant_ivars(scope, Prism.parse(source).value)

  # The table the pass seeds over `source`, where each class of `classes` seeds a constant for every ivar.
  def seeded(source, *classes)
    scope = scope_with(ivars: classes.to_h { |name| [name, any_constant] })
    seed(source, scope).discovery.published_constant_ivars.transform_values(&:to_a)
  end

  describe "the scope it answers" do
    it "carries the table on its discovery index, frozen, and leaves the scope it was handed as it was" do
      scope = scope_with(ivars: { "A" => any_constant })
      answered = seed("class A; LIMIT = 3; def initialize; @mode = MODE; end; end\n", scope)
      table = answered.discovery.published_constant_ivars

      expect(table).to eq({ "A" => Set[:@mode] })
      expect([table, table.fetch("A")]).to all(be_frozen)
      expect(answered.published_constant_ivars_for("A")).to eq(Set[:@mode])
      expect(scope.discovery.published_constant_ivars).to be_empty
    end

    # The internal spec's "nothing-published shortcut": the file is not walked, so the scope is asked for no seed.
    it "is the scope it was handed when the project published nothing, asked for no class's seeds" do
      scope = Class.new(SimpleDelegator) do
        attr_reader :asked

        def class_ivars_for(name)
          (@asked ||= []) << name
          __getobj__.class_ivars_for(name)
        end
      end.new(scope_with(published: Set[], ivars: { "A" => any_constant }))

      expect(seed("class A; def initialize; @mode = MODE; end; end\n", scope)).to equal(scope)
      expect(scope.asked).to be_nil
    end

    it "is the scope it was handed when the file seeds no ivar from a published constant" do
      scope = scope_with(ivars: { "A" => any_constant })

      expect(seed("class A; def initialize; @mode = 1; end; end\n", scope)).to equal(scope)
    end

    it "is the scope it was handed for a root that is no node" do
      scope = scope_with

      expect(described_class.seed_published_constant_ivars(scope, nil)).to equal(scope)
    end
  end

  describe "the writes it records" do
    it "records a write whose value reads a published constant, bare or by path, and no other" do
      source = "class A; def initialize; @mode = MODE; @path = Cfg::MODE; @one = 1; @unpublished = LOCAL; end; end\n"

      expect(seeded(source, "A")).to eq("A" => %i[@mode @path])
    end

    it "records only an ivar whose class-ivar seed is a constant" do
      scope = scope_with(ivars: { "A" => { :@mode => combinator.constant_of(:production),
                                           :@wide => combinator.nominal_of("Symbol") } })
      answered = seed("class A; def initialize; @mode = MODE; @wide = MODE; @unseeded = MODE; end; end\n", scope)

      expect(answered.discovery.published_constant_ivars).to eq({ "A" => Set[:@mode] })
    end

    it "records nothing outside a class, whatever the seeds hold under the empty name" do
      expect(seeded("@top = MODE\ndef m = (@in_def = MODE)\n", "")).to eq({})
    end

    it "does not look inside the value of a write" do
      expect(seeded("class A; def m = (@outer = (@inner = MODE)); end\n", "A")).to eq({})
    end
  end

  describe "the class a write belongs to" do
    it "is the qualified name of the class around it, in the body, a method or a block" do
      source = "module N; class A; @body = MODE; def m = (@in_def = MODE); def b = foo { @in_block = MODE }; end; end\n"

      expect(seeded(source, "N::A", "A")).to eq("N::A" => %i[@body @in_def @in_block])
    end

    it "is none for a write in a singleton method" do
      expect(seeded("class A; def self.s = (@s = MODE); def i = (@i = MODE); end\n", "A")).to eq("A" => [:@i])
    end

    it "is none in a `class <<` body, whose expression belongs to the class around it" do
      source = "class A; class << (@in_expression = MODE; self); def m = (@in_def = MODE); @in_body = MODE; end; end\n"

      expect(seeded(source, "A")).to eq("A" => [:@in_expression])
    end

    it "under `class <<`, is none below a bare header, and starts again at a rooted one" do
      source = <<~RUBY
        class A
          class << self
            class Hidden; def m = (@h = MODE); end
            class ::R; def m = (@r = MODE); class In; def m = (@i = MODE); end; end
          end
        end
      RUBY

      expect(seeded(source, "A", "Hidden", "A::Hidden", "R", "R::In", "In")).to eq("R" => [:@r], "R::In" => [:@i])
    end
  end

  describe "an eval-family block under `class <<`" do
    it "keeps the cref: a bare header in the block is ownerless, the block's own writes are the receiver's" do
      source = <<~RUBY
        class A
          class << self
            X.class_eval { class E; def m = (@e = MODE); end; def n = (@x = MODE) }
          end
        end
      RUBY

      expect(seeded(source, "A", "X", "E", "A::E", "X::E")).to eq("X" => [:@x])
    end

    it "gives the block of a `self::` receiver below a bare header to no class" do
      source = "class A; class << self; class Hidden; self::T.class_eval { @t = MODE }; end; end; end\n"

      expect(seeded(source, "A", "T", "A::T", "Hidden", "A::Hidden")).to eq({})
    end
  end

  describe "an eval-family block" do
    it "gives its writes to the receiver, and anchors a `self::` header there" do
      source = "X.class_eval { def m = (@x = MODE); @b = MODE; class self::D; def m = (@d = MODE); end }\n"

      expect(seeded(source, "X", "X::D", "D")).to eq("X" => %i[@x @b], "X::D" => [:@d])
    end

    it "walks the receiver and the arguments in the enclosing context" do
      source = "class A; (@receiver = MODE).class_eval(@argument = MODE) { def m = (@x = MODE) }; end\n"

      expect(seeded(source, "A")).to eq("A" => %i[@receiver @argument])
      expect(seeded("X.class_eval { foo.class_eval(@argument = MODE) { } }\n", "X")).to eq("X" => [:@argument])
    end

    it "keeps the enclosing self for a bare receiver, and gives the block of a receiver it cannot name to no class" do
      expect(seeded("class A; class_eval { def m = (@x = MODE) }; end\n", "A")).to eq("A" => [:@x])
      expect(seeded("X.class_eval { class_eval { def m = (@y = MODE) } }\n", "X")).to eq("X" => [:@y])
      expect(seeded("class A; foo.class_eval { def m = (@x = MODE) }; end\n", "A")).to eq({})
    end
  end

  describe "a constant write that creates a class" do
    it "gives the block's writes to the class the write names, and anchors a `self::` header there" do
      source = "module W; K = Class.new { def m = (@k = MODE); class self::D; def m = (@d = MODE); end }; end\n"

      expect(seeded(source, "W", "W::K", "W::K::D", "K", "D")).to eq("W::K" => [:@k], "W::K::D" => [:@d])
    end

    it "inside an eval block, names the class of a `self::` target under the receiver" do
      expect(seeded("X.class_eval { self::S = Class.new { def m = (@s = MODE) } }\n", "X", "X::S", "S"))
        .to eq("X::S" => [:@s])
    end

    it "does so in each spelling of the write" do
      source = "K ||= Class.new { def m = (@a = MODE) }\nP::Q = Class.new { def m = (@b = MODE) }\n" \
               "P::R ||= Class.new { def m = (@c = MODE) }\n"

      expect(seeded(source, "K", "P::Q", "P::R")).to eq("K" => [:@a], "P::Q" => [:@b], "P::R" => [:@c])
    end

    it "walks the factory call's arguments in the enclosing context" do
      source = "class A; K = Class.new(foo(@argument = MODE)) { def m = (@k = MODE) }; end\n"

      expect(seeded(source, "A", "A::K")).to eq("A" => [:@argument], "A::K" => [:@k])
      expect(seeded("X.class_eval { K = Class.new(foo(@argument = MODE)) { } }\n", "X", "K", "X::K"))
        .to eq("X" => [:@argument])
    end

    it "under `class <<`, gives the block of a bare write to no class, and that of a rooted path write to its class" do
      source = <<~RUBY
        class A
          class << self
            K = Class.new { def m = (@k = MODE) }
            ::R = Class.new { def m = (@r = MODE); class Bare; def m = (@b = MODE); end }
          end
        end
      RUBY

      expect(seeded(source, "A", "K", "A::K", "R", "Bare", "A::Bare", "R::Bare")).to eq("R" => [:@r])
    end
  end

  it "exposes the seed alone, and no constant of its own" do
    expect(described_class.singleton_methods(false)).to eq([:seed_published_constant_ivars])
    expect(described_class.constants).to be_empty
  end

  it "leaves none of its 8 functions on ScopeIndexer, public or private" do
    functions = described_class.private_instance_methods(false)

    expect(functions.size).to eq(8)
    expect(functions.select { |name| Rigor::Inference::ScopeIndexer.respond_to?(name, true) }).to eq([])
  end

  # The module reads none of the indexer's constants: with what it requires, it answers. `Scope` needs the bundle,
  # which the child does not have, so the probe hands it a stand-in that answers what the pass asks of a scope.
  it "loads and answers without the indexer" do
    probe = <<~RUBY
      require "rigor/inference/scope_indexer/published_constant_ivars"
      discovery = Struct.new(:published_constant_ivars) { def with(**members) = self.class.new(*members.values) }
      scope = Struct.new(:discovery) do
        def published_constant_names = ["MODE"]
        def published_constant?(name) = name == "MODE"
        def class_ivars_for(_name) = Hash.new(Rigor::Type::Combinator.constant_of(:production))
        def with_discovery(discovery) = self.class.new(discovery)
      end
      root = Prism.parse("class A; def m = (@mode = MODE); X.class_eval { @x = MODE }; class << self; @own = MODE; end; end")
      table = Rigor::Inference::ScopeIndexer::PublishedConstantIvars
              .seed_published_constant_ivars(scope.new(discovery.new({})), root.value).discovery.published_constant_ivars
      print [Rigor::Inference::ScopeIndexer.respond_to?(:index), table].inspect
    RUBY
    out, err, status = RubyRun.capture("-I", File.join(DeclarationFactSources::REPO_ROOT, "lib"), "-e", probe)

    expect(status).to be_success, err
    expect(out).to eq('[false, {"A" => Set[:@mode], "X" => Set[:@x]}]')
  end
end
