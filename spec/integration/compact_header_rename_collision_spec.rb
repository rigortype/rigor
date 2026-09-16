# frozen_string_literal: true

# Issue #986 — when the compact-header rename pass lands TWO declarations of one class on a single key, a
# raw ancestor name BOTH of them wrote must not be resolved by picking one site's cref.
#
# `class Outer::Leaf` at the top level and `class Outer::Leaf` inside `module Wrap` are one class with both
# bodies, and each body's `include Mixin` records a header nesting under the SAME raw key `"Mixin"` — the
# top-level site's empty chain, the compact site's `["Wrap"]`. The rename pass merged the two buckets with
# `Hash#merge`, so one chain REPLACED the other and the answer turned on which file the project fold
# reached last: top-then-compact resolved the include to `Wrap::Mixin`, compact-then-top to `::Mixin`.
#
# Unioning the two chains only makes that pick deterministic, and a deterministic wrong ancestor is worse
# than an order-dependent one: `Scope#compute_ancestor_class_name` takes the first known class as the SOLE
# resolution, `union_header_nesting` sorts `Wrap::Mixin` ahead of `::Mixin`, and if the two modules declare
# one method at different arities `call.wrong-arity` then fires on a program Ruby runs happily. Both
# `include`s run at runtime; which module lands nearer in the MRO is the two files' load order, which this
# walk cannot see. So the colliding chains are kept side by side and `Scope` DECLINES when they resolve to
# two different project classes — the receiver's method stays `Dynamic` and nothing is reported.

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

  # The top-level site with three more method sources around it: the class's own `def`, a superclass, and a
  # second mixin whose name no other site wrote.
  def surrounded_top_level_site
    <<~RUBY
      class Outer; end

      class Base
        def from_base = :base
      end

      module Mixin
        def plain = :plain
      end

      module Solo
        def from_solo = :solo
      end

      class Outer::Leaf < Base
        include Mixin
        include Solo
        def own = :own
      end
    RUBY
  end

  def surrounded_probe
    <<~RUBY
      Outer::Leaf.new.own(1)
      Outer::Leaf.new.from_base(1)
      Outer::Leaf.new.from_solo(1)
    RUBY
  end

  # The compact site again, with the calls written INSIDE its own body: `new.shared` is the collision's
  # false positive, `new.only_wrap` a method only this site's `Mixin` declares.
  def compact_site_calling_itself
    <<~RUBY
      module Wrap
        module Mixin
          def shared(y) = y
          def only_wrap(z) = z
        end

        class Outer::Leaf
          include Mixin
          new.shared(1, 2)
          new.only_wrap(1, 2)
        end
      end
    RUBY
  end

  def shared_top_level_site
    <<~RUBY
      class Outer; end

      module Mixin
        def shared = :top
      end

      class Outer::Leaf
        include Mixin
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

  # The fold reaches the files in walk order, so the file NAMES are what select the order under test: the
  # sites are written `f0_site.rb`, `f1_site.rb`, ... in the order given, and the probe sorts last.
  def answers(*sources, probe)
    FileUtils.mkdir_p("lib")
    sources.each_with_index { |source, i| File.write(File.join("lib", "f#{i}_site.rb"), source) }
    File.write(File.join("lib", "z_probe.rb"), probe)
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

  it "answers the same whichever declaration the project folds first, and reports nothing" do
    top_then_compact = answers(top_level_site, compact_site, both_probe)
    compact_then_top = answers(compact_site, top_level_site, both_probe)

    expect(top_then_compact).to eq(compact_then_top)
    # Both `Mixin`s are declared, so the two alternative crefs name two different project classes and the
    # include resolves to neither. Master answered `:wrapped` / `Dynamic[top]` one way round and
    # `Dynamic[top]` / `:plain` the other; the two resolutions it alternated between were each a coin flip
    # on load order, so the answer is silence in both orders rather than either of them.
    expect(top_then_compact[:dumps]).to eq(["dump_type: Dynamic[top]", "dump_type: Dynamic[top]"])
    expect(top_then_compact[:other]).to eq([])
  end

  it "does not report an arity error when the two mixins declare one method differently" do
    # The false-positive arm, and the reason the collision is declined rather than resolved. Ruby loads
    # `f0_site.rb` then `f1_site.rb`, so with the wrap site first `::Mixin` is included LAST, wins the MRO,
    # and `.shared` really does take no arguments. Master is silent in that order and reports
    # `wrong number of arguments (given 0, expected 1)` in the other, so it is a false positive on one of
    # the two orders whichever way the pick is made deterministic — and unioning the chains makes it the
    # answer for BOTH, since `union_header_nesting` sorts `Wrap::Mixin` first. The dumps below are what
    # discriminate the two orders on master; the silence is what this arm protects.
    wrap = <<~RUBY
      module Wrap
        module Mixin
          def shared(y) = y
        end

        class Outer::Leaf
          include Mixin
        end
      end
    RUBY
    top = <<~RUBY
      class Outer; end

      module Mixin
        def shared = :top
      end

      class Outer::Leaf
        include Mixin
      end
    RUBY
    [[wrap, top], [top, wrap]].each do |first, second|
      result = answers(first, second, "Rigor.dump_type(Outer::Leaf.new.shared)\n")
      expect(result[:other]).to eq([])
      expect(result[:dumps]).to eq(["dump_type: Dynamic[top]"])
    end
  end

  it "still fires on wrong arity for a method only one of the two mixins declares" do
    # The must-still-FIRE arm, and the control for the one above: `call.wrong-arity` is live in this
    # harness and still reads a mixin method's declared arity. The decline is scoped to the raw ancestor
    # name two colliding sites both wrote, so an `include` elsewhere in the same project — here on a class
    # no rename touches, alongside the colliding pair — is unaffected.
    source = <<~RUBY
      module Solo
        def only_here(x) = x
      end

      class Alone
        include Solo
      end

      Rigor.dump_type(Alone.new.only_here(1))
      Alone.new.only_here
    RUBY
    result = answers(top_level_site, compact_site, source)
    expect(result[:other]).to include(/wrong number of arguments/)
    expect(result[:dumps]).to eq(["dump_type: 1"])
  end

  it "keeps resolving the collision when only one of the two crefs names a declared module" do
    # The bound on the decline: it is two DIFFERENT project classes that make the name unanswerable. With no
    # `Wrap::Mixin` declared, the compact site's cref resolves nowhere, the alternatives agree on `::Mixin`,
    # and both sites' include keeps its answer — in both fold orders.
    wrap = <<~RUBY
      module Wrap
        class Outer::Leaf
          include Mixin
        end
      end
    RUBY
    [[wrap, top_level_site], [top_level_site, wrap]].each do |first, second|
      result = answers(first, second, "Rigor.dump_type(Outer::Leaf.new.plain)\n")
      expect(result[:dumps]).to eq(["dump_type: :plain"])
      expect(result[:other]).to eq([])
    end
  end

  it "takes a third site's nested spelling as a third cref without crashing, in every fold order" do
    # `module Outer; class Leaf` is the Zeitwerk default spelling, so a real project reaches the collision
    # with three crefs, not two. The alternatives shape has to survive the PER-FILE merge as well as the
    # rename pass: `merge_ancestry_tables` merges a file's plain String chains over the cross-file seed,
    # whose bucket already holds alternatives, and unioning them there split an Array — an internal
    # analyzer error on the third file, cold and warm alike.
    nested_site = <<~RUBY
      module Outer
        class Leaf
          include Mixin
          def nested_own = :nested
        end
      end
    RUBY
    probe = <<~RUBY
      Rigor.dump_type(Outer::Leaf.new.nested_own)
      Rigor.dump_type(Outer::Leaf.new.plain)
      Rigor.dump_type(Outer::Leaf.new.wrapped)
    RUBY
    results = [top_level_site, compact_site, nested_site].permutation.map do |order|
      answers(*order, probe)
    end
    expect(results.map { |r| r[:other] }).to all(eq([]))
    expect(results.uniq.size).to eq(1)
    # The class's OWN def is unaffected by the ambiguity of the mixin name; `Outer::Mixin` is not declared,
    # so the third cref adds no third resolution and the two that disagree still decline.
    expect(results.first[:dumps]).to eq(
      ["dump_type: :nested", "dump_type: Dynamic[top]", "dump_type: Dynamic[top]"]
    )
  end

  it "still fires on wrong arity elsewhere on the colliding class itself" do
    # The decline is per ancestor NAME, and must not become a blanket amnesty for the receiver. Declining
    # by handing `call.wrong-arity` an unknown external mixin did exactly that: the rule suppresses a level
    # carrying a mixin it cannot see into, so the class's own `def`, its superclass's and its unambiguous
    # second mixin's all went quiet too. Both ambiguous classes are taken as levels instead, so only a
    # method they actually disagree about is unanswerable.
    [[surrounded_top_level_site, compact_site], [compact_site, surrounded_top_level_site]].each do |first, second|
      result = answers(first, second, surrounded_probe)
      expect(result[:other]).to contain_exactly(
        /wrong number of arguments to `own'/, /wrong number of arguments to `from_base'/,
        /wrong number of arguments to `from_solo'/
      )
    end
  end

  it "declines inside the compact declaration's own body too" do
    # A body written inside the compact header does not see the rename: its `self_type` is the per-node
    # `Singleton[Wrap::Outer::Leaf]`, and the per-file ancestry tables laid over the seed are keyed the same
    # way with this site's chain ALONE — so `include Mixin` resolved to `Wrap::Mixin` outright and
    # `new.shared(1, 2)` reported an arity the other site's `Mixin` contradicts. The re-anchored bucket is
    # filed under the un-renamed name as well, which is what carries the alternatives in here.
    [[compact_site_calling_itself, shared_top_level_site],
     [shared_top_level_site, compact_site_calling_itself]].each do |first, second|
      result = answers(first, second, "\n")
      # The must-still-FIRE half, in the same body: `only_wrap` is declared by one site's `Mixin` only, so
      # the alternatives do not disagree about it and it is answered whatever the load order.
      expect(result[:other]).to contain_exactly(/wrong number of arguments to `only_wrap'/)
    end
  end

  it "declines a name neither mixin defines, in both fold orders" do
    # The must-still-decline arm: a name no ancestor of the class owns is unchanged — still `Dynamic`,
    # still silent, exactly as on master.
    fold_orders.each do |first, second|
      result = answers(first, second, "Rigor.dump_type(Outer::Leaf.new.neither_mixin_defines_this)\n")
      expect(result[:dumps]).to eq(["dump_type: Dynamic[top]"])
      expect(result[:other]).to eq([])
    end
  end
end
