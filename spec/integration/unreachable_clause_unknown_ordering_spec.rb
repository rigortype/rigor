# frozen_string_literal: true

# Issue #657 — `Type::Bot` is the assertion "this can never match", and only a KNOWN-disjoint ordering
# supports it.
#
# `narrow_constant_to_class` asked `subclass_of?`, which folds `:disjoint` and `:unknown` into one `false`.
# That is safe on the negative edge, where the pre-state survives, and an over-claim on the positive one:
#
#   module Taggable; def tag = "t"; end
#   class Integer; include Taggable; end
#   x = 1
#   case x
#   when Taggable then x.tag       # reported unreachable; `1.is_a?(Taggable)` is true in MRI
#   end
#
# The ordering is `:unknown` because an in-source `include` into a CORE class never reaches the
# environment's class ordering — the include is discovered in project source, `Integer`'s ancestry comes
# from RBS, and the two are not joined. Joining them is the precision half, left open on #657.
#
# The same collapse lived in the `Tuple` / `HashShape` and `Singleton` carriers, which ask the ordering
# about `Array` / `Hash` / `Class` — the second describe block below covers those. The singleton residue
# (`extend` is not modelled, so a target the environment DOES order against `Class` still collapses) was
# #898, closed by reading the project's own `extend` record; that half lives in
# `spec/integration/unreachable_clause_singleton_extend_spec.rb`.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "an unknown class ordering on the positive edge (#657)" do
  def run_source(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def rules_for(source)
    run_source(source).diagnostics.map(&:qualified_rule).reject { |r| r == "dump.type" }
  end

  around do |example|
    Dir.mktmpdir("rigor-unknown-ordering-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not report a when arm unreachable for a core class the project reopens" do
    # Both halves matter: the arm is no longer called unreachable, AND the call inside it does not draw
    # `call.undefined-method`. An earlier cut kept the literal instead of joining to Dynamic and traded the
    # first false positive for the second.
    expect(rules_for(<<~RUBY)).to be_empty
      module Taggable
        def tag = "t"
      end

      class Integer
        include Taggable
      end

      class Holder
        def probe
          x = 1
          case x
          when Taggable then x.tag
          end
        end
      end
    RUBY
  end

  it "does not report it for a module nothing in the environment relates to the subject" do
    # The same `:unknown` verdict from the other direction — and the reason this is not a narrower fix:
    # Rigor cannot prove `String` does NOT include `Unrelated` either, since any file could reopen it.
    expect(rules_for(<<~RUBY)).to be_empty
      module Unrelated
        def other = 1
      end

      class Holder
        def probe
          s = "str"
          case s
          when Unrelated then s.other
          end
        end
      end
    RUBY
  end

  it "still reports an arm the environment knows is disjoint" do
    # Mandatory must-still-fire. `String` vs `Integer` is `:disjoint`, not `:unknown` — the evidence the
    # `Bot` collapse always needed, and the arm that fails if the fix is written as "never collapse".
    expect(rules_for(<<~RUBY)).to eq(["flow.unreachable-clause"])
      class Holder
        def probe
          s = "str"
          case s
          when Integer then s.succ
          end
        end
      end
    RUBY
  end

  it "still collapses an instance_of? guard, and only widens the is_a? one" do
    # `instance_of?` compares the exact class, and a module is never an object's class, so `Bot` is right
    # here whatever the ordering says. The fix is scoped to the inexact (`is_a?` / `case`) edge, and the two
    # guards in one fixture pin the boundary from both sides — the exact branch's subject is still `bot`,
    # the inexact one's is the honest `Dynamic[top]`.
    result = run_source(<<~RUBY)
      module Taggable
        def tag = "t"
      end

      class Integer
        include Taggable
      end

      class Holder
        def probe_exact
          x = 1
          Rigor.dump_type(x) if x.instance_of?(Taggable)
        end

        def probe_inexact
          x = 1
          Rigor.dump_type(x) if x.is_a?(Taggable)
        end
      end
    RUBY
    dumps = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
    expect(dumps).to eq(["dump_type: bot", "dump_type: Dynamic[top]"])
  end

  # The first cut of the decline reached only the `Constant` carrier, because that is the carrier the
  # repro happens to use. Three of the four positive-edge carriers ask the same question, and a literal
  # `[1, 2]` / `{ a: 1 }` / class object is as ordinary a case subject as `1`.
  describe "the other carriers that reach the same verdict" do
    it "does not report a when arm unreachable for Array and Hash reopened with a project mixin" do
      # `Tuple` and `HashShape` project to `Array` / `Hash`, so the include lands on a core class exactly
      # as `Integer` does, and the ordering is `:unknown` for the same reason.
      expect(rules_for(<<~RUBY)).to be_empty
        module Taggable
          def tag = "t"
        end

        class Array
          include Taggable
        end

        class Hash
          include Taggable
        end

        class Holder
          def from_tuple
            x = [1, 2]
            case x
            when Taggable then x.tag
            end
          end

          def from_hash
            h = { a: 1 }
            case h
            when Taggable then h.tag
            end
          end
        end
      RUBY
    end

    it "does not report it for a class object extended with a project module" do
      # `Singleton[Widget]` is approximated as an instance of `Class`, and `Class` vs a project module is
      # `:unknown` — while `Widget.is_a?(Meta)` is true in MRI after the `extend`.
      expect(rules_for(<<~RUBY)).to be_empty
        module Meta
          def meta = 1
        end

        class Widget
          extend Meta
        end

        class Holder
          def probe
            k = Widget
            case k
            when Meta then k.meta
            end
          end
        end
      RUBY
    end

    it "still reports arms the environment knows are disjoint on those carriers" do
      # Mandatory must-still-fire, once per widened carrier. `Array` / `Hash` / `Class` against `Integer`
      # is `:disjoint`, the evidence the collapse always needed; all three fail if the fix is written as
      # "never collapse".
      expect(rules_for(<<~RUBY)).to eq(["flow.unreachable-clause"] * 3)
        class Widget; end

        class Holder
          def from_tuple
            x = [1, 2]
            case x
            when Integer then x.succ
            end
          end

          def from_hash
            h = { a: 1 }
            case h
            when Integer then h.succ
            end
          end

          def from_singleton
            k = Widget
            case k
            when Integer then k.succ
            end
          end
        end
      RUBY
    end

    it "keeps the shape and the singleton on the edge the ordering does support" do
      # The decline is additive: it fires only where `subclass_of?` already answered false, so the
      # preserving edge is untouched and no carrier starts claiming a match it had not established.
      result = run_source(<<~RUBY)
        class Widget; end

        class Holder
          def shape_preserved
            x = [1, 2]
            Rigor.dump_type(x) if x.is_a?(Array)
          end

          def singleton_preserved
            k = Widget
            Rigor.dump_type(k) if k.is_a?(Class)
          end
        end
      RUBY
      dumps = result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
      expect(dumps).to eq(["dump_type: [1, 2]", "dump_type: singleton(Widget)"])
    end
  end
end
