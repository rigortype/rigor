# frozen_string_literal: true

require "spec_helper"

# ADR-116 C4 — `ExpressionTyper::PerElementAssemblers` turns the per-position results of a block folded once per Tuple
# position into the call's type. They are pure functions over lists of types, so the examples build the lists with
# `Type::Combinator` and call the one entry, `assemble_per_element_result`, with no `Scope` and no typer.
#
# `elements` is the receiver's element types (`[1, "a", :b]`); `per_position` is what the block answered at each.
RSpec.describe Rigor::Inference::ExpressionTyper::PerElementAssemblers do
  let(:combinator) { Rigor::Type::Combinator }
  let(:elements) { [combinator.constant_of(1), combinator.constant_of("a"), combinator.constant_of(:b)] }
  let(:integer) { combinator.nominal_of("Integer") }

  def const(value) = combinator.constant_of(value)

  def assemble(name, per_position, element_types = elements)
    described_class.assemble_per_element_result(name, per_position, element_types)
  end

  def describe_of(type) = type&.describe

  describe ".assemble_per_element_result" do
    it "answers nil for a method the table does not name" do
      expect(assemble(:each, [const(true), const(true), const(true)])).to be_nil
    end

    it "assembles map and its alias as the Tuple of the per-position results" do
      per_position = [integer, const("x"), const(nil)]

      expect(describe_of(assemble(:map, per_position))).to eq(describe_of(combinator.tuple_of(*per_position)))
      expect(describe_of(assemble(:collect, per_position))).to eq(describe_of(assemble(:map, per_position)))
    end

    describe "select / filter / find_all and reject" do
      let(:decided) { [const(true), const(false), const(1)] }

      it "keeps the receiver elements whose result is truthy for select and its aliases" do
        expected = describe_of(combinator.tuple_of(elements[0], elements[2]))

        %i[select filter find_all].each do |name|
          expect(describe_of(assemble(name, decided))).to eq(expected)
        end
      end

      it "keeps the receiver elements whose result is falsey for reject" do
        expect(describe_of(assemble(:reject, [const(true), const(nil), const(1)])))
          .to eq(describe_of(combinator.tuple_of(elements[1])))
      end

      it "declines when any position is not a Constant, since the survivors' count is unknown" do
        undecided = [const(true), integer, const(false)]

        expect(assemble(:select, undecided)).to be_nil
        expect(assemble(:reject, undecided)).to be_nil
      end

      it "answers the empty Tuple when no position survives" do
        expect(describe_of(assemble(:select, [const(false), const(nil), const(false)])))
          .to eq(describe_of(combinator.tuple_of))
      end
    end

    describe "take_while and drop_while" do
      it "cut at the first falsey Constant after truthy ones" do
        per_position = [const(true), const(false), const(true)]

        expect(describe_of(assemble(:take_while, per_position))).to eq(describe_of(combinator.tuple_of(elements[0])))
        expect(describe_of(assemble(:drop_while, per_position)))
          .to eq(describe_of(combinator.tuple_of(elements[1], elements[2])))
      end

      it "takes every element, and drops none, when every position is a truthy Constant" do
        per_position = [const(1), const(2), const(3)]

        expect(describe_of(assemble(:take_while, per_position))).to eq(describe_of(combinator.tuple_of(*elements)))
        expect(describe_of(assemble(:drop_while, per_position))).to eq(describe_of(combinator.tuple_of))
      end

      it "declines when an undecided position precedes the stopping point" do
        expect(assemble(:take_while, [integer, const(false), const(true)])).to be_nil
        expect(assemble(:drop_while, [const(true), integer, const(false)])).to be_nil
      end

      it "declines when no position is falsey and one is undecided" do
        expect(assemble(:take_while, [const(true), integer, const(true)])).to be_nil
      end

      it "decides at the first falsey Constant even when a later position is undecided" do
        expect(describe_of(assemble(:take_while, [const(true), const(nil), integer])))
          .to eq(describe_of(combinator.tuple_of(elements[0])))
      end
    end

    describe "partition" do
      it "splits the receiver elements into the truthy and the falsey Tuple" do
        expect(describe_of(assemble(:partition, [const(true), const(false), const(1)])))
          .to eq(describe_of(combinator.tuple_of(combinator.tuple_of(elements[0], elements[2]),
                                                 combinator.tuple_of(elements[1]))))
      end

      it "declines when any position is not a Constant" do
        expect(assemble(:partition, [const(true), integer, const(false)])).to be_nil
      end
    end

    describe "count" do
      it "counts the truthy Constant positions" do
        expect(describe_of(assemble(:count, [const(true), const(nil), const(1)]))).to eq("2")
      end

      it "declines when any position is not a Constant" do
        expect(assemble(:count, [const(true), integer, const(1)])).to be_nil
      end
    end

    describe "filter_map" do
      it "keeps the per-position results that are neither nil nor false, in order" do
        per_position = [const(1), const(nil), const(false), const("x")]

        expect(describe_of(assemble(:filter_map, per_position, per_position)))
          .to eq(describe_of(combinator.tuple_of(const(1), const("x"))))
      end

      it "declines when any position is not a Constant" do
        expect(assemble(:filter_map, [const(1), integer, const(2)])).to be_nil
      end
    end

    describe "flat_map and collect_concat" do
      it "concatenates a Tuple result and contributes a scalar Constant as one element" do
        per_position = [combinator.tuple_of(const(1), const(2)), const(3), combinator.tuple_of]
        expected = describe_of(combinator.tuple_of(const(1), const(2), const(3)))

        expect(describe_of(assemble(:flat_map, per_position))).to eq(expected)
        expect(describe_of(assemble(:collect_concat, per_position))).to eq(expected)
      end

      it "declines when a result is neither a Tuple nor a Constant" do
        array_of_integer = combinator.nominal_of(Array, type_args: [integer])

        expect(assemble(:flat_map, [combinator.tuple_of(const(1)), array_of_integer])).to be_nil
      end
    end

    describe "find and detect" do
      it "answers the element at the first truthy position" do
        per_position = [const(false), const(1), const(true)]

        expect(describe_of(assemble(:find, per_position))).to eq("\"a\"")
        expect(describe_of(assemble(:detect, per_position))).to eq("\"a\"")
      end

      it "joins the elements of the undecided positions before the first truthy one" do
        expect(describe_of(assemble(:find, [integer, const(false), const(true)])))
          .to eq(describe_of(combinator.union(elements[0], elements[2])))
      end

      it "answers nil when every position is falsey" do
        expect(describe_of(assemble(:find, [const(false), const(nil), const(false)]))).to eq("nil")
      end

      it "declines when an undecided position has no truthy one after it" do
        expect(assemble(:find, [const(false), integer, const(false)])).to be_nil
      end

      it "does not join undecided positions after the first truthy one" do
        expect(describe_of(assemble(:find, [const(true), integer, integer]))).to eq("1")
      end
    end

    describe "rfind" do
      it "answers the element at the last truthy position" do
        expect(describe_of(assemble(:rfind, [const(true), const(1), const(false)]))).to eq("\"a\"")
      end

      it "joins the elements of the undecided positions after the last truthy one" do
        expect(describe_of(assemble(:rfind, [const(true), const(false), integer])))
          .to eq(describe_of(combinator.union(elements[0], elements[2])))
      end

      it "answers nil when every position is falsey and declines on an undecided one without a truthy" do
        expect(describe_of(assemble(:rfind, [const(false), const(false), const(nil)]))).to eq("nil")
        expect(assemble(:rfind, [integer, const(false), const(false)])).to be_nil
      end
    end

    describe "find_index, index and rindex" do
      it "answers the index of the first truthy position, as a Constant" do
        per_position = [const(false), const(true), const(true)]

        expect(describe_of(assemble(:find_index, per_position))).to eq("1")
        expect(describe_of(assemble(:index, per_position))).to eq("1")
      end

      it "joins the indices of undecided positions before the first truthy one" do
        expect(describe_of(assemble(:find_index, [integer, const(false), const(true)])))
          .to eq(describe_of(combinator.union(const(0), const(2))))
      end

      it "answers nil when nothing matches and declines on an undecided position without a truthy one" do
        expect(describe_of(assemble(:find_index, [const(false), const(nil), const(false)]))).to eq("nil")
        expect(assemble(:find_index, [const(false), integer, const(false)])).to be_nil
      end

      it "answers the index of the last truthy position for rindex" do
        expect(describe_of(assemble(:rindex, [const(true), const(true), const(false)]))).to eq("1")
        expect(describe_of(assemble(:rindex, [const(true), const(false), integer])))
          .to eq(describe_of(combinator.union(const(0), const(2))))
        expect(describe_of(assemble(:rindex, [const(false), const(false), const(false)]))).to eq("nil")
        expect(assemble(:rindex, [integer, const(false), const(false)])).to be_nil
      end
    end

    it "treats `false` and `nil` as the only falsey values" do
      expect(describe_of(assemble(:select,
                                  [const(0), const(""), const(:s)]))).to eq(describe_of(combinator.tuple_of(*elements)))
    end
  end
end
