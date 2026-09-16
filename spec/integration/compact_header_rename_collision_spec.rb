# frozen_string_literal: true

# Issue #986 — when the compact-header rename pass lands TWO declarations of one class on a single key, the
# colliding `header_nestings` buckets must fold with the table's own union, not with a Hash merge whose
# winner is whichever file the project fold reached last.
#
# `class Outer::Leaf` at the top level and `class Outer::Leaf` inside `module Wrap` are one class with both
# bodies, and each body's `include Mixin` records a header nesting under the SAME raw key `"Mixin"` — the
# top-level site's empty chain, the compact site's `["Wrap"]`. Replacing one with the other made
# `Outer::Leaf.new.wrapped` and `.plain` answer differently depending on file order; unioning makes the
# answer a property of the project.
#
# The union is one chain per raw NAME, not one per SITE: with `Wrap::Mixin` ahead of `::Mixin`, the single
# `"Mixin"` entry the includes record keeps resolves to `Wrap::Mixin`, and `::Mixin`'s methods stay
# unresolved. That is #728's one-chain-per-raw-key bound, and the decline it produces is SILENT — the
# unresolved arm answers `Dynamic`, never a diagnostic, so the cost is a missed method and not a false
# positive. The `Dynamic[top]` expectations below pin that bound deliberately.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a compact-header rename colliding with a top-level declaration (#986)" do
  around do |example|
    Dir.mktmpdir("rigor-compact-header-collision-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # Both sites write the bare name `Mixin`, and the two `Mixin`s each define a different method, so which
  # cref the include was resolved in is readable straight off the answer.
  def top_level_site
    <<~RUBY
      class Outer; end

      module Mixin
        def plain = :plain
      end

      class Outer::Leaf
        include Mixin
      end
    RUBY
  end

  def compact_site
    <<~RUBY
      module Wrap
        module Mixin
          def wrapped = :wrapped
        end

        class Outer::Leaf
          include Mixin
        end
      end
    RUBY
  end

  def both_probe
    <<~RUBY
      Rigor.dump_type(Outer::Leaf.new.wrapped)
      Rigor.dump_type(Outer::Leaf.new.plain)
    RUBY
  end

  def fold_orders
    [[top_level_site, compact_site], [compact_site, top_level_site]]
  end

  # The fold reaches the files in walk order, so the two file NAMES are what select the order under test.
  def answers(first, second, probe)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "a_first.rb"), first)
    File.write(File.join("lib", "b_second.rb"), second)
    File.write(File.join("lib", "c_probe.rb"), probe)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    diagnostics = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    ).diagnostics
    {
      dumps: diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message),
      other: diagnostics.reject { |d| d.qualified_rule == "dump.type" }.map(&:message)
    }
  end

  it "answers the same whichever declaration the project folds first" do
    top_then_compact = answers(top_level_site, compact_site, both_probe)
    compact_then_top = answers(compact_site, top_level_site, both_probe)

    expect(top_then_compact).to eq(compact_then_top)
    # `Wrap::Mixin` is the most-qualified candidate the unioned chain offers for the raw name `Mixin`, and
    # it IS an ancestor of this class at runtime — both `include Mixin` sites run. `.plain` is the
    # one-chain-per-raw-key cost: flip it to `"dump_type: :plain"` when the includes record keeps one entry
    # per SITE and each entry resolves in its own site's cref (#728's bound, left standing by #986).
    expect(top_then_compact[:dumps]).to eq(["dump_type: :wrapped", "dump_type: Dynamic[top]"])
  end

  it "stays silent on the name the union could not resolve" do
    # The false-positive bound. An unresolved mixin method must answer `Dynamic` and report NOTHING: the
    # union widened the candidate list, and a widened list may not turn a missed method into a finding.
    fold_orders.each do |first, second|
      result = answers(first, second, "Rigor.dump_type(Outer::Leaf.new.plain)\n")
      expect(result[:dumps]).to eq(["dump_type: Dynamic[top]"])
      expect(result[:other]).to eq([])
    end
  end

  it "declines a name neither mixin defines, in both fold orders" do
    # The must-still-decline arm: a name no ancestor of the class owns is unchanged by the union — still
    # `Dynamic`, still silent, exactly as before the fix.
    fold_orders.each do |first, second|
      result = answers(first, second, "Rigor.dump_type(Outer::Leaf.new.neither_mixin_defines_this)\n")
      expect(result[:dumps]).to eq(["dump_type: Dynamic[top]"])
      expect(result[:other]).to eq([])
    end
  end

  it "keeps the compact site's mixin reachable from a probe written at the top level" do
    # The union's point, stated positively: `Wrap::Mixin`'s method answers from a probe where no `Wrap` is
    # in scope, because the chain that governs the include is the declaring SITE's and survives the
    # rename collision.
    result = answers(top_level_site, compact_site, "def probe = Rigor.dump_type(Outer::Leaf.new.wrapped)\n")
    expect(result[:dumps]).to eq(["dump_type: :wrapped"])
    expect(result[:other]).to eq([])
  end
end
