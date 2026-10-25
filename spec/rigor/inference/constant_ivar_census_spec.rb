# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

require "rigor/configuration"

# Issue #2291 — the ADR-58 class-ivar census ran before the file's constant table was seeded, so `@q = LIT` in one
# method read `Dynamic[top]` in every other, and `rigor sig-gen` skipped `def q = @q` while emitting `def g = LIT`.
# A write whose value is a constant read now takes the type the constant's write binds, unless the file may rebind
# that constant (`ScopeIndexer::ConstantIvarValue`).
RSpec.describe "the ADR-58 ivar census types a write from an in-source constant (#2291)" do
  def census(source, class_name, ivar)
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    index[program].class_ivars_for(class_name)[ivar]&.describe
  end

  def k_census(body, ivar = :@x) = census("class K\n#{body}\nend\n", "K", ivar)

  describe "a credited write" do
    it "takes a bare constant's type" do
      expect(k_census("LIT = [:a, :b].freeze\ndef initialize = @x = LIT")).to eq("[:a, :b]")
    end

    it "resolves the constant lexically through an enclosing namespace" do
      source = "module M\nX = { a: 1 }.freeze\nclass K\ndef initialize = @x = X\nend\nend\n"

      expect(census(source, "M::K", :@x)).to eq("{ a: 1 }")
    end

    it "resolves a constant path" do
      source = "module M\nX = 1\nend\nclass K\ndef initialize = @x = M::X\nend\n"

      expect(census(source, "K", :@x)).to eq("1")
    end

    it "takes a constant a sibling method mutates as the widened type a method body reads" do
      body = "LIT = [1]\ndef initialize = @x = LIT\ndef add = LIT << 2"

      expect(k_census(body)).to eq("Dynamic[Array[Dynamic[top]]]")
    end
  end

  describe "a declined write keeps the census's ordinary typing" do
    it "declines a constant assigned twice" do
      expect(k_census("LIT = 1\nLIT = 2\ndef initialize = @x = LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant an operator write rebinds" do
      expect(k_census("LIT = 1\nLIT ||= 2\ndef initialize = @x = LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant a multiple assignment rebinds" do
      expect(k_census("LIT = 1\nLIT, = [2]\ndef initialize = @x = LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant a const_set names" do
      expect(k_census("LIT = 1\nconst_set(:LIT, 2)\ndef initialize = @x = LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant a remove_const names" do
      expect(k_census("LIT = 1\ndef self.reset = remove_const(\"LIT\")\ndef initialize = @x = LIT"))
        .to eq("Dynamic[top]")
    end

    it "declines every constant when a const_set names a computed name" do
      expect(k_census("LIT = 1\ndef self.set(n) = const_set(n, 2)\ndef initialize = @x = LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant path whose base is not a constant" do
      expect(k_census("LIT = 1\ndef initialize = @x = self.class::LIT")).to eq("Dynamic[top]")
    end

    it "declines a constant nothing defines" do
      expect(k_census("def initialize = @x = MISSING")).to eq("Dynamic[top]")
    end
  end

  describe "rigor sig-gen over the ivar" do
    around do |example|
      Dir.mktmpdir("rigor-constant-ivar-") { |dir| Dir.chdir(dir) { example.run } }
    end

    def emitted(paths)
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => paths))
      Rigor::SigGen::Generator.new(configuration: configuration, paths: paths).run
                              .select { |c| c.classification == Rigor::SigGen::Classification::NEW_METHOD }
                              .to_h { |c| [c.method_name, c.rbs] }
    end

    it "emits a reader and a predicate over an ivar a constant seeds" do
      FileUtils.mkdir_p("lib")
      File.write("lib/k.rb", <<~RUBY)
        require "set"
        class K
          LIT = Set[[:a, :b]].freeze
          ARR = [[:a, :b]].freeze
          def initialize = @q = LIT
          def q = @q
          def initialize2; @r = ARR; end
          def r = @r
          def g = LIT
          def has?(k) = @q.include?(k)
        end
      RUBY

      expect(emitted(["lib/k.rb"]).slice(:q, :r, :g, :has?)).to eq(
        q: "def q: () -> Set[untyped]",
        r: "def r: () -> ([[:a, :b]] | nil)",
        g: "def g: () -> Set[untyped]",
        has?: "def has?: (untyped) -> (false | true)"
      )
    end

    # Guard: a constant another file assigns stays out of reach, as it is for a method returning it (#2300).
    it "does not reach a constant another file assigns" do
      FileUtils.mkdir_p("lib")
      File.write("lib/consts.rb", "class K\n  LIT = [:a].freeze\nend\n")
      File.write("lib/k.rb", "class K\n  def initialize = @q = LIT\n  def q = @q\n  def g = LIT\nend\n")

      expect(emitted(["lib"]).keys & %i[q g]).to eq([])
    end
  end
end
