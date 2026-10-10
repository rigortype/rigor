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
      Rigor.assert_type("Integer", (1 + (m ** 2)).val)
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

  it "answers an Integer flow for an Integer limit and admits a Float for a Float one" do
    source = <<~RUBY
      require "rigor/testing"

      graph = AcLibraryRb::MaxFlow.new(2)
      Rigor.assert_type("Integer", graph.flow(0, 1))
      Rigor.assert_type("Float | Integer", graph.flow(0, 1, 2.5))
      Rigor.assert_type("Float | Integer", graph.flow(0, 1, gets ? 3 : 2.5))
      Rigor.assert_type("[Integer, Integer]", AcLibraryRb::MinCostFlow.new(2).flow(0, 1))
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

  # Issue #1697 — the library's documented idiom: a top-level `include AcLibraryRb` mixes the module into
  # `Object`, so its instance methods answer bare top-level calls. They are silent; typing them is #1715's.
  it "silences a bare top-level call through a top-level include AcLibraryRb, untyped" do
    source = <<~RUBY
      require "rigor/testing"
      require "ac-library-rb/crt"
      include AcLibraryRb

      Rigor.assert_type("Dynamic[top]", crt([2, 3], [3, 5]))
      Rigor.assert_type("Dynamic[top]", pow_mod(2, 10, 1000))
      frobnicate
    RUBY
    expect(rules(run_plugin(source: source))).to eq([[7, "call.unresolved-toplevel"]])
  end

  # Review of #1706: a project method on the receiver's own class outranks the module mixed into Object.
  it "does not type a project Integer#inv_mod from AcLibraryRb#inv_mod" do
    source = <<~RUBY
      require "ac-library-rb/math"
      include AcLibraryRb

      class Integer
        def inv_mod(m) = pow(m - 2, m).to_s
      end

      puts 3.inv_mod(7).upcase
    RUBY
    expect(rules(run_plugin(source: source))).to eq([])
  end

  # Issue #1698 — the library's documented idiom: `include AcLibraryRb` in a class, then the bare class names.
  it "resolves a bare class name through `include AcLibraryRb` in a class body" do
    source = <<~RUBY
      require "rigor/testing"
      require "ac-library-rb/segtree"

      class Solver
        include AcLibraryRb

        def run
          seg = Segtree.new([1, 2, 3], 0) { |x, y| x + y }
          Rigor.assert_type("AcLibraryRb::Segtree", seg)
          seg.frobnicate
        end
      end
    RUBY
    expect(rules(run_plugin(source: source))).to eq([[10, "call.undefined-method"]])
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
