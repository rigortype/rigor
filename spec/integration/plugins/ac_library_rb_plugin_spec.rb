# frozen_string_literal: true

# Integration spec for `plugins/rigor-ac-library-rb/`: a pure RBS-bundle plugin whose manifest declares
# `signature_paths: ["sig"]`. With it active, calls into ac-library-rb's `AcLibraryRb` namespace resolve against the
# bundled signatures instead of reading `Dynamic[top]`.

require "spec_helper"

unless defined?(AC_LIBRARY_RB_PLUGIN_LIB)
  AC_LIBRARY_RB_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-ac-library-rb/lib", __dir__)
end
$LOAD_PATH.unshift(AC_LIBRARY_RB_PLUGIN_LIB) unless $LOAD_PATH.include?(AC_LIBRARY_RB_PLUGIN_LIB)
require "rigor-ac-library-rb"

RSpec.describe "plugins/rigor-ac-library-rb" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::AcLibraryRb }

  def rules(result) = result.diagnostics.map { |d| [d.line, d.qualified_rule] }

  it "is a pure RBS-bundle plugin" do
    expect(plugin_class.manifest.signature_paths).to eq(["sig"])
    expect(plugin_class.manifest.target_gems).to eq(["ac-library-rb"])
  end

  it "types the structural results precisely" do
    source = <<~RUBY
      require "rigor/testing"

      uf = AcLibraryRb::UnionFind.new(4)
      Rigor.assert_type("Integer", uf.merge(0, 1))
      Rigor.assert_type("Array[Array[Integer]]", uf.groups)
      graph = AcLibraryRb::MaxFlow.new(3)
      Rigor.assert_type("Integer", graph.add_edge(0, 1, 4))
      Rigor.assert_type("Array[bool]", graph.min_cut(0))
      Rigor.assert_type("[Integer, Integer]", AcLibraryRb::MinCostFlow.new(2).flow(0, 1))
      Rigor.assert_type("Integer", AcLibraryRb::Segtree.new([1, 2], 0) { |x, y| x + y }.max_right(0) { |v| v < 2 })
      AcLibraryRb::ModInt.set_mod(7)
      Rigor.assert_type("AcLibraryRb::ModInt", AcLibraryRb::ModInt.new(3) + 4)
      Rigor.assert_type("Array[Integer]", 12.divisors)
    RUBY
    result = run_plugin(source: source)
    expect(result.diagnostics.map(&:message)).to be_empty
  end

  it "does not take a literal constructor argument as a container's element type" do
    source = <<~RUBY
      require "rigor/testing"

      seg = AcLibraryRb::Segtree.new(4, 0) { |x, y| x + y }
      Rigor.assert_type("Dynamic[top]", seg.prod(0, 2))
    RUBY
    expect(run_plugin(source: source).diagnostics.map(&:message)).to be_empty
  end

  # Review findings on #1680: each read as a wrong type or a diagnostic on correct code before the fix.
  it "types an Integer on the left of a ModInt as a ModInt, through ModInt#coerce" do
    source = <<~RUBY
      require "rigor/testing"

      AcLibraryRb::ModInt.set_mod(11)
      m = AcLibraryRb::ModInt.new(3)
      Rigor.assert_type("AcLibraryRb::ModInt", 1 + m)
      Rigor.assert_type("Integer", (2 * m).val)
      Rigor.assert_type("3", 1 + 2)
    RUBY
    expect(run_plugin(source: source).diagnostics.map(&:message)).to be_empty
  end

  it "does not pin a priority queue built from a literal array to its literals" do
    source = <<~RUBY
      pq = [3, 1].to_pq
      pq << 5
      v = pq.pop
      puts "five" if v == 5
    RUBY
    expect(run_plugin(source: source).diagnostics.map(&:message)).to be_empty
  end

  it "takes a MaxFlow edge read as an Array of Integers" do
    source = <<~RUBY
      def read_edge = gets.to_s.split.map(&:to_i)
      graph = AcLibraryRb::MaxFlow.new(3)
      graph << read_edge
      graph.push(read_edge)
    RUBY
    expect(run_plugin(source: source).diagnostics.map(&:message)).to be_empty
  end

  it "reports a misspelled method and a wrong argument, which read as untyped without the plugin" do
    source = <<~RUBY
      uf = AcLibraryRb::DSU.new(4)
      uf.unify(0, 1)
      uf.merge("0", 1)
    RUBY
    expect(rules(run_plugin(source: source))).to include([2, "call.undefined-method"],
                                                         [3, "call.argument-type-mismatch"])
  end
end
