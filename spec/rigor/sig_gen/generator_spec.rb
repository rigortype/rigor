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
        .to eq([["Widget", :n, "def n: () -> Integer"]])
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
      expect(method.rbs).to eq("def two: (untyped, untyped) -> String")
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

    it "skips def self.foo singleton-side methods in the MVP" do
      path = write_fixture("lib/singleton.rb", <<~RUBY)
        class Holder
          def self.cls_method
            1
          end

          def instance_method
            "x"
          end
        end
      RUBY

      candidates = generator(paths: [path]).run

      expect(candidates.map(&:method_name)).to eq([:instance_method])
    end
  end

  describe "#run when RBS already declares the method" do
    it "classifies an exact-match declaration as equivalent" do
      write_fixture("sig/widget.rbs", "class Widget\n  def n: () -> Integer\nend\n")
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
      expect(method.rbs).to eq("def value: () -> Integer")
    end
  end

  describe "#run output shape" do
    it "produces MethodCandidate records that round-trip through #to_h" do
      path = write_fixture("lib/round_trip.rb", "class RoundTrip\n  def m\n    \"x\"\n  end\nend\n")

      hash = generator(paths: [path]).run.first.to_h

      expect(hash).to include(
        file: path, class: "RoundTrip", method: "m", kind: "instance",
        classification: "new_method", rbs: "def m: () -> String"
      )
    end
  end
end
