# frozen_string_literal: true

require "spec_helper"
require "prism"
require "rigor/inference/scope_indexer"

# ADR-116 WD9 (#3400) — `ScopeIndexer::MixinTables` builds the include and prepend tables of one file. The examples
# hand `mixin_tables` a parsed snippet and read the three tables back: no index is built and no body evaluated,
# apart from the examples that pin the callers. The examples that read the include table beside the extend table,
# the methods table or a scope stay in `scope_indexer_spec.rb`.
RSpec.describe Rigor::Inference::ScopeIndexer::MixinTables do
  let(:indexer) { Rigor::Inference::ScopeIndexer }

  def parse(source)
    Prism.parse(source).value
  end

  def tables(source) = described_class.mixin_tables(parse(source))

  def includes(source) = tables(source).fetch(:includes)

  def prepends(source) = tables(source).fetch(:prepends)

  # The instance side of the edges whose order is not a fact, by owner.
  def unpositioned(source) = tables(source).fetch(:unpositioned).transform_values { |sides| sides[:include] }

  # #1097 — inside a `*_eval` / `*_exec` block, `Module.nesting` stays LEXICAL while a mixin call binds to the
  # receiver. The examples of that group of `scope_indexer_spec.rb` that read the include table alone, moved as
  # they were; the ones that also read another table stay there.
  describe "eval-block dual context (#1097)" do
    it "declines a `self::` eval receiver inside a `class <<` body" do
      # Inside `class << self` self is the singleton — `self::X` raises NameError at
      # runtime unless the constant lives on that singleton — so the receiver declines
      # rather than filing the block under a class it never opened.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            class << self
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
      expect(table).not_to have_key("M::X")
    end

    it "declines a `self::` eval receiver inside `class << <non-constant>`" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class Y
          class << obj
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).not_to have_key("Y::X")
    end

    it "attributes `include` inside a `self::`-receiver eval block to the resolved owner" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        module M
          Y.class_eval do
            self::X.class_eval { include T }
          end
        end
      RUBY
      expect(table).to include("Y::X" => ["T"])
      expect(table).not_to have_key("M")
    end

    it "declines a `self::` eval receiver inside a `class` declaration under `class <<`" do
      # `class D` opens `#<Class:C>::D` — `self` inside is that unnameable class, so
      # `self::X` there cannot be spelled `C::D::X`.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          class << self
            class D
              self::X.class_eval { include T }
            end
          end
        end
      RUBY
      expect(table).not_to have_key("X")
      expect(table).not_to have_key("C::D::X")
      expect(table).not_to have_key("D::X")
    end

    it "declines a `self::` eval receiver inside an opaque eval body" do
      # `obj.instance_eval`'s self is the receiver object — `self::X` resolves on its
      # singleton, a table nothing names — never `C::X`.
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          obj.instance_eval { self::X.class_eval { include T } }
        end
      RUBY
      expect(table).not_to have_key("C::X")
      expect(table).not_to have_key("X")
    end

    it "attributes `include` inside a meta-new block to the block's class" do
      table = described_class.send(:build_discovered_includes, parse(<<~RUBY))
        module T; end
        class C
          K = Class.new { include T }
        end
      RUBY
      expect(table).to include("C::K" => ["T"])
      expect(table).not_to have_key("C")
    end
  end

  # Issue #1123 — the instance-side prepend table: `{class => [module names, as written]}` in
  # instance-ancestor SEARCH order. It adds the prepend ORDER and KIND the include table cannot carry
  # (that one keeps every mixin in search order since #1173 — prepends ahead of includes — but is read
  # as a set by the arity / visibility / reflection consumers), and
  # `Scope#user_def_through_ancestors` searches it ahead of the class's own `def`s.
  describe ".build_discovered_prepends" do
    it "records an in-body `prepend` in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C
          prepend T
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => ["T"])
    end

    it "orders two statements nearest-first, and one statement's arguments in call order" do
      # `prepend A; prepend B` searches B first; `prepend A, B` makes A the nearer of the two. Since
      # #1173 the include table keeps the same search order — prepends sort ahead of includes there,
      # matching where Ruby puts them (before the class itself).
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          prepend A
          prepend B
        end
        class One
          prepend A, B
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("Two" => %w[B A], "One" => %w[A B])
      expect(described_class.send(:build_discovered_includes, program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders `include` statements nearest-first, and one statement's arguments in written order" do
      # #1173 — `include A; include B` searches B first (Ruby's later-include-wins); `include A, B`
      # keeps `["A", "B"]` because one statement's argument list lands as a unit ahead of the earlier
      # statements'. The pre-#1173 call-order list answered `["A", "B"]` for both.
      program = parse(<<~RUBY)
        module A; end
        module B; end
        class Two
          include A
          include B
        end
        class One
          include A, B
        end
      RUBY
      expect(described_class.send(:build_discovered_includes, program)).to eq("Two" => %w[B A], "One" => %w[A B])
    end

    it "orders a mix of prepend and include the way the runtime ancestry does" do
      # `prepend` lands before the class itself, `include` after it, so both spellings and both
      # statement orders search the prepended module first.
      program = parse(<<~RUBY)
        module I; end
        module P; end
        class A
          include I
          prepend P
        end
        class B
          prepend P
          include I
        end
      RUBY
      expect(described_class.send(:build_discovered_includes, program)).to eq("A" => %w[P I], "B" => %w[P I])
    end

    it "records the `Recv.prepend(Mod)` call form under the receiver in both tables" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.prepend(T)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
      # The call form is the same ancestry edge as the declaration form, so the set-shaped include table
      # carries it too — otherwise the two spellings of one edge would answer differently for arity,
      # visibility and undefined-method suppression.
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => ["T"])
    end

    it "records the `Recv.include(Mod)` and `Recv.send(:include, Mod)` call forms in the include table only" do
      # Issue #1722 — the call form is the same ancestry edge as an in-body `include`, as `Recv.prepend(Mod)` is.
      program = parse(<<~RUBY)
        module T; end
        module U; end
        class C; end
        C.include(T)
        C.send(:include, U)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to be_empty
      expect(described_class.send(:build_discovered_includes, program)).to eq("C" => %w[U T])
    end

    it "resolves an unqualified call-form receiver through the nesting the file declares" do
      program = parse(<<~RUBY)
        module Api
          module T; end
          class C; end
          C.prepend(T)
        end
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("Api::C" => ["T"])
    end

    it "declines a call-form receiver that names no static class" do
      program = parse(<<~RUBY)
        module T; end
        klass = Class.new
        klass.prepend(T)
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to be_empty
    end

    it "records a `prepend` written inside an eval block against the block's receiver" do
      program = parse(<<~RUBY)
        module T; end
        class C; end
        C.instance_eval { prepend T }
      RUBY
      expect(described_class.send(:build_discovered_prepends, program)).to eq("C" => ["T"])
    end
  end
end
