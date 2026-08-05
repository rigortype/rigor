# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def generator(paths:, signature_paths: nil)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => paths,
        "signature_paths" => signature_paths
      ).compact
    )
    described_class.new(configuration: configuration, paths: paths)
  end

  describe "#run on a fresh class without RBS" do
    it "classifies a literal-returning def as new-method with the inferred return" do
      path = write_fixture("lib/widget.rb", "class Widget\n  def n\n    42\n  end\nend\n")

      candidates = generator(paths: [path]).run
      new_methods = candidates.select { |c| c.classification == Rigor::SigGen::Classification::NEW_METHOD }

      expect(new_methods.map { |c| [c.class_name, c.method_name, c.rbs] })
        .to eq([["Widget", :n, "def n: () -> 42"]])
    end

    it "resolves a directory path by recursively globbing every nested *.rb file" do
      write_fixture("lib/a/one.rb", "class One\n  def n\n    1\n  end\nend\n")
      write_fixture("lib/b/two.rb", "class Two\n  def n\n    2\n  end\nend\n")
      write_fixture("lib/README.md", "not ruby")
      lib_dir = File.join(tmpdir, "lib")

      candidates = generator(paths: [lib_dir]).run
      new_methods = candidates.select { |c| c.classification == Rigor::SigGen::Classification::NEW_METHOD }

      expect(new_methods.map(&:class_name)).to contain_exactly("One", "Two")
    end

    it "renders required-positional parameters as untyped per ADR-5 clause 2" do
      path = write_fixture("lib/adder.rb", <<~RUBY)
        class Adder
          def two(a, b)
            "constant"
          end
        end
      RUBY

      candidates = generator(paths: [path]).run

      method = candidates.find { |c| c.method_name == :two }
      expect(method.rbs).to eq(%(def two: (untyped, untyped) -> "constant"))
    end

    it "skips defs with optional / keyword / block / rest params via sig.skipped.complex-shape" do
      path = write_fixture("lib/complex.rb", <<~RUBY)
        class Complex
          def opt(a = 1); a; end
          def kw(a:); a; end
          def rest(*a); a; end
          def blk(&b); b; end
        end
      RUBY

      candidates = generator(paths: [path]).run

      skipped = candidates.select { |c| c.classification == Rigor::SigGen::Classification::SKIPPED }
      expect(skipped.map(&:skip_reason)).to all(eq(:complex_shape))
      expect(skipped.map(&:method_name)).to contain_exactly(:opt, :kw, :rest, :blk)
    end

    it "skips defs whose inferred return collapses to untyped via sig.skipped.untyped-return" do
      path = write_fixture("lib/untyped.rb", <<~RUBY)
        class Untyped
          def calls
            unknown_helper(1, 2)
          end
        end
      RUBY

      candidates = generator(paths: [path]).run

      method = candidates.find { |c| c.method_name == :calls }
      expect(method.classification).to eq(Rigor::SigGen::Classification::SKIPPED)
      expect(method.skip_reason).to eq(:untyped_return)
    end

    it "skips top-level / DSL-block defs (no enclosing nameable class)" do
      path = write_fixture("lib/toplevel.rb", <<~RUBY)
        def at_root
          1
        end
      RUBY

      candidates = generator(paths: [path]).run

      expect(candidates).to be_empty
    end

    it "covers both `def self.foo` singleton methods and instance methods (slice 4)" do
      src = "class Holder\n  def self.cls_method; 1; end\n  def instance_method; \"x\"; end\nend\n"
      path = write_fixture("lib/singleton.rb", src)

      candidates = generator(paths: [path]).run.select do |c|
        c.classification == Rigor::SigGen::Classification::NEW_METHOD
      end

      expect(candidates.map { |c| [c.method_name, c.kind] }).to contain_exactly(
        %i[cls_method singleton], %i[instance_method instance]
      )
    end
  end

  describe "namespace kind + module_function tracking (gap #3 a/b)" do
    it "records `:module` vs `:class` for every walked segment" do
      src = "module Outer\n  class Inner\n    def m; 1; end\n  end\nend\n"
      path = write_fixture("lib/x.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.namespace_kinds["Outer"]).to eq(:module)
      expect(candidate.namespace_kinds["Outer::Inner"]).to eq(:class)
    end

    it "emits `def self?.name` for methods inside a module_function region" do
      src = "module Helper\n  module_function\n  def go; \"ok\"; end\nend\n"
      path = write_fixture("lib/x.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :go }

      expect(candidate.rbs).to eq(%(def self?.go: () -> "ok"))
    end

    it "does not flag methods declared BEFORE module_function as module_function" do
      src = "module Helper\n  def before_mf; 1; end\n  module_function\n  def after_mf; 2; end\nend\n"
      path = write_fixture("lib/x.rb", src)

      run = generator(paths: [path]).run
      before = run.find { |c| c.method_name == :before_mf }
      after = run.find { |c| c.method_name == :after_mf }

      expect(before.rbs).to start_with("def before_mf:")
      expect(after.rbs).to start_with("def self?.after_mf:")
    end

    it "does not propagate module_function across class boundaries inside a module" do
      src = "module Helper\n  module_function\n  class Inner\n    def m; 1; end\n  end\nend\n"
      path = write_fixture("lib/x.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs).to start_with("def m:")
    end

    it "does not treat the named form `module_function :name` as the bare region toggle" do
      # `module_function :go` names a SPECIFIC method rather than opening a region; this walker only tracks the
      # bare-form region toggle, so a subsequent def is unaffected (stays a regular instance method).
      src = "module Helper\n  module_function :go\n  def go; \"ok\"; end\nend\n"
      path = write_fixture("lib/x.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :go }

      expect(candidate.rbs).to start_with("def go:")
    end
  end

  describe "Const = Data.define / Struct.new shell recognition (gap #3 e)" do
    it "records `Const = Data.define(...)` as a class shell carried on every candidate" do
      src = <<~RUBY
        module Outer
          Shell = Data.define(:a, :b)
          def self.go; 1; end
        end
      RUBY
      path = write_fixture("lib/shells.rb", src)

      run = generator(paths: [path]).run
      candidate = run.find { |c| c.method_name == :go }

      expect(candidate.class_shells).to include("Outer::Shell")
      expect(candidate.namespace_kinds["Outer::Shell"]).to eq(:class)
    end

    it "records `Const = Struct.new(...)` as a class shell" do
      src = <<~RUBY
        module Outer
          Shell = Struct.new(:a)
          def self.go; 1; end
        end
      RUBY
      path = write_fixture("lib/shells.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :go }

      expect(candidate.class_shells).to include("Outer::Shell")
    end

    it "does not register unrelated Const = <expr> assignments" do
      src = <<~RUBY
        module Outer
          Other = [1, 2, 3]
          NotAShell = Set.new
          def self.go; 1; end
        end
      RUBY
      path = write_fixture("lib/shells.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :go }

      expect(candidate.class_shells).to be_empty
    end
  end

  # Issue #227. Before this, a `Const = Data.define(...) do ... end` assignment produced output that was WRONG,
  # not merely thin: the block body's methods were attributed to the enclosing namespace (which then rendered as
  # a `class` even when it was a `module`), and the members, the constructors, and the `::Data` ancestry were all
  # absent — so the class the file actually defines never appeared.
  describe "Data.define / Struct.new member and constructor emission (#227)" do
    def run_for(source, **)
      path = write_fixture("lib/shapes.rb", source)
      generator(paths: [path], **).run
    end

    def rbs_for(candidates, class_name)
      candidates.select { |c| c.class_name == class_name }.filter_map(&:rbs)
    end

    it "attributes a block body's defs to the constant, not the enclosing namespace" do
      candidates = run_for(<<~RUBY)
        module Outer
          Shell = Data.define(:a) do
            def label
              "x"
            end
          end
        end
      RUBY

      label = candidates.find { |c| c.method_name == :label }
      expect(label.class_name).to eq("Outer::Shell")
      expect(label.namespace_kinds["Outer"]).to eq(:module)
    end

    it "declares the members, both constructors, and the ::Data ancestry" do
      candidates = run_for("module Outer\n  Shell = Data.define(:a, :b)\nend\n")

      expect(rbs_for(candidates, "Outer::Shell")).to eq(
        ["def a: () -> untyped",
         "def b: () -> untyped",
         "def self.new: (a: untyped, b: untyped) -> instance | (untyped a, untyped b) -> instance",
         "def self.[]: (a: untyped, b: untyped) -> instance | (untyped a, untyped b) -> instance"]
      )
      expect(candidates.first.class_superclasses["Outer::Shell"]).to eq("::Data")
    end

    it "declares writers and optional constructor positions for a Struct" do
      candidates = run_for("Point = Struct.new(:x)\n")

      expect(rbs_for(candidates, "Point")).to eq(
        ["def x: () -> untyped",
         "def x=: (untyped) -> untyped",
         "def self.new: (?x: untyped) -> instance | (?untyped x) -> instance",
         "def self.[]: (?x: untyped) -> instance | (?untyped x) -> instance"]
      )
      expect(candidates.first.class_superclasses["Point"]).to eq("::Struct[untyped]")
    end

    it "drops the positional constructor form under keyword_init: true" do
      candidates = run_for("Point = Struct.new(:x, keyword_init: true)\n")

      expect(rbs_for(candidates, "Point")).to include("def self.new: (?x: untyped) -> instance")
    end

    # The named-subclass form already got its `class` keyword from the source; what it never got was the computed
    # superclass (`record_superclass` refuses to guess at a CallNode) or the members.
    it "covers the `class X < Data.define(...)` form too" do
      candidates = run_for("class Named < Data.define(:id)\nend\n")

      expect(rbs_for(candidates, "Named")).to include("def id: () -> untyped")
      expect(candidates.first.class_superclasses["Named"]).to eq("::Data")
    end

    it "leaves a member the class itself already declares to the user" do
      write_fixture("sig/shapes.rbs", <<~RBS)
        class Point < ::Data
          attr_reader x: Integer
        end
      RBS
      candidates = run_for("Point = Data.define(:x, :y)\n", signature_paths: [File.join(tmpdir, "sig")])

      expect(rbs_for(candidates, "Point")).to include("def y: () -> untyped")
      expect(rbs_for(candidates, "Point")).not_to include("def x: () -> untyped")
    end

    # `::Data.new: () -> bot` answers the `.new` lookup for every value class. Deferring to it as if it were the
    # user's own declaration is what would leave the arity false positive in place.
    it "still declares .new when only the inherited ::Data one is visible" do
      write_fixture("sig/shapes.rbs", "class Point < ::Data\nend\n")
      candidates = run_for("Point = Data.define(:x)\n", signature_paths: [File.join(tmpdir, "sig")])

      expect(rbs_for(candidates, "Point")).to include(
        "def self.new: (x: untyped) -> instance | (untyped x) -> instance"
      )
    end

    it "types members from `.new` observations under --params=observed" do
      path = write_fixture("lib/shapes.rb", "Point = Data.define(:x, :y)\n")
      observations = {
        ["Point", :initialize] => [
          Rigor::SigGen::ObservedCall.new(keyword: { x: Rigor::Type::Combinator.constant_of("a") }),
          [Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of(2)]
        ]
      }
      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)

      candidates = described_class.new(configuration: config, paths: [path], observations: observations).run

      expect(candidates.select { |c| c.class_name == "Point" }.filter_map(&:rbs))
        .to include('def x: () -> ("a" | 1)', "def y: () -> 2")
    end

    # A one-argument `Point.new(attrs)` shim must not type member 0 as that argument's type: the arities disagree,
    # so the call site says nothing about which member each position feeds.
    it "ignores positional observations whose arity does not cover the member list" do
      path = write_fixture("lib/shapes.rb", "Point = Data.define(:x, :y)\n")
      observations = { ["Point", :initialize] => [[Rigor::Type::Combinator.constant_of("attrs")]] }
      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)

      candidates = described_class.new(configuration: config, paths: [path], observations: observations).run

      expect(candidates.select { |c| c.class_name == "Point" }.filter_map(&:rbs))
        .to include("def x: () -> untyped")
    end
  end

  describe "superclass capture (ADR-14)" do
    it "records a plain-constant superclass on every candidate" do
      src = <<~RUBY
        class Base
          def b; 1; end
        end
        class Child < Base
          def c; 2; end
        end
      RUBY
      path = write_fixture("lib/hier.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :c }

      expect(candidate.class_superclasses["Child"]).to eq("Base")
    end

    it "records a qualified-constant-path superclass verbatim" do
      src = <<~RUBY
        module Scm
          module Adapters
            class GitAdapter < AbstractAdapter
              def rev; 1; end
            end
          end
        end
      RUBY
      path = write_fixture("lib/git.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :rev }

      expect(candidate.class_superclasses["Scm::Adapters::GitAdapter"]).to eq("AbstractAdapter")
    end

    it "records a NAMESPACED-constant-path superclass verbatim (ConstantPathNode superclass)" do
      # Distinct from the class's own qualified name above: here the SUPERCLASS itself is a `Foo::Bar` path
      # (`qualified_constant_path`'s recursive `Prism::ConstantPathNode` branch).
      src = <<~RUBY
        class Widget < Acme::Base
          def go; 1; end
        end
      RUBY
      path = write_fixture("lib/widget.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :go }

      expect(candidate.class_superclasses["Widget"]).to eq("Acme::Base")
    end

    # A computed superclass is un-representable in RBS and guessing would misfold. The `Data.define` / `Struct.new`
    # pair is the exception the ADR-48 layouts let us resolve exactly (#227) — everything else stays unrecorded.
    it "does not record a computed superclass it cannot resolve" do
      src = <<~RUBY
        Base = Class.new
        class Point < Class.new(Base)
          def norm; 1; end
        end
      RUBY
      path = write_fixture("lib/point.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :norm }

      expect(candidate.class_superclasses).not_to have_key("Point")
    end

    it "records the synthesised ancestry of a `class X < Struct.new(...)`" do
      src = <<~RUBY
        class Point < Struct.new(:x, :y)
          def norm; 1; end
        end
      RUBY
      path = write_fixture("lib/point.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :norm }

      expect(candidate.class_superclasses["Point"]).to eq("::Struct[untyped]")
    end
  end

  describe "visibility-aware emission (post-dogfood)" do
    it "skips private methods by default" do
      src = "class Box\n  def public_one; \"x\"; end\n  private\n  def private_one; \"y\"; end\nend\n"
      path = write_fixture("lib/box.rb", src)

      methods = generator(paths: [path]).run.map(&:method_name)

      expect(methods).to eq([:public_one])
    end

    it "emits private methods when include_private: true is set" do
      src = "class Box\n  def public_one; \"x\"; end\n  private\n  def private_one; \"y\"; end\nend\n"
      path = write_fixture("lib/box.rb", src)

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      methods = described_class.new(configuration: config, paths: [path], include_private: true)
                               .run.map(&:method_name)

      expect(methods).to contain_exactly(:public_one, :private_one)
    end
  end

  describe "initialize exclusion (post-dogfood)" do
    it "skips `def initialize` (RBS inherits `Object#initialize`)" do
      src = "class Box\n  def initialize\n    @count = 0\n  end\n  def n; 1; end\nend\n"
      path = write_fixture("lib/box.rb", src)

      methods = generator(paths: [path]).run.map(&:method_name)

      expect(methods).to eq([:n])
    end

    it "does emit `def self.initialize` (singleton-side; not the constructor)" do
      src = "class Box\n  def self.initialize\n    \"x\"\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      methods = generator(paths: [path]).run

      expect(methods.map(&:method_name)).to eq([:initialize])
      expect(methods.first.kind).to eq(:singleton)
    end

    it "emits an `initialize` stub when the constructor takes arguments" do
      src = "class Box\n  def initialize(name)\n    @name = name\n  end\n  def n; 1; end\nend\n"
      path = write_fixture("lib/box.rb", src)

      init = generator(paths: [path]).run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq("def initialize: (untyped) -> void")
    end

    it "emits an `initialize` stub mirroring keyword-argument shape" do
      src = "class Box\n  def initialize(name:, opts: {})\n    @name = name\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      init = generator(paths: [path]).run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq("def initialize: (name: untyped, ?opts: untyped) -> void")
    end

    it "fills in observed keyword arg types in the stub when --params=observed is active" do
      src = "class Box\n  def initialize(name:, count: 0)\n    @name = name\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)
      observations = {
        ["Box", :initialize] => [
          Rigor::SigGen::ObservedCall.new(
            keyword: { name: Rigor::Type::Combinator.constant_of("Alice"),
                       count: Rigor::Type::Combinator.constant_of(42) }
          )
        ]
      }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      init = described_class.new(configuration: config, paths: [path], observations: observations)
                            .run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq(%(def initialize: (name: "Alice", ?count: 42) -> void))
    end

    it "fills in observed positional arg types in the stub" do
      src = "class Box\n  def initialize(name)\n    @name = name\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)
      observations = {
        ["Box", :initialize] => [
          Rigor::SigGen::ObservedCall.new(positional: [Rigor::Type::Combinator.constant_of("Alice")])
        ]
      }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      init = described_class.new(configuration: config, paths: [path], observations: observations)
                            .run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq(%(def initialize: ("Alice") -> void))
    end

    it "renders a `&block` constructor param as a valid RBS block AFTER the parens" do
      src = "class Box\n  def initialize(&block)\n    @block = block\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      init = generator(paths: [path]).run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq("def initialize: () ?{ (*untyped) -> untyped } -> void")
    end

    it "renders a `*args` constructor rest param as `*untyped`" do
      src = "class Box\n  def initialize(*args)\n    @args = args\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      init = generator(paths: [path]).run.find { |c| c.method_name == :initialize }

      expect(init.rbs).to eq("def initialize: (*untyped) -> void")
    end

    it "places the block suffix after a keyword-rest param (the mastodon `(**untyped) ?{ … }` shape)" do
      src = "class Box\n  def initialize(**opts, &block)\n    @opts = opts\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      init = generator(paths: [path]).run.find { |c| c.method_name == :initialize }

      # Regression: this used to emit `(**untyped, ?{ (?) -> void })`, which RBS rejects and which then
      # collapsed the whole `sig/` env build (the 2026-07-06 mastodon coverage note's `connection_pool` /
      # `elasticsearch` files). The block belongs after the parens.
      expect(init.rbs).to eq("def initialize: (**untyped) ?{ (*untyped) -> untyped } -> void")
      expect { RBS::Parser.parse_signature(RBS::Buffer.new(name: "x.rbs", content: "class C\n  #{init.rbs}\nend\n")) }
        .not_to raise_error
    end
  end

  describe "explicit-return union (post-dogfood body-typer enhancement)" do
    it "unions an explicit `return value` with the implicit-return expression" do
      src = "class Box\n  def m(flag)\n    return 1 if flag\n    \"end\"\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs.split(" -> ").last.delete("()").split(" | ").sort).to eq(['"end"', "1"])
    end

    it "treats bare `return` as `nil`" do
      src = "class Box\n  def m(flag)\n    return if flag\n    \"end\"\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs.split(" -> ").last.delete("()").split(" | ").sort).to eq(['"end"', "nil"])
    end

    it "does not credit returns from nested blocks / lambdas / inner defs" do
      src = <<~RUBY
        class Box
          def m
            [1].each { |i| return false }
            "end"
          end
        end
      RUBY
      path = write_fixture("lib/box.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs).to eq(%(def m: () -> "end"))
    end
  end

  describe "lenience-preserving guard (post-dogfood tighter? hardening)" do
    it "refuses to classify as tighter when the declared union loses a `nil` member" do
      write_fixture("sig/box.rbs", "class Box\n  def fetch: () -> String?\nend\n")
      path = write_fixture("lib/box.rb", "class Box\n  def fetch\n    \"hi\"\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :fetch }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "refuses to classify as tighter when the declared union loses a member and the INFERRED side is ALSO a Union" do
      # Distinct from the `String?` case above (there the inferred side is a bare Constant, never taking the
      # `Type::Union` branch of `loses_declared_union_member?`'s inferred-side dispatch). Here both sides are
      # Unions: declared `String | Integer | nil` vs. an inferred `String | Integer` that drops the `nil` arm.
      write_fixture("sig/box.rbs", "class Box\n  def fetch: () -> (String | Integer | nil)\nend\n")
      path = write_fixture(
        "lib/box.rb", "class Box\n  def fetch\n    rand < 0.5 ? \"hi\" : 1\n  end\nend\n"
      )

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :fetch }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "refuses to tighten Array[T] to a Tuple shape" do
      write_fixture("sig/box.rbs", "class Box\n  def each: () -> Array[Integer]\nend\n")
      path = write_fixture("lib/box.rb", "class Box\n  def each\n    [1, 2, 3]\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :each }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "refuses to tighten when the inferred Constant comes from a non-literal body expression" do
      write_fixture("sig/box.rbs", "class Box\n  def count: () -> Integer\nend\n")
      src = "class Box\n  def initialize; @items = []; end\n  def count; @items.size; end\nend\n"
      path = write_fixture("lib/box.rb", src)

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :count }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "DOES tighten when the body's last expression is a directly-authored literal" do
      write_fixture("sig/box.rbs", "class Box\n  def status: () -> Integer\nend\n")
      path = write_fixture("lib/box.rb", "class Box\n  def status\n    200\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :status }

      expect(method.classification).to eq(Rigor::SigGen::Classification::TIGHTER_RETURN)
      expect(method.rbs).to eq("def status: () -> 200")
    end

    it "refuses to tighten when an `untyped` type-arg would be replaced by a concrete form" do
      write_fixture("sig/box.rbs", "class Box\n  def to_h: () -> Hash[String, untyped]\nend\n")
      path = write_fixture("lib/box.rb", "class Box\n  def to_h\n    {\"k\" => 1}\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :to_h }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "refuses to tighten when a declared Nominal `untyped` type-arg would be replaced (non-HashShape carrier)" do
      # Distinct from the HashShape case above: `narrows_collection_to_shape?` never fires here (the inferred
      # value is itself a `Nominal[Array, …]`, not a literal-shape carrier), so this exercises
      # `replaces_untyped_type_arg?`'s own class_name/type_args comparison directly.
      write_fixture("sig/box.rbs", "class Box\n  def dup_ints: (Array[Integer] arr) -> Array[untyped]\nend\n")
      path = write_fixture(
        "lib/box.rb", "class Box\n  def dup_ints(arr)\n    arr.map { |x| x }\n  end\nend\n"
      )

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :dup_ints }

      expect(method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end
  end

  describe "#run when RBS already declares the method" do
    it "classifies an exact-match declaration as equivalent" do
      write_fixture("sig/widget.rbs", "class Widget\n  def n: () -> 42\nend\n")
      path = write_fixture("lib/widget.rb", "class Widget\n  def n\n    42\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      n_method = gen.run.find { |c| c.method_name == :n }

      expect(n_method.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "classifies a strict subtype as tighter-return and renders the inferred form" do
      write_fixture("sig/box.rbs", "class Box\n  def value: () -> Numeric\nend\n")
      path = write_fixture("lib/box.rb", "class Box\n  def value\n    42\n  end\nend\n")

      gen = generator(paths: [path], signature_paths: [File.join(tmpdir, "sig")])
      method = gen.run.find { |c| c.method_name == :value }

      expect(method.classification).to eq(Rigor::SigGen::Classification::TIGHTER_RETURN)
      expect(method.declared_return_rbs).to eq("Numeric")
      expect(method.rbs).to eq("def value: () -> 42")
    end
  end

  describe "#run on singleton methods (slice 4)" do
    it "emits `def self.foo: ...` for `def self.foo` defs" do
      path = write_fixture("lib/holder.rb", "class Holder\n  def self.factory\n    \"hi\"\n  end\nend\n")

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :factory }

      expect(candidate.kind).to eq(:singleton)
      expect(candidate.rbs).to eq(%(def self.factory: () -> "hi"))
    end

    it "treats `class << self; def foo; end` defs as singleton" do
      path = write_fixture("lib/holder.rb", <<~RUBY)
        class Holder
          class << self
            def helper
              42
            end
          end
        end
      RUBY

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :helper }

      expect(candidate.kind).to eq(:singleton)
      expect(candidate.rbs).to eq("def self.helper: () -> 42")
    end
  end

  describe "#run on attr_* declarations (slice 4)" do
    it "emits a long-form reader candidate for attr_reader against the ivar's accumulated type" do
      path = write_fixture("lib/box.rb", <<~RUBY)
        class Box
          def initialize
            @name = "hi"
          end
          attr_reader :name
        end
      RUBY

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :name }

      expect(candidate.kind).to eq(:instance)
      expect(candidate.rbs).to eq(%(def name: () -> "hi"))
    end

    it "emits reader + writer candidates for attr_accessor" do
      path = write_fixture("lib/box.rb", <<~RUBY)
        class Box
          def initialize
            @count = 0
          end
          attr_accessor :count
        end
      RUBY

      candidates = generator(paths: [path]).run.select { |c| %i[count count=].include?(c.method_name) }

      expect(candidates.map { |c| [c.method_name, c.rbs] }).to contain_exactly(
        [:count, "def count: () -> 0"],
        [:count=, "def count=: (0) -> 0"]
      )
    end

    it "skips attr_* whose ivar has no accumulated write (no known type)" do
      path = write_fixture("lib/box.rb", "class Box\n  attr_reader :empty_ivar\nend\n")

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :empty_ivar }

      expect(candidate.classification).to eq(Rigor::SigGen::Classification::SKIPPED)
      expect(candidate.skip_reason).to eq(:untyped_return)
    end
  end

  describe "#run with observations (--params=observed)" do
    it "renders observed argument types when an observation matches the method's required arity" do
      path = write_fixture("lib/box.rb", "class Box\n  def greet(name)\n    \"hi\"\n  end\nend\n")
      type = Rigor::Type::Combinator.constant_of("Alice")
      observations = { ["Box", :greet] => [[type], [Rigor::Type::Combinator.constant_of("Bob")]] }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :greet }

      expect(candidate.rbs).to eq(%(def greet: ("Alice" | "Bob") -> "hi"))
    end

    it "falls back to untyped when no observation matches the method's required arity" do
      path = write_fixture("lib/box.rb", "class Box\n  def add(a, b)\n    \"x\"\n  end\nend\n")
      type = Rigor::Type::Combinator.constant_of(42)
      observations = { ["Box", :add] => [[type]] }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :add }

      expect(candidate.rbs).to eq(%(def add: (untyped, untyped) -> "x"))
    end

    it "preserves distinct literal observations as a union" do
      path = write_fixture("lib/box.rb", "class Box\n  def m(x)\n    \"r\"\n  end\nend\n")
      observations = {
        ["Box", :m] => [
          [Rigor::Type::Combinator.constant_of("a")],
          [Rigor::Type::Combinator.constant_of("b")]
        ]
      }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :m }

      expect(candidate.rbs).to eq(%(def m: ("a" | "b") -> "r"))
    end

    it "renders multiple observed positional params comma-joined, each unioned independently" do
      path = write_fixture("lib/box.rb", "class Box\n  def add(a, b)\n    \"x\"\n  end\nend\n")
      observations = {
        ["Box", :add] => [
          [Rigor::Type::Combinator.constant_of(1), Rigor::Type::Combinator.constant_of("y")],
          [Rigor::Type::Combinator.constant_of(2), Rigor::Type::Combinator.constant_of("z")]
        ]
      }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :add }

      expect(candidate.rbs).to eq(%(def add: (1 | 2, "y" | "z") -> "x"))
    end

    # attr_reader + initialize-param observations
    #
    # When `--params=observed` is active and the observation scan sees `Person.new("Alice")`, the observed String type
    # flows through the ivar pre-pass fallback so that `attr_reader :name` can emit a concrete return type even though
    # the ivar pre-pass itself only sees `@name = name` with an untyped `name` parameter.
    it "resolves attr_reader type from initialize positional-param observations" do
      path = write_fixture("lib/person.rb", <<~RUBY)
        class Person
          def initialize(name)
            @name = name
          end
          attr_reader :name
        end
      RUBY

      observations = {
        ["Person", :initialize] => [
          [Rigor::Type::Combinator.constant_of("Alice")],
          [Rigor::Type::Combinator.constant_of("Bob")]
        ]
      }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :name }

      expect(candidate.classification).to eq(Rigor::SigGen::Classification::NEW_METHOD)
      expect(candidate.rbs).to eq(%(def name: () -> ("Alice" | "Bob")))
    end

    it "resolves attr_reader type from initialize keyword-param observations" do
      path = write_fixture("lib/point.rb", <<~RUBY)
        class Point
          def initialize(x:, y:)
            @x = x
            @y = y
          end
          attr_reader :x, :y
        end
      RUBY

      t_int  = Rigor::Type::Combinator.constant_of(0)
      t_str  = Rigor::Type::Combinator.constant_of("origin")
      obs    = Rigor::SigGen::ObservedCall.new(keyword: { x: t_int, y: t_str })
      observations = { ["Point", :initialize] => [obs] }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidates = described_class.new(configuration: config, paths: [path], observations: observations)
                                  .run.select { |c| %i[x y].include?(c.method_name) }
                                      .to_h { |c| [c.method_name, c.rbs] }

      expect(candidates[:x]).to eq("def x: () -> 0")
      expect(candidates[:y]).to eq(%(def y: () -> "origin"))
    end

    it "falls back to skipped when no observations exist for initialize" do
      path = write_fixture("lib/empty.rb", <<~RUBY)
        class Widget
          def initialize(label)
            @label = label
          end
          attr_reader :label
        end
      RUBY

      # observations for a different class — Widget gets nothing
      observations = { ["Other", :initialize] => [[Rigor::Type::Combinator.constant_of("x")]] }

      config = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      candidate = described_class.new(configuration: config, paths: [path], observations: observations)
                                 .run.find { |c| c.method_name == :label }

      expect(candidate.classification).to eq(Rigor::SigGen::Classification::SKIPPED)
      expect(candidate.skip_reason).to eq(:untyped_return)
    end
  end

  describe "#run output shape" do
    it "produces MethodCandidate records that round-trip through #to_h" do
      path = write_fixture("lib/round_trip.rb", "class RoundTrip\n  def m\n    \"x\"\n  end\nend\n")

      hash = generator(paths: [path]).run.first.to_h

      expect(hash).to include(
        file: path, class: "RoundTrip", method: "m", kind: "instance",
        classification: "new_method", rbs: %(def m: () -> "x")
      )
    end
  end

  # The output-validity guard. Both bugs that motivated it are fixed, so the trigger is stubbed at the render
  # step: what is pinned is the POLICY — an unparseable line never leaves the generator, it is demoted to a
  # skip and recorded as a Rigor defect. Emitting it would poison the consumer's whole file.
  describe "unparseable rendered RBS (SigGen::RbsValidity guard)" do
    it "demotes the method to :skipped and records it instead of emitting it" do
      path = write_fixture("lib/widget.rb", "class Widget\n  def n\n    42\n  end\nend\n")
      gen = generator(paths: [path])
      allow(gen).to receive(:render_rbs_line).and_return("def n: () -> { data-contrast: Integer }")

      candidate = gen.run.find { |c| c.method_name == :n }

      expect(candidate.classification).to eq(Rigor::SigGen::Classification::SKIPPED)
      expect(candidate.skip_reason).to eq(:unrenderable_rbs)
      expect(candidate.rbs).to be_nil

      expect(gen.unrenderable.size).to eq(1)
      recorded = gen.unrenderable.first
      expect(recorded.method_name).to eq(:n)
      expect(recorded.class_name).to eq("Widget")
      expect(recorded.error).to include("record key")
    end

    it "leaves a healthy run's record empty" do
      path = write_fixture("lib/widget.rb", "class Widget\n  def n\n    42\n  end\nend\n")
      gen = generator(paths: [path])
      expect(gen.run.map(&:method_name)).to include(:n)
      expect(gen.unrenderable).to be_empty
    end
  end
end
