# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Issue #2936 — a rendered union drops a plain nominal member that is a strict subclass of another member.
RSpec.describe "sig-gen union subsumption" do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def rendered(source, method_name = :m)
    lib = File.join(tmpdir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "sub.rb"), source)
    configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
    candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
    candidates.find { |c| c.method_name == method_name }.rbs
  end

  def body_returning(expr, declared_line = "")
    "class Sub\n#{declared_line}  def m(f, g) = #{expr}\nend\n"
  end

  it "collapses a subclass into its superclass" do
    expect(rendered(body_returning("f ? StandardError.new : ArgumentError.new")))
      .to eq("def m: (untyped, untyped) -> StandardError")
  end

  it "collapses the subclass of a nil-able union and keeps nil" do
    expect(rendered(body_returning("f ? StandardError.new : (g ? ArgumentError.new : nil)")))
      .to eq("def m: (untyped, untyped) -> (StandardError | nil)")
  end

  it "collapses a three-level chain to the root" do
    src = "class Sub\n  def m(f, g) = f ? Exception.new : (g ? StandardError.new : ArgumentError.new)\nend\n"
    expect(rendered(src)).to eq("def m: (untyped, untyped) -> Exception")
  end

  it "keeps siblings" do
    expect(rendered(body_returning("f ? ArgumentError.new : TypeError.new")))
      .to match(/-> \((ArgumentError \| TypeError|TypeError \| ArgumentError)\)\z/)
  end

  it "leaves the guards' verdict alone: a declared Exception still classifies as a tighter return" do
    lib = File.join(tmpdir, "lib")
    sig = File.join(tmpdir, "sig")
    FileUtils.mkdir_p([lib, sig])
    File.write(File.join(sig, "sub.rbs"), "class Sub\n  def m: (untyped f) -> Exception\nend\n")
    File.write(File.join(lib, "sub.rb"), body_returning("f ? StandardError.new : ArgumentError.new").sub("(f, g)", "(f)"))
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => [lib], "signature_paths" => [sig])
    )
    candidate = Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run.find { |c| c.method_name == :m }
    expect([candidate.classification, candidate.rbs])
      .to eq([Rigor::SigGen::Classification::TIGHTER_RETURN, "def m: (untyped f) -> StandardError"])
  end

  describe "#collapse_subsumed_members" do
    let(:generator) do
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [tmpdir]))
      Rigor::SigGen::Generator.new(configuration: configuration, paths: [tmpdir]).tap do |g|
        g.instance_variable_set(:@environment, Rigor::Environment.default)
      end
    end

    def nominal(name, *args) = Rigor::Type::Nominal.new(name, args)

    def collapse(*members)
      generator.send(:collapse_subsumed_members, Rigor::Type::Combinator.union(*members))
    end

    it "keeps a generic pair, which is invariant" do
      pair = [nominal("Array", nominal("Integer")), nominal("Array", nominal("Numeric"))]
      expect(collapse(*pair).members).to match_array(pair)
    end

    it "keeps a generic subclass beside its generic superclass" do
      pair = [nominal("Array", nominal("Integer")), nominal("Enumerable", nominal("Integer"))]
      expect(collapse(*pair).members).to match_array(pair)
    end

    it "drops a class that includes a module member" do
      expect(collapse(nominal("String"), nominal("Comparable"))).to eq(nominal("Comparable"))
    end

    it "keeps a literal beside its own class" do
      union = collapse(Rigor::Type::Combinator.constant_of(1), nominal("Integer"))
      expect(union.members.size).to eq(2)
    end
  end

  it "keeps an undecidable project class pair" do
    src = "class Sub\n  def m(f) = f ? Zed.new : Yed.new\nend\nclass Zed; end\nclass Yed < Zed; end\n"
    expect(rendered(src)).to eq("def m: (untyped) -> (Yed | Zed)")
  end
end
