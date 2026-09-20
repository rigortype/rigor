# frozen_string_literal: true

require "spec_helper"

# Issue #527 slice 1 — a Ruby-source subclass of a CORE or STDLIB class resolves its inherited calls
# against that ancestor's RBS.
#
# `class SubHash < Hash` answering `Dynamic[top]` to `has_key?` while `{}.has_key?` folded was the
# largest single opacity family in the 2026-09-01 corpus sweep (oj's `Oj::EasyHash`, 26 sites;
# kramdown's `Kramdown::Utils::StringScanner < ::StringScanner`, 26 more). The resolution goes into
# `RbsDispatch.lookup_method` rather than a new tier, because `dispatch_one` keys `self`, `instance`,
# the type-variable map and `SelfSubstitute` on the RECEIVER's class name.
#
# ADR-114 states the decline conditions and the false-positive boundary this file pins from the outside.
RSpec.describe "a source subclass of a core/stdlib class resolves inherited calls (#527 S1)",
               type: :runner do
  def analyzed(source, prelude: "")
    analyze(%(require "rigor/testing"\n#{prelude}include Rigor::Testing\n#{source}))
  end

  def dumps(source, prelude: "")
    analyzed(source, prelude: prelude).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prelude: "")
    analyzed(source, prelude: prelude).diagnostics.map { |d| d.qualified_rule.to_s }
  end

  describe "the inherited declaration answers" do
    it "resolves a core superclass's method on an implicit-self call" do
      expect(dumps(<<~RUBY)).to eq(%w[bool Integer])
        class SubHash < Hash
          def probe
            dump_type(has_key?(:a))
            dump_type(size)
          end
        end
      RUBY
    end

    it "is not generics-specific: a String subclass resolves too" do
      expect(dumps(<<~RUBY)).to eq(%w[Integer Integer])
        class SubStr < String
          def probe
            dump_type(length)
            dump_type(bytesize)
          end
        end
      RUBY
    end

    it "keeps a `-> self` / `-> instance` return on the RECEIVER, which is what CRuby does" do
      expect(dumps(<<~RUBY)).to eq(%w[SubHash SubStr MyError])
        class SubHash < Hash
          def probe = dump_type(clear)
        end

        class SubStr < String
          def probe = dump_type(force_encoding("UTF-8"))
        end

        class MyError < StandardError
          def probe = dump_type(exception("x"))
        end
      RUBY
    end

    it "reaches a declaration written further up the ancestor's OWN RBS ancestry" do
      # `StandardError` declares neither; `Exception` does, and it precedes `::Object` in the MRO.
      expect(dumps(<<~RUBY)).to eq(["String", "Array[String]?"])
        class MyError < StandardError
          def probe
            dump_type(message)
            dump_type(backtrace)
          end
        end
      RUBY
    end

    it "resolves through a stdlib superclass written with a rooted name" do
      expect(dumps(<<~RUBY, prelude: %(require "strscan"\n))).to eq(["String?", "Integer"])
        class MyScanner < ::StringScanner
          def probe
            dump_type(scan(/a/))
            dump_type(pos)
          end
        end
      RUBY
    end

    it "answers an explicit receiver as well as an implicit self" do
      expect(dumps(<<~RUBY)).to eq(["String"])
        class MyError < StandardError; end
        dump_type(MyError.new("x").message)
      RUBY
    end
  end

  describe "type variables" do
    # The receiver is `Nominal[SubHash]` with no type arguments, so `Hash[K, V]`'s variables degrade
    # per the translator's contract. That is what a raw `Hash` receiver already answers — honest
    # rather than a loss, and deliberately NOT an attempt to infer the subclass's element types.
    it "degrades a generic return to Dynamic[top] rather than guessing the element type" do
      expect(dumps(<<~RUBY)).to eq(["Array[Dynamic[top]]"])
        class SubHash < Hash
          def probe
            dump_type(keys)
          end
        end
      RUBY
    end
  end

  describe "the declines" do
    it "leaves a subclass of a gem class with no RBS on Dynamic[top]" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        class MyController < ActionController::Base
          def probe
            dump_type(params)
          end
        end
      RUBY
    end

    it "leaves a subclass of an RBS-SHIPPING gem on Dynamic[top] — that is slice 3's question" do
      expect(dumps(<<~RUBY, prelude: %(require "prism"\n))).to eq(["Dynamic[top]"])
        class MyVisitor < Prism::Visitor
          def probe
            dump_type(visit(nil))
          end
        end
      RUBY
    end

    it "yields to the subclass's own def" do
      expect(dumps(<<~RUBY)).to eq(["42"])
        class Overrider < Hash
          def has_key?(key) = 42

          def probe
            dump_type(has_key?(:a))
          end
        end
      RUBY
    end

    it "yields to a def on a nearer SOURCE ancestor" do
      expect(dumps(<<~RUBY)).to eq(["42"])
        class Middle < Hash
          def has_key?(key) = 42
        end

        class Leaf < Middle
          def probe
            dump_type(has_key?(:a))
          end
        end
      RUBY
    end

    # The blocker the first draft shipped: CRuby PRESERVES the subclass where core/stdlib RBS names
    # the base class, so adopting the declaration answered `Nominal[Hash]` for a value that is a
    # `SubHash` — and because `Hash` is RBS-known, the negative rules read it as a closed surface and
    # fired `call.undefined-method` on working code one hop downstream. Verified against the
    # interpreter: each of these really does return the subclass at runtime.
    it "declines a declaration that returns the walked ancestor or one of its own RBS ancestors" do
      types = dumps(<<~RUBY, prelude: %(require "set"\nrequire "pathname"\nrequire "date"\n))
        class SubHash < Hash
          def probe = dump_type(merge({}))
        end

        class SubSet < Set
          def probe = dump_type(flatten)
        end

        class SubPath < Pathname
          def probe = dump_type(basename)
        end

        class SubDate < Date
          def probe = dump_type(self + 1)
        end
      RUBY
      expect(types).to eq(["Dynamic[top]"] * 4)
    end

    # The same defect one level down, inside a type ARGUMENT. `Pathname#children: () ->
    # Array[Pathname]` hands back an array of SUBCLASS instances — verified against the interpreter,
    # as are `entries`, `each_child`, `ascend`, `descend` and `find`; only `glob` yields a plain
    # `Pathname`. A first draft unwrapped only the top level and fired here.
    it "declines when the owner appears inside a type argument, not only at the top level" do
      types = dumps(<<~RUBY, prelude: %(require "pathname"\n))
        class SubPath < Pathname
          def probe
            dump_type(children)
            dump_type(children.first)
          end
        end
      RUBY
      expect(types).to eq(["Dynamic[top]", "Dynamic[top]"])
    end

    it "fires nothing downstream of a nested owner return either" do
      source = <<~RUBY
        require "pathname"

        class SubPath < Pathname
          def extra = 1

          def probe
            children.first.extra
            children.each { |c| c.extra }
            each_child { |c| c.extra }
            ascend.first.extra
          end
        end
      RUBY
      expect(rules(source)).not_to include("call.undefined-method")
    end

    it "fires nothing downstream of such a return — the ADR-5 case that forced the decline" do
      source = <<~RUBY
        require "pathname"

        class SubHash < Hash
          def extra = 1
          def probe = merge({}).extra
        end

        class SubPath < Pathname
          def extra = 1
          def probe = basename.extra
        end
      RUBY
      expect(rules(source)).not_to include("call.undefined-method")
    end

    it "declines a name owned by Object or Kernel, which sit at or after a top-level def's MRO rung" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        class SubHash < Hash
          def probe
            dump_type(instance_variable_get(:@x))
          end
        end
      RUBY
    end

    # Slice 2's territory: `include Enumerable` / `include Comparable` on a source class. This slice
    # walks the SUPERCLASS chain only, so the include stays opaque and the slices stay attributable.
    it "does not follow an include into a core module" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        class Counted
          include Comparable
          def <=>(other) = 0

          def probe
            dump_type(clamp(1, 2))
          end
        end
      RUBY
    end

    # Issue #992's surface mark. `ScopeIndexer` records a `Klass.include(M)` written outside the class
    # body because it can add members the in-body walks never see; `#992`'s arity rule already declines
    # on it, and so must this.
    it "declines a class an outside-the-body include or prepend can have widened" do
      expect(dumps(<<~RUBY)).to eq(["Dynamic[top]"])
        module Ext
          def empty? = 42
        end

        class Extended < Hash; end
        Extended.include(Ext)

        def probe = dump_type(Extended.new.empty?)
      RUBY
    end

    # ADR-17. The patch sits on an INTERMEDIATE source ancestor, which the first draft missed: it
    # asked only the receiver and the OWNER's RBS ancestors, so `Leaf` adopted `Hash#key?` while the
    # method that runs is `Middle#key?` from the `pre_eval:` file.
    it "declines when a pre_eval patch redefines the name on a source ancestor between the two" do
      result = analyze(
        files: {
          "app.rb" => <<~RUBY,
            require "rigor/testing"
            include Rigor::Testing

            class Middle < Hash; end

            class Leaf < Middle
              def probe = dump_type(key?(:a))
            end
          RUBY
          "patch.rb" => <<~RUBY
            class Middle
              def key?(other) = 42
            end
          RUBY
        },
        config: { "paths" => %w[app.rb], "pre_eval" => %w[patch.rb] }
      )
      types = result.diagnostics.filter_map do |d|
        d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type")
      end
      expect(types).to eq(["Dynamic[top]"])
    end

    it "leaves the constructor and the receiver carrier alone" do
      expect(dumps(<<~RUBY)).to eq(%w[SubHash SubStr])
        class SubHash < Hash; end
        class SubStr < String; end
        dump_type(SubHash.new)
        dump_type(SubStr.new)
      RUBY
    end
  end

  # The reframed false-positive boundary (ADR-114). ADR-43 declined blanket inherited resolution
  # because firing `call.undefined-method` against a partial RBS "would frighten working code". That
  # wall is not reachable through dispatch: `undefined_method_diagnostic` and `arity_envelope_for` gate
  # on `Reflection.rbs_class_known?` of the RECEIVER, which a Ruby-source subclass never is. What this
  # slice can do instead is propagate a WRONG PRECISE TYPE one hop, and fire there.
  describe "the negative rules" do
    it "stays silent on a bogus call and a wrong arity against the subclass itself" do
      source = <<~RUBY
        class SubHash < Hash
          def probe
            bogus_method_that_does_not_exist
            has_key?(:a, :b)
          end
        end
      RUBY
      expect(rules(source)).not_to include("call.undefined-method", "call.wrong-arity")
    end

    it "stays silent on the same misuse through an explicit receiver" do
      source = <<~RUBY
        class MyError < StandardError; end

        def probe
          e = MyError.new("x")
          e.totally_bogus
          e.message(1, 2)
        end
      RUBY
      expect(rules(source)).not_to include("call.undefined-method", "call.wrong-arity")
    end

    it "DOES fire one hop downstream, where the newly precise type is the receiver" do
      source = <<~RUBY
        class MyError < StandardError; end

        def probe
          MyError.new("x").message.bogus_downstream
        end
      RUBY
      expect(rules(source)).to include("call.undefined-method")
    end

    # The positive neighbour for the two silences above: the same misuse on a direct core receiver has
    # always fired and must keep firing, or those silences would prove nothing.
    it "keeps firing on a direct core receiver" do
      expect(rules(%({}.bogus_method_that_does_not_exist))).to include("call.undefined-method")
      expect(rules(%("x".bogus_method_that_does_not_exist))).to include("call.undefined-method")
    end
  end
end
