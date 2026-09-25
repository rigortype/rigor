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
