# frozen_string_literal: true

require "spec_helper"

# ADR-116 C4 — {Rigor::Inference::Narrowing::ClassDispatch.narrow_class_dispatch} on plain `Rigor::Type` values: no
# `Scope`, no runner, no RBS load. The context is the four-field record `Narrowing.narrow_class` builds (`exact`,
# `polarity`, `environment`, `scope`); the module reads each through its accessor only, so a `Struct` of the same
# fields stands in for it. The environment is a table (`ancestry`, below) answering the three questions the module
# asks of it — `class_ordering`, `rbs_module?` and `singleton_extended_modules` — and the one `scope` read
# (`singleton_extends_of`) is a stub over another table. `narrowing_spec.rb` and the
# `spec/integration/unreachable_clause_*` specs pin the same arms against the real `Environment`, through
# `narrow_class`, `narrow_not_class` and a whole run.
#
# The table: `Base`, `Derived < Base`, `Sibling < Base`, the modules `Taggable` and `Meta`, `Widget` (which the
# "signature" says extends `Meta`), and the core names a `Constant` or shape projects to. `Missing` is a name the table
# cannot order, which is the `:unknown` ordering of #657.
#
# Mutation-proved: each guard line (a `return` modifier) of `class_dispatch.rb` was blanked in turn and an example here
# failed, except four that no input distinguishes:
#
# - `singleton_extend_declines_bot?`'s `return false if extended.empty?`: `[].any?` is false on the next line, so the
#   guard only saves the block.
# - `singleton_ancestor_modules`'s `return from_source if from_rbs.empty?` and `return from_rbs if from_source.empty?`:
#   `from_source | from_rbs` answers the same modules (only their order differs, and `any?` does not read it). Tried:
#   a scope record alone, a signature record alone, both, and neither.
# - `class_ordering`'s `return :equal if lhs == rhs`: `Environment#class_ordering` answers `:equal` for equal names
#   itself, and so does the table here. Tried: each carrier under its own class, positive, negative and `instance_of?`.
#
# `singleton_ancestor_modules`'s `context.environment&.` nil arm is unreachable through the entry:
# `narrow_singleton_to_class` asks `subclass_of?` and `declines_bot?` of the environment first, and a nil one raises
# there.
RSpec.describe Rigor::Inference::Narrowing::ClassDispatch do
  let(:ancestry) do
    {
      "Integer" => %w[Integer Numeric Comparable Object], "Numeric" => %w[Numeric Comparable Object],
      "String" => %w[String Comparable Object], "Array" => %w[Array Enumerable Object],
      "Hash" => %w[Hash Enumerable Object], "Class" => %w[Class Module Object], "Module" => %w[Module Object],
      "Base" => %w[Base Object], "Derived" => %w[Derived Base Object], "Sibling" => %w[Sibling Base Object],
      "Widget" => %w[Widget Object], "Gadget" => %w[Gadget Object], "NilClass" => %w[NilClass Object],
      "Taggable" => %w[Taggable], "Meta" => %w[Meta], "Comparable" => %w[Comparable], "Enumerable" => %w[Enumerable]
    }.freeze
  end

  let(:context_class) { Struct.new(:exact, :polarity, :environment, :scope) }
  let(:scope_class) do
    Struct.new(:extends) do
      def singleton_extends_of(class_name) = extends.fetch(class_name, [])
    end
  end
  let(:environment_class) do
    Struct.new(:ancestry) do
      def class_ordering(lhs, rhs)
        return :equal if lhs == rhs

        left = ancestry[lhs]
        right = ancestry[rhs]
        return :unknown if left.nil? || right.nil?
        return :subclass if left.include?(rhs)
        return :superclass if right.include?(lhs)

        :disjoint
      end

      def rbs_module?(name) = %w[Taggable Meta Comparable Enumerable Moddy].include?(name)

      def singleton_extended_modules(name) = name == "Widget" ? ["Meta"] : []
    end
  end
  let(:environment) { environment_class.new(ancestry) }

  def combinator = Rigor::Type::Combinator
  def bot = combinator.bot

  def const(value) = combinator.constant_of(value)
  def nominal(name) = combinator.nominal_of(name)

  def positive(type, class_name, exact: false, scope: nil)
    described_class.narrow_class_dispatch(type, class_name, context_class.new(exact, :positive, environment, scope))
  end

  def negative(type, class_name, exact: false, scope: nil)
    described_class.narrow_class_dispatch(type, class_name, context_class.new(exact, :negative, environment, scope))
  end

  describe "a Constant" do
    it "stays under a class it is an instance of, and is lost under an unrelated one" do
      expect(positive(const(1), "Integer")).to eq(const(1))
      expect(positive(const(1), "Numeric")).to eq(const(1))
      expect(positive(const(1), "String")).to eq(bot)
    end

    it "becomes Dynamic under a class the environment cannot order" do
      expect(positive(const(1), "Missing")).to eq(combinator.untyped)
    end

    it "is lost under `instance_of?` of a different class, even an unknown one" do
      expect(positive(const(1), "Numeric", exact: true)).to eq(bot)
      expect(positive(const(1), "Missing", exact: true)).to eq(bot)
      expect(positive(const(1), "Integer", exact: true)).to eq(const(1))
    end

    it "is removed by the negative edge of a class it belongs to, and kept otherwise" do
      expect(negative(const(1), "Integer")).to eq(bot)
      expect(negative(const(1), "Comparable")).to eq(bot)
      expect(negative(const(1), "String")).to eq(const(1))
      expect(negative(const(1), "Missing")).to eq(const(1))
    end
  end

  describe "a Nominal" do
    it "is kept under its own class" do
      expect(positive(nominal("Base"), "Base")).to eq(nominal("Base"))
      expect(positive(nominal("Base"), "Base", exact: true)).to eq(nominal("Base"))
    end

    it "is kept under an ancestor and narrowed down under a descendant" do
      expect(positive(nominal("Derived"), "Base")).to eq(nominal("Derived"))
      expect(positive(nominal("Base"), "Derived")).to eq(nominal("Derived"))
    end

    it "is lost under a disjoint class" do
      expect(positive(nominal("Derived"), "Sibling")).to eq(bot)
    end

    it "becomes Dynamic under a class the environment cannot order" do
      expect(positive(nominal("Base"), "Missing")).to eq(combinator.untyped)
    end

    it "narrows down to the class under `instance_of?` of a descendant" do
      expect(positive(nominal("Base"), "Derived", exact: true)).to eq(nominal("Derived"))
    end

    it "is lost under `instance_of?` of a module, an ancestor or a disjoint class" do
      expect(positive(nominal("Base"), "Taggable", exact: true)).to eq(bot)
      expect(positive(nominal("Derived"), "Base", exact: true)).to eq(bot)
      expect(positive(nominal("Derived"), "Sibling", exact: true)).to eq(bot)
      expect(positive(nominal("Base"), "Missing", exact: true)).to eq(bot)
    end

    it "is lost under `instance_of?` of a module even when the table orders the module below the nominal's class" do
      # No real environment answers `:superclass` for a module (`Object`, `BasicObject`, `Integer` and `Module`
      # against `Kernel`, `Comparable` and `Enumerable` answer `:subclass` or `:disjoint`), so the module test is only
      # distinguishable with a synthetic ordering: `Moddy` is a module whose ancestry lists `Base`.
      synthetic = environment_class.new(ancestry.merge("Moddy" => %w[Moddy Base]))
      context = context_class.new(true, :positive, synthetic, nil)

      expect(described_class.narrow_class_dispatch(nominal("Base"), "Moddy", context)).to eq(bot)
    end

    it "is removed by the negative edge of its own class and of an ancestor" do
      expect(negative(nominal("Base"), "Base")).to eq(bot)
      expect(negative(nominal("Derived"), "Base")).to eq(bot)
    end

    it "is kept by the negative edge of a descendant, a disjoint class and an unknown one" do
      expect(negative(nominal("Base"), "Derived")).to eq(nominal("Base"))
      expect(negative(nominal("Derived"), "Sibling")).to eq(nominal("Derived"))
      expect(negative(nominal("Base"), "Missing")).to eq(nominal("Base"))
    end

    it "is kept by the negative edge of `instance_of?` of an ancestor, and removed by its own class" do
      expect(negative(nominal("Derived"), "Base", exact: true)).to eq(nominal("Derived"))
      expect(negative(nominal("Derived"), "Derived", exact: true)).to eq(bot)
    end
  end

  describe "a Union" do
    it "narrows each member under the positive edge" do
      union = combinator.union(nominal("Derived"), nominal("Sibling"), const(nil))

      expect(positive(union, "Derived")).to eq(nominal("Derived"))
    end

    it "narrows each member under the negative edge" do
      union = combinator.union(nominal("Derived"), nominal("Sibling"), const(nil))

      expect(negative(union, "Base")).to eq(const(nil))
    end
  end

  describe "a Tuple and a HashShape" do
    let(:tuple) { combinator.tuple_of(nominal("Integer")) }
    let(:shape) { combinator.hash_shape_of({ a: nominal("Integer") }) }

    it "keeps a Tuple under Array and its ancestors, and a HashShape under Hash" do
      expect(positive(tuple, "Array")).to eq(tuple)
      expect(positive(tuple, "Enumerable")).to eq(tuple)
      expect(positive(shape, "Hash")).to eq(shape)
      expect(positive(shape, "Enumerable")).to eq(shape)
    end

    it "loses a Tuple under Hash and a HashShape under Array" do
      expect(positive(tuple, "Hash")).to eq(bot)
      expect(positive(shape, "Array")).to eq(bot)
    end

    it "makes a shape Dynamic under a class the environment cannot order" do
      expect(positive(tuple, "Missing")).to eq(combinator.untyped)
      expect(positive(shape, "Missing")).to eq(combinator.untyped)
    end

    it "loses a shape under `instance_of?` of a class other than its projection" do
      expect(positive(tuple, "Enumerable", exact: true)).to eq(bot)
      expect(positive(tuple, "Array", exact: true)).to eq(tuple)
    end

    it "removes a shape on the negative edge of its projection's class, and keeps it otherwise" do
      expect(negative(tuple, "Array")).to eq(bot)
      expect(negative(tuple, "Hash")).to eq(tuple)
      expect(negative(shape, "Hash")).to eq(bot)
      expect(negative(shape, "Array")).to eq(shape)
    end
  end

  describe "a Singleton" do
    let(:widget) { combinator.singleton_of("Widget") }

    it "is kept under Class and Module, which a class object is an instance of" do
      expect(positive(widget, "Class")).to eq(widget)
      expect(positive(widget, "Module")).to eq(widget)
    end

    it "is lost under a class that no class object is an instance of" do
      expect(positive(widget, "Base")).to eq(bot)
    end

    it "becomes Dynamic under a class the environment cannot order against Class" do
      expect(positive(combinator.singleton_of("Gadget"), "Missing")).to eq(combinator.untyped)
    end

    it "is removed by the negative edge of Class and kept by an unrelated class" do
      expect(negative(widget, "Class")).to eq(bot)
      expect(negative(widget, "Base")).to eq(widget)
    end

    context "with a module the class object extends (#898)" do
      it "becomes Dynamic when the source record says the extended module is the target (`:equal`)" do
        scope = scope_class.new({ "Widget" => ["Taggable"] })

        expect(positive(widget, "Taggable", scope: scope)).to eq(combinator.untyped)
      end

      it "becomes Dynamic when the extended module is below the target (`:subclass`)" do
        scope = scope_class.new({ "Widget" => ["Derived"] })

        expect(positive(widget, "Base", scope: scope)).to eq(combinator.untyped)
      end

      it "becomes Dynamic when the extended module cannot be ordered against the target (`:unknown`)" do
        scope = scope_class.new({ "Widget" => ["Missing"] })

        expect(positive(widget, "Base", scope: scope)).to eq(combinator.untyped)
      end

      it "stays lost when the extended module is above the target or disjoint from it" do
        above = scope_class.new({ "Widget" => ["Base"] })
        disjoint = scope_class.new({ "Widget" => ["Integer"] })

        expect(positive(widget, "Derived", scope: above)).to eq(bot)
        expect(positive(widget, "Base", scope: disjoint)).to eq(bot)
      end

      it "reads the signature's `extend` when the scope records none" do
        scope = scope_class.new({})

        expect(positive(widget, "Meta", scope: scope)).to eq(combinator.untyped)
      end

      it "reads the signature's `extend` with no scope at all" do
        expect(positive(widget, "Meta")).to eq(combinator.untyped)
      end

      it "reads both records together" do
        scope = scope_class.new({ "Widget" => ["Taggable"] })

        expect(positive(widget, "Taggable", scope: scope)).to eq(combinator.untyped)
        expect(positive(widget, "Meta", scope: scope)).to eq(combinator.untyped)
      end

      it "reads the source record alone for a class the signature does not know" do
        scope = scope_class.new({ "Gadget" => ["Taggable"] })

        expect(positive(combinator.singleton_of("Gadget"), "Taggable", scope: scope)).to eq(combinator.untyped)
      end

      it "does not consult the extend record under `instance_of?`" do
        scope = scope_class.new({ "Widget" => ["Taggable"] })

        expect(positive(widget, "Taggable", exact: true, scope: scope)).to eq(bot)
      end

      it "does not consult the extend record on the negative edge" do
        scope = scope_class.new({ "Widget" => ["Taggable"] })

        expect(negative(widget, "Taggable", scope: scope)).to eq(widget)
      end

      it "keeps the loss when nothing is extended" do
        scope = scope_class.new({})

        expect(positive(combinator.singleton_of("Base"), "Taggable", scope: scope)).to eq(bot)
      end
    end
  end

  describe "the remaining carriers" do
    it "narrows Top and Dynamic to the class on the positive edge" do
      expect(positive(combinator.top, "Base")).to eq(nominal("Base"))
      expect(positive(combinator.untyped, "Base")).to eq(nominal("Base"))
    end

    it "leaves Bot as it is on the positive edge" do
      expect(positive(bot, "Base")).to eq(bot)
    end

    it "leaves every other carrier as it is on the negative edge" do
      carriers = [combinator.top, combinator.untyped, bot]

      expect(carriers.map { |carrier| negative(carrier, "Base") }).to eq(carriers)
    end
  end
end
