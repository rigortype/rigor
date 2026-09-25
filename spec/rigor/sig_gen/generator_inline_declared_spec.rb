# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# ADR-112 WD4 / #1076 — a member declared inline by `# @rbs` / `#:` is written to `sig/` by default, so the
# generated signature is a complete contract, and `sig_gen.inline_declared: skip` leaves every member the inline
# reader declares out of it, for a project whose Steep also reads the inline annotations.
RSpec.describe Rigor::SigGen::Generator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:source) do
    <<~RUBY
      class Greeter
        # @rbs name: String
        # @rbs return: String
        def greet(name)
          "Hello, " + name
        end

        #: () -> Integer
        def count
          1
        end

        # @rbs num: Float
        def pair(num)
          [num, num.to_s]
        end

        def plain
          "x"
        end
      end
    RUBY
  end

  after { FileUtils.remove_entry(tmpdir) }

  # `Configuration.new` never auto-wires `rigor-rbs-inline`, and the suite empties the plugin registry, so the
  # plugin is listed and registered by hand the way `generator_spec.rb`'s #995 example does.
  before do
    require "rigor-rbs-inline"
    Rigor::Plugin.register(Rigor::Plugin::RbsInline) unless Rigor::Plugin.registered_for("rbs-inline")
  end

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def run_generator(path, inline_declared: nil, sig: false)
    data = Rigor::Configuration::DEFAULTS.merge(
      "paths" => [path],
      "plugins" => [{ "gem" => "rigor-rbs-inline", "id" => "rbs-inline",
                      "config" => { "require_magic_comment" => false } }]
    )
    data["signature_paths"] = [File.join(tmpdir, "sig")] if sig
    data["sig_gen"] = { "inline_declared" => inline_declared } if inline_declared
    described_class.new(configuration: Rigor::Configuration.new(data), paths: [path]).run
  end

  def find(candidates, name)
    candidates.find { |c| c.method_name == name }
  end

  describe "by default (inline_declared: write)" do
    it "writes a fully declared member as its inline declaration, whatever the body infers" do
      candidates = run_generator(write_fixture("lib/greeter.rb", source))

      greet = find(candidates, :greet)
      count = find(candidates, :count)
      expect([greet.classification, greet.rbs])
        .to eq([Rigor::SigGen::Classification::NEW_METHOD, "def greet: (String name) -> String"])
      # The body proves `1`; the author wrote `Integer`, and the declaration is the contract that ships.
      expect([count.classification, count.rbs])
        .to eq([Rigor::SigGen::Classification::NEW_METHOD, "def count: () -> Integer"])
    end

    it "keeps the authored parameters and fills an unwritten return from the body" do
      pair = find(run_generator(write_fixture("lib/greeter.rb", source)), :pair)

      expect(pair.classification).to eq(Rigor::SigGen::Classification::NEW_METHOD)
      expect(pair.rbs).to eq("def pair: (Float num) -> [Float, String]")
    end

    it "leaves a member the author annotated nothing on to the ordinary proposal (#995)" do
      plain = find(run_generator(write_fixture("lib/greeter.rb", source)), :plain)

      expect(plain.classification).to eq(Rigor::SigGen::Classification::TIGHTER_RETURN)
      expect(plain.rbs).to eq(%(def plain: () -> "x"))
    end

    it "writes a declared member whose body types as untyped instead of skipping it" do
      path = write_fixture("lib/box.rb", <<~RUBY)
        class Box
          #: (untyped raw) -> String
          def load(raw)
            raw.fetch(:x)
          end
        end
      RUBY

      load = find(run_generator(path), :load)

      expect([load.classification, load.rbs])
        .to eq([Rigor::SigGen::Classification::NEW_METHOD, "def load: (untyped raw) -> String"])
    end

    it "carries a member annotation the author wrote inline, but not the reader's own markers" do
      path = write_fixture("lib/box.rb", <<~RUBY)
        class Box
          # @rbs %a{deprecated}
          # @rbs return: String
          def label
            "x"
          end

          # @rbs n: Integer
          def twice(n)
            n * 2
          end
        end
      RUBY

      candidates = run_generator(path)

      expect(find(candidates, :label).rbs_lines).to eq(["%a{deprecated}", "def label: () -> String"])
      expect(find(candidates, :twice).rbs_lines).to eq(["def twice: (Integer n) -> Integer"])
    end

    it "writes an inline-typed attribute from its declaration" do
      path = write_fixture("lib/person.rb", <<~RUBY)
        class Person
          attr_reader :name #: String

          def initialize(name)
            @name = name
          end
        end
      RUBY

      name = find(run_generator(path), :name)

      expect([name.classification, name.rbs])
        .to eq([Rigor::SigGen::Classification::NEW_METHOD, "def name: () -> String"])
    end

    it "classifies a member sig/ already mirrors as equivalent" do
      write_fixture("sig/greeter.rbs", <<~RBS)
        class Greeter
          def greet: (String name) -> String
        end
      RBS

      greet = find(run_generator(write_fixture("lib/greeter.rb", source), sig: true), :greet)

      expect(greet.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "proposes an inline update when sig/ holds a copy the inline declaration has since changed" do
      write_fixture("sig/greeter.rbs", <<~RBS)
        class Greeter
          def greet: (Symbol name) -> String
        end
      RBS

      greet = find(run_generator(write_fixture("lib/greeter.rb", source), sig: true), :greet)

      expect(greet.classification).to eq(Rigor::SigGen::Classification::INLINE_UPDATE)
      expect(greet.rbs).to eq("def greet: (String name) -> String")
      expect(greet.declared_rbs).to eq("def greet: (Symbol name) -> String")
    end

    it "proposes an inline update when sig/ lacks an annotation the inline declaration carries" do
      write_fixture("sig/box.rbs", "class Box\n  def label: () -> String\nend\n")
      path = write_fixture("lib/box.rb", <<~RUBY)
        class Box
          # @rbs %a{deprecated}
          # @rbs return: String
          def label
            "x"
          end
        end
      RUBY

      label = find(run_generator(path, sig: true), :label)

      expect(label.classification).to eq(Rigor::SigGen::Classification::INLINE_UPDATE)
    end
  end

  describe "an initialize whose parameters are annotated" do
    it "is written `-> void`, whatever the body's last expression is" do
      path = write_fixture("lib/conn.rb", <<~RUBY)
        class Conn
          # @rbs opts: Hash[Symbol, untyped]
          def initialize(opts)
            @timeout = opts[:timeout]
          end
        end
      RUBY

      init = find(run_generator(path), :initialize)

      expect([init.classification, init.rbs])
        .to eq([Rigor::SigGen::Classification::NEW_METHOD, "def initialize: (Hash[Symbol, untyped] opts) -> void"])
    end
  end

  # Review of #1422 (probe `f1`): with a parameter-only annotation the return is inferred, not authored, so it is
  # held to the ordinary proposal rules against `sig/`, and only the authored parameters can make the copy stale.
  describe "a mixed-provenance member sig/ already declares" do
    let(:chain) do
      <<~RUBY
        class Chain
          # @rbs x: Integer
          def c(x) = x.to_s.size

          # @rbs name: String
          def pair(name) = [name, name.to_s]
        end
      RUBY
    end

    def classify(sig)
      write_fixture("sig/chain.rbs", sig)
      run_generator(write_fixture("lib/chain.rb", chain), sig: true)
    end

    it "leaves a hand-widened return alone when the lenience guards say so" do
      pair = find(classify("class Chain\n  def pair: (String name) -> Array[String]\nend\n"), :pair)

      expect(pair.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "proposes a narrower inferred return as tighter-return, keeping the authored parameters" do
      c = find(classify("class Chain\n  def c: (Integer x) -> Numeric\nend\n"), :c)

      expect([c.classification, c.rbs, c.declared_return_rbs])
        .to eq([Rigor::SigGen::Classification::TIGHTER_RETURN, "def c: (Integer x) -> Integer", "Numeric"])
    end

    it "updates the authored parameters and keeps the return sig/ has" do
      pair = find(classify("class Chain\n  def pair: (Symbol name) -> Array[String]\nend\n"), :pair)

      expect([pair.classification, pair.rbs])
        .to eq([Rigor::SigGen::Classification::INLINE_UPDATE, "def pair: (String name) -> Array[String]"])
    end
  end

  # Review round 2 of #1422 (probes `m2c` / `m2d`): the inline side and the `sig/` side are paired slot by slot.
  # A shape they do not share is refused, and a slot rbs-inline defaulted (`untyped b`, `?{ (?) -> untyped }`)
  # never drives or overwrites anything.
  describe "an inline declaration against a sig/ member of another shape, or with defaulted slots" do
    let(:source) do
      <<~RUBY
        class P
          # @rbs name: String
          def overl(name) = [name, name]

          # @rbs a: String
          def two(a, b) = [a, a]

          # @rbs name: String
          def blk(name, &blk) = [name, name]

          # @rbs name: String
          def over_same(name) = name.size
        end
      RUBY
    end
    let(:m2_sig) do
      <<~RBS
        class P
          def overl: (String name) -> Array[String] | (Integer name) -> Integer
          def two: (String a, Integer b) -> Array[String]
          def blk: (String name) { (String) -> void } -> Array[String]
          def over_same: (String name) -> Integer | (Integer name) -> Integer
        end
      RBS
    end

    def classify(sig)
      write_fixture("sig/p.rbs", sig)
      run_generator(write_fixture("lib/p.rb", source), sig: true)
    end

    it "refuses a member whose overload count differs, and infers no return for it" do
      candidates = classify(m2_sig)

      %i[overl over_same].each do |name|
        candidate = find(candidates, name)
        expect([candidate.classification, candidate.skip_reason, candidate.rbs])
          .to eq([Rigor::SigGen::Classification::SKIPPED, :inline_shape_mismatch, nil])
      end
    end

    it "keeps a sig/ parameter and block the author did not annotate, and proposes nothing" do
      candidates = classify(m2_sig)

      expect(find(candidates, :two).classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
      expect(find(candidates, :blk).classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
    end

    it "updates only the annotated parameter, keeping the unannotated one and the block from sig/" do
      candidates = classify(<<~RBS)
        class P
          def two: (Symbol a, Integer b) -> Array[String]
          def blk: (Symbol name) { (String) -> void } -> Array[String]
        end
      RBS

      expect(find(candidates, :two).rbs).to eq("def two: (String a, Integer b) -> Array[String]")
      expect(find(candidates, :blk).rbs).to eq("def blk: (String name) { (String) -> void } -> Array[String]")
    end

    it "refuses a member whose parameter list has a different shape" do
      pair = find(classify("class P\n  def two: (String a) -> Array[String]\nend\n"), :two)

      expect(pair.skip_reason).to eq(:inline_shape_mismatch)
    end
  end

  it "treats a sig/ copy that only spells names absolutely as current" do
    write_fixture("sig/greeter.rbs", "class Greeter\n  def greet: (::String name) -> ::String\nend\n")

    greet = find(run_generator(write_fixture("lib/greeter.rb", source), sig: true), :greet)

    expect(greet.classification).to eq(Rigor::SigGen::Classification::EQUIVALENT)
  end

  # Review of #1422 (probe `g_new`): sig-gen writes no class type parameters, so a `class Box` header in `sig/`
  # beside an inline `class Box[T]` would fail the definition build of Box and of every class mentioning it.
  describe "a class made generic by an inline declaration" do
    let(:box) do
      <<~RUBY
        # @rbs generic T
        class Box
          #: () -> T
          def get = @v

          class Inner
            def n = 1
          end
        end

        class User
          #: () -> Box[Integer]
          def box = Box.new
        end
      RUBY
    end

    it "writes nothing that would open it, nested classes included, and the rest as usual" do
      candidates = run_generator(write_fixture("lib/box.rb", box))

      skipped = candidates.select { |c| c.skip_reason == :inline_generic_class }.map(&:method_name)
      expect(skipped).to contain_exactly(:get, :n)
      expect(find(candidates, :box).rbs).to eq("def box: () -> Box[Integer]")
    end

    # Review round 2 (probe `g5`): rbs accepts `class Box[U]` beside an inline `Box[T]`, so a copied `-> T`
    # would name a parameter the `sig/` declaration does not bind.
    it "writes nothing into a sig/ declaration that names the type parameters otherwise" do
      write_fixture("sig/box.rbs", "class Box[U]\nend\n")

      get = find(run_generator(write_fixture("lib/box.rb", box), sig: true), :get)

      expect(get.skip_reason).to eq(:inline_generic_class)
    end

    it "writes the members into a declaration sig/ already carries" do
      write_fixture("sig/box.rbs", "class Box[T]\nend\n")
      path = write_fixture("lib/box.rb", box)

      get = Dir.chdir(tmpdir) { find(run_generator(path, sig: true), :get) }

      expect([get.classification, get.rbs]).to eq([Rigor::SigGen::Classification::NEW_METHOD, "def get: () -> T"])
    end
  end

  describe "with inline_declared: skip" do
    it "skips every member the inline reader declares, annotated or not, and nothing else" do
      path = write_fixture("lib/greeter.rb", source)
      other = write_fixture("lib/other.rb", "class Other\n  def n\n    1\n  end\nend\n")
      candidates = run_generator(path, inline_declared: "skip") + run_generator(other, inline_declared: "skip")

      skipped = candidates.select { |c| c.skip_reason == :inline_declared }.map(&:method_name)
      expect(skipped).to contain_exactly(:greet, :count, :pair, :plain)
      expect(find(candidates, :n).classification).to eq(Rigor::SigGen::Classification::NEW_METHOD)
    end
  end
end
