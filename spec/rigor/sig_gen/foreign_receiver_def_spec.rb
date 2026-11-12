# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Issue #3155 — a `def` whose receiver is not the lexical self (`def String.q` in `class L`, `def A.z` in `A::B`,
# `def o.q` on a local or a constant holding an object, `def self.n` in a `class << self` body) defines no method of
# the enclosing class. sig-gen and the ScopeIndexer filed it on the instance side anyway (or on the class's singleton
# side), so it overwrote a same-named instance def in the proposal and in the call-site read.
RSpec.describe "a def whose receiver is not the lexical self (#3155)", type: :runner do
  def proposals(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, body| File.write(File.join(lib, name), body) }
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
      Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
                              .reject { |c| c.classification == :skipped }
                              .map { |c| [c.class_name, c.rbs] }
                              .sort
    end
  end

  def assert_type_mismatches(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics.filter_map do |diagnostic|
      diagnostic.message if diagnostic.message.start_with?("assert_type mismatch")
    end
  end

  def return_mismatches(source, rbs)
    diagnostics = analyze(files: { "code.rb" => source }, sig: { "code.rbs" => rbs }).diagnostics
    diagnostics.select { |d| d.rule.to_s == "def.return-type-mismatch" }.map(&:line)
  end

  # The meta-singleton def comes last, so a walk that files it on M1's singleton takes it over `def n`.
  def self.meta_source = <<~RUBY
    class M1
      class << self
        def n = :sing_n
        def self.n = "meta"
      end
    end
  RUBY

  # label => [source, sig-gen proposals, a call that must read the class's own method, its type]
  rows = {
    "def String.q in class L" => [
      "class L\n  def q = 1\n  def String.q = \"other\"\nend\n", [["L", "def q: () -> 1"]], "L.new.q", "1"
    ],
    "def A.z in A::B" => [
      "module A\n  module B\n    def z = 3\n    def A.z = \"A.z\"\n  end\nend\n", [["A::B", "def z: () -> 3"]],
      "A::B.new.z", "3"
    ],
    "def o.q on a local" => [
      "class LO\n  def q = 1\n  o = Object.new\n  def o.q = \"obj\"\nend\n", [["LO", "def q: () -> 1"]], "LO.new.q", "1"
    ],
    "def OBJ.q on a constant holding an object" => [
      "class LC\n  def q = 1\n  OBJ = Object.new\n  def OBJ.q = :objconst\nend\n", [["LC", "def q: () -> 1"]],
      "LC.new.q", "1"
    ],
    "def self.n in class << self" => [meta_source, [["M1", "def self.n: () -> :sing_n"]], "M1.n", ":sing_n"]
  }

  rows.each do |label, (source, expected, call, type)|
    it "proposes only the enclosing class's own method for #{label}" do
      expect(proposals("code.rb" => source)).to eq(expected)
    end

    it "reads `#{call}` as the enclosing class's own method for #{label}" do
      expect(assert_type_mismatches("#{source}assert_type(#{type.inspect}, #{call})\n")).to eq([])
    end
  end

  it "leaves the committed `def self.n` signature unchallenged by the meta-singleton def" do
    expect(return_mismatches(self.class.meta_source, "class M1\n  def self.n: () -> :sing_n\nend\n")).to eq([])
  end

  it "does not check a singleton def a later def of the name replaced" do
    source = "class V\n  def V.w = \"first\"\n  def self.w = :second\nend\n"
    expect(return_mismatches(source, "class V\n  def self.w: () -> :second\nend\n")).to eq([])
  end

  context "with the lexical self as the receiver (controls)" do
    let(:source) do
      <<~RUBY
        class Ctl
          def self.x = 1
          def Ctl.y = "y"
          def z = :z
          class << self
            def w = 2.0
            def Ctl.v = :v
          end
        end
      RUBY
    end

    it "proposes each on its own side" do
      expect(proposals("code.rb" => source)).to eq(
        [["Ctl", "def self.v: () -> :v"], ["Ctl", "def self.w: () -> Float"], ["Ctl", "def self.x: () -> 1"],
         ["Ctl", "def self.y: () -> \"y\""], ["Ctl", "def z: () -> :z"]]
      )
    end

    it "still checks each singleton def against its signature" do
      rbs = "class Ctl\n#{%w[x y w v].map { |name| "  def self.#{name}: () -> 9\n" }.join}end\n"
      expect(return_mismatches(source, rbs)).to eq([2, 3, 6, 7])
    end
  end

  it "reads `class << M` inside `module M` as `class << self`" do
    source = "module CM\n  def m = 1\n  class << CM\n    def m = \"single\"\n  end\nend\n"
    expect(proposals("code.rb" => source)).to eq([["CM", "def m: () -> 1"], ["CM", "def self.m: () -> \"single\""]])
  end

  it "keeps a reopened class's own def when another file defines the name on another object" do
    files = { "a.rb" => "class Re\n  def a = 1\nend\n",
              "b.rb" => "class Re\n  def String.a = \"x\"\n  def b = 2\nend\n" }
    expect(proposals(files)).to eq([["Re", "def a: () -> 1"], ["Re", "def b: () -> 2"]])
  end

  it "leaves a foreign def out of a module_function module" do
    source = "module MF\n  module_function\n  def f = 1\n  def String.g = 2\nend\n"
    expect(proposals("code.rb" => source)).to eq([["MF", "def self?.f: () -> 1"]])
  end

  it "does not check `def String.q` against the enclosing class's own `def self.q` signature" do
    source = "class L\n  def String.q = \"other\"\nend\n"
    expect(return_mismatches(source, "class L\n  def self.q: () -> 1\nend\n")).to eq([])
  end

  it "does not check `def self.n` in a `class << self` body against the class's `def self.n` signature" do
    source = "class M2\n  class << self\n    def self.n = \"meta\"\n  end\nend\n"
    expect(return_mismatches(source, "class M2\n  def self.n: () -> :sing_n\nend\n")).to eq([])
  end

  context "with an ivar the foreign def's body writes" do
    let(:source) do
      <<~RUBY
        class IV
          def initialize = @x = 1
          def a = @x
          def String.q
            @x = "s"
          end
        end
      RUBY
    end

    it "leaves the write out of the class's ivar census" do
      expect(assert_type_mismatches(source.sub("def a = @x", 'def a = assert_type("1", @x)'))).to eq([])
    end

    it "leaves the write out of def.ivar-write-mismatch" do
      rules = analyze(files: { "code.rb" => source }).diagnostics.map { |d| d.rule.to_s }
      expect(rules).not_to include("def.ivar-write-mismatch")
    end
  end

  describe "the indexer's tables" do
    let(:program) { Prism.parse("class L\n  def q = 1\n  def String.other = 2\nend\n").value }

    it "files no method of the enclosing class" do
      expect(Rigor::Inference::ScopeIndexer.build_methods_and_def_nodes(program).first).to eq("L" => { q: :instance })
    end

    it "claims no owner or side in the deferred-range row" do
      rows = Rigor::Inference::ScopeIndexer.build_deferred_ranges(program)
      expect(rows.map { |row| row.drop(2) }).to eq([[:q, :instance, "L"], [:other, nil, nil]])
    end

    it "claims no owner or side for a foreign def passed to either module_function spelling" do
      %w[module_function self.module_function].each do |spelling|
        rows = Rigor::Inference::ScopeIndexer.build_deferred_ranges(
          Prism.parse("module MF\n  #{spelling} def String.g = 1\nend\n").value
        )
        expect(rows.map { |row| row.drop(2) }.uniq).to eq([[:g, nil, nil]])
      end
    end
  end
end
