# frozen_string_literal: true

# Issue #1123 — `Module#prepend` is ignored in discovered-ancestor ordering: the overridden method wins.
#
# `Base.prepend(Loud)` (and the in-body `prepend Loud`) left the class's own `def` nearer than the prepended
# module, so `Base.new.speak` typed the value the program does NOT run — a wrong precise claim, not merely a
# lost precision. Ruby inserts a prepended module, and its own ancestry, IMMEDIATELY BEFORE the class that
# prepends it, so the module's `def` wins and the class's own body is what `super` reaches.
#
# The fix was the instance-side ordering in `Scope#user_def_through_ancestors`: a prepend wedge (fed by
# `ScopeIndexer`'s new prepend table) searched ahead of the class's own defs; since #1567 it is a position on
# `Scope::ResolutionChain`, which puts a prepended module ahead of the class at every level.
# Issue #1173 later gave `include` the same treatment: the include table stores instance-ancestor search
# order, so `include M1; include M2` answers M2's definition the way CRuby does — the control below now
# asserts the CORRECT runtime order rather than the pre-#1173 divergence.
#
# Every expectation below is the answer CRuby gives for the same source, or (the receiver-form call examples since
# ADR-119 C2-b1) `Dynamic[top]` beside the walk's answer, which is CRuby's.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "Module#prepend ancestor order (#1123)" do
  def dumps_for(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    ).diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  # The definer the ancestor walk answers (the union read the existence checks use), from one file's tables.
  def walk_owner(source, class_name, method_name)
    root = Prism.parse(source).value
    scope = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty)[root]
    scope.user_def_through_ancestors(class_name, method_name)&.last
  end

  around do |example|
    Dir.mktmpdir("rigor-prepend-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # ADR-119 C2-b1 — a receiver-form `Recv.prepend(Mod)` written outside the class body is an unpositioned edge:
  # the tables cannot place it against the class's other mixin statements, so the chain is marked and the instance
  # typing read answers `UNKNOWN` (the mark is not discharged, since `Mod` defines the name). The three call-form
  # examples below therefore type `Dynamic[top]`, never the class's own (overridden) answer, and pin the order the
  # walk resolves (`walk_owner`), which is what #1123 fixed. The in-body forms keep their precise types.

  # NOTE: the module bodies below return DISTINCT module constants rather than literals. A value-pinned
  # (literal) return is widened to `Dynamic[top]` by ADR-57 N5's overridable-method gate whenever a related
  # class redefines the name — which a prepended method always has (the class that prepends it does) — so a
  # literal would hide WHICH definition answered. This lane does not own `ExpressionTyper`'s gate, so the
  # examples below state the observable the gate leaves: a non-pinned return, or the class's own literal
  # where no prepend is in play.
  it "puts a prepended module ahead of the class for the `Base.prepend(Mod)` call form" do
    source = <<~RUBY
      module Mod
        def speak = Comparable
      end
      class Base
        def speak = Kernel
      end
      Base.prepend(Mod)
      Rigor.dump_type(Base.new.speak)
    RUBY
    expect(walk_owner(source, "Base", :speak)).to eq("Mod")
    expect(dumps_for(source)).to eq(["dump_type: Dynamic[top]"])
  end

  it "puts an in-body `prepend Mod` ahead of the class too" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Comparable)"])
      module Mod
        def speak = Comparable
      end
      class Base
        prepend Mod
        def speak = Kernel
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "resolves `super` from the prepended method to the class's own definition, never to itself" do
    # `super` is a Dynamic source (`ExpressionTyper` types `Prism::SuperNode` as `dynamic_top`), so the
    # observable is the interpolated `String` — the module's body ran — plus the absence of the `bot` the
    # engine's recursion net answers a self-call with (`def speak = speak` types `bot`).
    source = <<~RUBY
      module Loud
        def speak = "LOUD \#{super}"
      end
      class Base
        def speak = "base"
      end
      Base.prepend(Loud)
      Rigor.dump_type(Base.new.speak)
    RUBY
    expect(walk_owner(source, "Base", :speak)).to eq("Loud")
    # Since C2-b1 the call form types `Dynamic[top]` (see above); it is never the recursion net's `bot`.
    expect(dumps_for(source)).to eq(["dump_type: Dynamic[top]"])
  end

  it "searches a prepend on an ancestor for the subclass too" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Comparable)"])
      module Mod
        def speak = Comparable
      end
      class Base
        prepend Mod
        def speak = Kernel
      end
      class Sub < Base
      end
      Rigor.dump_type(Sub.new.speak)
    RUBY
  end

  it "orders two `prepend` statements nearest-first, as Ruby does" do
    # `prepend A; prepend B` searches B before A, so B's def wins.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Enumerable)"])
      module A
        def speak = Comparable
      end
      module B
        def speak = Enumerable
      end
      class Base
        prepend A
        prepend B
        def speak = Kernel
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "keeps one statement's argument order, as Ruby does" do
    # `prepend A, B` makes A the nearer of the two.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Comparable)"])
      module A
        def speak = Comparable
      end
      module B
        def speak = Enumerable
      end
      class Base
        prepend A, B
        def speak = Kernel
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "keeps a prepended module ahead of an included one, whichever order they are written" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Comparable)"])
      module Inc
        def speak = Enumerable
      end
      module Pre
        def speak = Comparable
      end
      class Base
        include Inc
        prepend Pre
        def speak = Kernel
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "reaches a method only the prepended module's own include defines" do
    # Ruby inserts the prepend's whole sub-chain before the class, so `Prefix` is ahead of `Base`. (The
    # mixin name is top level because an in-body `include Prefix` resolving to a NESTED `Mod::Prefix` is
    # the deliberately-missing `<owner>::<raw>` rung the include walk documents — a separate gap this
    # change does not touch.)
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: singleton(Comparable)"])
      module Prefix
        def speak = Comparable
      end
      module Mod
        include Prefix
      end
      class Base
        prepend Mod
        def speak = Kernel
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "resolves the receiver of a `Recv.prepend(Mod)` written inside a namespace" do
    source = <<~RUBY
      module Api
        module Loud
          def speak = Comparable
        end
        class Widget
          def speak = Kernel
        end
        Widget.prepend(Loud)
      end
      Rigor.dump_type(Api::Widget.new.speak)
    RUBY
    expect(walk_owner(source, "Api::Widget", :speak)).to eq("Api::Loud")
    expect(dumps_for(source)).to eq(["dump_type: Dynamic[top]"])
  end

  it "leaves a class's own def winning over an included module (include control)" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: \"base\""])
      module Mod
        def speak = "mod"
      end
      class Base
        include Mod
        def speak = "base"
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "answers the LAST include's def when two modules both define it (include control, #1173)" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: \"m2\""])
      module M1
        def speak = "m1"
      end
      module M2
        def speak = "m2"
      end
      class Base
        include M1
        include M2
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "falls through a prepended module that does not define the method" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: \"base\""])
      module Other
        def other = :other
      end
      class Base
        prepend Other
        def speak = "base"
      end
      Rigor.dump_type(Base.new.speak)
    RUBY
  end

  it "declines the singleton side: `class << self; prepend Mod` still answers the class's own def" do
    # DECLINED, and recorded here rather than fixed: the singleton-side mixin walk folds a `class << self`
    # body's `include` / `prepend` into the `extend` edge (issue #915), which records that the module is on
    # the singleton but not WHERE in its MRO — so `class << self; prepend Mod; end` leaves `def self.speak`
    # nearer than `Mod#speak`, and the instance-side ordering this change lands does not reach it. The
    # table this change adds is instance-side only by construction (a `class << self` body records no
    # `current_class`, the same rule that keeps it out of `discovered_includes`), so the decline is
    # structural rather than an omission. This example pins that the instance-side ordering did not
    # disturb the singleton one; a singleton-side prepend ordering is a separate change.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: \"base\""])
      module Loud
        def speak = "LOUD"
      end
      class Base
        class << self
          prepend Loud
        end
        def self.speak = "base"
      end
      Rigor.dump_type(Base.speak)
    RUBY
  end
end
