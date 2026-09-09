# frozen_string_literal: true

# Issue #898 — `narrow_singleton_to_class` approximates `Singleton[Foo]` as "an instance of `Class`" and
# asks the class ordering about `Class` alone, which is silent about every module `extend` put in the class
# object's singleton ancestry:
#
#   class Widget; extend Comparable; end
#   k = Widget
#   case k
#   when Comparable then k.clamp(1, 2)   # reported unreachable; `Widget.is_a?(Comparable)` is true in MRI
#   end
#
# #657's `:unknown` decline does not reach it: `Class` and `Comparable` are both in RBS and neither
# includes the other, so the ordering answers `:disjoint` and the collapse is authorised on evidence the
# model never had. The evidence it needs is the project's own `extend` record, which #526 already built
# inside `ScopeIndexer` and threw away; it now survives onto the scope as `discovered_extends`.
#
# The record is read in ONE direction only. It says a module IS in the singleton ancestry; it can never say
# one is absent (a runtime `Widget.extend(m)`, a `class << self; include M; end`, an `extend` in a file
# outside the analysed set are all invisible to the walk), so a hit withholds the `Bot` and yields
# `Dynamic[top]` rather than asserting the arm matches. The must-still-fire half below is what separates
# that from disabling the rule for singletons.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a class object's own extend record on the positive edge (#898)" do
  def run_files(files)
    FileUtils.mkdir_p("lib")
    files.each { |name, source| File.write(File.join("lib", name), source) }
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib])
  end

  def run_source(source) = run_files("demo.rb" => source)

  def rules_for(source)
    run_source(source).diagnostics.map(&:qualified_rule).reject { |r| r == "dump.type" }
  end

  def dumps_for(result)
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-singleton-extend-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "does not report a when arm unreachable for a class object extended with an RBS-known module" do
    # Both halves matter, as on #657's `Constant` carrier: the arm is no longer called unreachable, AND
    # the call inside it draws no `call.undefined-method`. Preserving `Singleton[Widget]` would have
    # traded the first false positive for the second — `Comparable` is RBS, so nothing folds `clamp` onto
    # `Widget`'s singleton method table.
    expect(rules_for(<<~RUBY)).to be_empty
      class Widget
        extend Comparable
      end

      class Holder
        def probe
          k = Widget
          case k
          when Comparable then k.clamp(1, 2)
          end
        end
      end
    RUBY
  end

  it "reads the extend from a sibling file" do
    # The table has to arrive through the cross-file pre-pass seed, not just the per-file walk: the class
    # a `case` names is rarely declared in the file that switches on it.
    diagnostics = run_files(
      "widget.rb" => <<~RUBY,
        class Widget
          extend Comparable
        end
      RUBY
      "holder.rb" => <<~RUBY
        class Holder
          def probe
            k = Widget
            case k
            when Comparable then k.clamp(1, 2)
            end
          end
        end
      RUBY
    ).diagnostics.map(&:qualified_rule)
    expect(diagnostics).to be_empty
  end

  it "reads an extend inherited from the as-written superclass chain" do
    # A singleton class inherits its superclass's singleton class, so `Base`'s `extend` is `Derived`'s
    # ancestry too and `Derived.is_a?(Comparable)` is true.
    expect(rules_for(<<~RUBY)).to be_empty
      class Base
        extend Comparable
      end

      class Derived < Base; end

      class Holder
        def probe
          k = Derived
          case k
          when Comparable then k.clamp(1, 2)
          end
        end
      end
    RUBY
  end

  it "reads `extend self`, which puts the module in its own singleton ancestry" do
    expect(rules_for(<<~RUBY)).to be_empty
      module Meta
        extend self

        def meta = 1
      end

      class Holder
        def probe
          k = Meta
          case k
          when Meta then k.meta
          end
        end
      end
    RUBY
  end

  describe "the half that must still fire" do
    it "still reports a module arm for a class object the project never extends" do
      # The `Class` approximation is real evidence where no `extend` competes with it, and this is the
      # case that fails first if the fix is written as "never collapse a singleton against a module".
      expect(rules_for(<<~RUBY)).to eq(["flow.unreachable-clause"])
        class Widget; end

        class Holder
          def probe
            k = Widget
            case k
            when Comparable then k.clamp(1, 2)
            end
          end
        end
      RUBY
    end

    it "still reports an arm no extended module orders BELOW" do
      # `Integer` includes `Comparable`, so `extend Comparable` under `when Integer` orders `:superclass`
      # — the extended module is a SUPERTYPE of the target and supports nothing. Reading "not disjoint" as
      # support here retracts `case SomeClass when Integer` from every class that extends a core module,
      # and the first cut of this fix did exactly that.
      expect(rules_for(<<~RUBY)).to eq(["flow.unreachable-clause"])
        class Widget
          extend Comparable
        end

        class Holder
          def probe
            k = Widget
            case k
            when Integer then k.succ
            end
          end
        end
      RUBY
    end

    it "keeps the preserving edge and does not turn the decline into a claim" do
      # Three pins in one run. `is_a?(Class)` still preserves `singleton(Widget)` (the `extend` record is
      # consulted only after `subclass_of?` already answered false). The truthy edge of the extended-module
      # guard is `Dynamic[top]`, the decline — not the asked module, which the record cannot establish.
      # And the FALSEY edge still carries `singleton(Widget)`: the record is never read there, so a
      # conditional or runtime `extend` cannot make Rigor call the `else` branch dead.
      result = run_source(<<~RUBY)
        class Widget
          extend Comparable
        end

        class Holder
          def preserved
            k = Widget
            Rigor.dump_type(k) if k.is_a?(Class)
          end

          def both_edges
            k = Widget
            if k.is_a?(Comparable)
              Rigor.dump_type(k)
            else
              Rigor.dump_type(k)
            end
          end
        end
      RUBY
      expect(dumps_for(result)).to eq(
        ["dump_type: singleton(Widget)", "dump_type: Dynamic[top]", "dump_type: singleton(Widget)"]
      )
    end
  end
end
