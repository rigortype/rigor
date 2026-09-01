# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::JSONFolding do
  def json_singleton = Rigor::Type::Combinator.singleton_of("JSON")
  def c(value) = Rigor::Type::Combinator.constant_of(value)
  def string_t = Rigor::Type::Combinator.nominal_of("String")

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: json_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  # ── generate / pretty_generate ─────────────────────────────────────────

  describe "generate / pretty_generate" do
    it "types JSON.pretty_generate({}) as Nominal[String]" do
      hash_arg = Rigor::Type::Combinator.hash_shape_of({})
      expect(fold(:pretty_generate, hash_arg)).to eq(string_t)
    end

    it "types JSON.generate([]) as Nominal[String]" do
      array_arg = Rigor::Type::Combinator.tuple_of
      expect(fold(:generate, array_arg)).to eq(string_t)
    end

    it "folds regardless of the argument's shape (not a literal-value fold)" do
      expect(fold(:generate, Rigor::Type::Combinator.untyped)).to eq(string_t)
      expect(fold(:generate, c(42))).to eq(string_t)
      expect(fold(:generate, Rigor::Type::Combinator.nominal_of("Object"))).to eq(string_t)
    end

    it "accepts the optional second (options) argument" do
      hash_arg = Rigor::Type::Combinator.hash_shape_of({})
      opts = Rigor::Type::Combinator.hash_shape_of({})
      expect(fold(:pretty_generate, hash_arg, opts)).to eq(string_t)
    end
  end

  # ── decline / edge cases ────────────────────────────────────────────────

  describe "decline cases" do
    it "declines for JSON.parse — an unrelated JSON method stays untyped" do
      expect(fold(:parse, c("{}"))).to be_nil
    end

    it "declines for JSON.dump — another unsupported method" do
      expect(fold(:dump, Rigor::Type::Combinator.hash_shape_of({}))).to be_nil
    end

    it "declines when the argument list is empty" do
      expect(fold(:generate)).to be_nil
    end

    it "declines when given more than two arguments" do
      hash_arg = Rigor::Type::Combinator.hash_shape_of({})
      expect(fold(:generate, hash_arg, hash_arg, hash_arg)).to be_nil
    end

    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: c("JSON"),
                                              method_name: :generate,
                                              args: [Rigor::Type::Combinator.hash_shape_of({})]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a Nominal[JSON] instance receiver (not the singleton)" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.nominal_of("JSON"),
                                              method_name: :generate,
                                              args: [Rigor::Type::Combinator.hash_shape_of({})]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("CGI"),
                                              method_name: :generate,
                                              args: [Rigor::Type::Combinator.hash_shape_of({})]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a Dynamic receiver" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.untyped,
                                              method_name: :generate,
                                              args: [Rigor::Type::Combinator.hash_shape_of({})]
                                            ))
      expect(result).to be_nil
    end
  end
end
