# frozen_string_literal: true

require "spec_helper"

# The meta-introspection tier asked directly, on plain data: what `try_dispatch` reads of the context (receiver,
# selector, arguments, block type, environment) and which lift answers. Each lift's own rules are pinned through
# `MethodDispatcher.dispatch` and the runner, in `method_dispatcher_spec.rb`, `expression_typer_spec.rb`,
# `declared_singleton_new_spec.rb` and `anonymous_class_new_block_body_spec.rb`.
RSpec.describe Rigor::Inference::MethodDispatcher::MetaIntrospection do
  def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
  def class_object(name) = Rigor::Type::Combinator.singleton_of(name)
  def constant(value) = Rigor::Type::Combinator.constant_of(value)

  def dispatch(receiver, method_name, args = [], **rest)
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args, **rest))
  end

  describe "`class`" do
    it "answers the class object for an instance" do
      expect(dispatch(nominal("Foo"), :class)).to eq(class_object("Foo"))
    end

    it "answers the value's class for a constant" do
      expect(dispatch(constant(1), :class)).to eq(class_object("Integer"))
    end

    it "answers Dynamic[Class] for an instance of a module, read from the context's environment" do
      result = dispatch(nominal("Comparable"), :class, environment: Rigor::Environment.default)

      expect(result).to eq(Rigor::Type::Combinator.dynamic(nominal("Class")))
    end
  end

  describe "`new`" do
    it "answers a fresh instance for a class object no lift names" do
      expect(dispatch(class_object("Foo"), :new)).to eq(nominal("Foo"))
    end

    it "declines an instance receiver" do
      expect(dispatch(nominal("Foo"), :new)).to be_nil
    end

    # One row per curated lift: the class, the arguments, and what `describe` prints for the answer.
    {
      "Pathname" => [["a/b"], "#<Pathname:a/b>"],
      "Array" => [[2, 1], "[1, 1]"],
      "Range" => [[1, 3], "1..3"],
      "Set" => [[], "Set[]"],
      "Hash" => [[0], "Hash[Dynamic[top], Integer]"],
      "Regexp" => [["a"], "/a/"],
      "Date" => [[2024, 1, 2], "2024-01-02"],
      "Struct" => [[:a], "singleton(Struct)"],
      "Class" => [[], "singleton(Object)"]
    }.each do |class_name, (values, expected)|
      it "answers the #{class_name} lift" do
        args = values.map { |value| constant(value) }

        expect(dispatch(class_object(class_name), :new, args).describe).to eq(expected)
      end
    end

    it "fills an Array.new tuple from the context's block type" do
      result = dispatch(class_object("Array"), :new, [constant(2)], block_type: nominal("String"))

      expect(result).to eq(Rigor::Type::Combinator.tuple_of(nominal("String"), nominal("String")))
    end
  end

  # A guard: no line of the module pins it, since a selector the `case` does not name falls out of it.
  it "declines every other selector, so the tiers behind it are asked" do
    expect(dispatch(class_object("Foo"), :allocate)).to be_nil
    expect(dispatch(nominal("Foo"), :name)).to be_nil
  end

  describe ".array_new_element, which SetFolding, ShapeDispatch and SetMutation also call" do
    it "drops a value pin and widens a literal container at every depth" do
      nested = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.tuple_of(constant(1)))

      expect(described_class.array_new_element(constant(1))).to eq(nominal("Integer"))
      expect(described_class.array_new_element(nested).describe).to eq("Array[Array[Integer]]")
    end
  end
end
