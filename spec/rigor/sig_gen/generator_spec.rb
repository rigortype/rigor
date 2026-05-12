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
  end

  describe "explicit-return union (post-dogfood body-typer enhancement)" do
    it "unions an explicit `return value` with the implicit-return expression" do
      src = "class Box\n  def m(flag)\n    return 1 if flag\n    \"end\"\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs.split(" -> ").last.split(" | ").sort).to eq(['"end"', "1"])
    end

    it "treats bare `return` as `nil`" do
      src = "class Box\n  def m(flag)\n    return if flag\n    \"end\"\n  end\nend\n"
      path = write_fixture("lib/box.rb", src)

      candidate = generator(paths: [path]).run.find { |c| c.method_name == :m }

      expect(candidate.rbs.split(" -> ").last.split(" | ").sort).to eq(['"end"', "nil"])
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
end
