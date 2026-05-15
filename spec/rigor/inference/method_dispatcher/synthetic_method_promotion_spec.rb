# frozen_string_literal: true

require "spec_helper"
require "rigor/environment"
require "rigor/inference/method_dispatcher"
require "rigor/inference/synthetic_method"
require "rigor/inference/synthetic_method_index"

# ADR-16 slice 6a-TierB — precision promotion for Tier B emissions.
# When a SyntheticMethod records its `origin_module` in provenance,
# the dispatcher's `try_synthetic_method` tier redispatches the
# call on `Nominal[origin_module]` via `RbsDispatch.try_dispatch`.
# This promotes Tier B's slice-2b/3b floor `Dynamic[T]` to the
# module's authored RBS return type.
#
# Slice 6a-TierB does NOT promote Tier C emissions — those have no
# `origin_module`. They stay at `Dynamic[T]` until slice 6b routes
# their `return_type:` strings through ADR-13's resolver chain.
# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Rigor::Inference::MethodDispatcher, ".dispatch" do
  # rubocop:enable RSpec/SpecFilePathFormat
  def environment_with(index)
    Rigor::Environment.new(
      rbs_loader: Rigor::Environment::RbsLoader.default,
      synthetic_method_index: index
    )
  end

  def synthetic_for(class_name:, method_name:, provenance:)
    Rigor::Inference::SyntheticMethod.new(
      class_name: class_name,
      method_name: method_name,
      return_type: "untyped",
      kind: :instance,
      provenance: provenance
    )
  end

  describe "Tier B path (origin_module recorded in provenance)" do
    it "promotes the call to the included module's RBS-declared return type" do
      sm = synthetic_for(
        class_name: "FakeUser",
        method_name: :between?,
        provenance: { origin_module: "Comparable" }
      )
      env = environment_with(Rigor::Inference::SyntheticMethodIndex.new(entries: [sm]))

      result = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("FakeUser"),
        method_name: :between?,
        arg_types: [
          Rigor::Type::Combinator.nominal_of("Integer"),
          Rigor::Type::Combinator.nominal_of("Integer")
        ],
        environment: env
      )

      # Comparable#between? is declared as `() -> bool` in core RBS;
      # the precision-promoted dispatcher returns the module's
      # actual return type, NOT the slice-2b/3b floor's untyped.
      expect(result).not_to be_nil
      expect(result).not_to eq(Rigor::Type::Combinator.untyped)
    end

    it "falls back to Dynamic[T] when the origin_module is not in the RBS env" do
      sm = synthetic_for(
        class_name: "FakeUser",
        method_name: :bogus_method,
        provenance: { origin_module: "Does::Not::Exist::Module" }
      )
      env = environment_with(Rigor::Inference::SyntheticMethodIndex.new(entries: [sm]))

      result = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("FakeUser"),
        method_name: :bogus_method,
        arg_types: [], environment: env
      )
      expect(result).to eq(Rigor::Type::Combinator.untyped)
    end

    it "first-wins by registration order when multiple Tier B entries match" do
      first = synthetic_for(
        class_name: "FakeUser", method_name: :between?,
        provenance: { origin_module: "Does::Not::Exist" } # unresolvable — falls through
      )
      second = synthetic_for(
        class_name: "FakeUser", method_name: :between?,
        provenance: { origin_module: "Comparable" } # resolves
      )
      env = environment_with(Rigor::Inference::SyntheticMethodIndex.new(entries: [first, second]))

      result = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("FakeUser"),
        method_name: :between?,
        arg_types: [
          Rigor::Type::Combinator.nominal_of("Integer"),
          Rigor::Type::Combinator.nominal_of("Integer")
        ],
        environment: env
      )
      # The first entry's origin_module doesn't resolve; the
      # promotion walk falls through to the second entry which DOES
      # resolve. End result is the resolved type — NOT untyped.
      expect(result).not_to be_nil
      expect(result).not_to eq(Rigor::Type::Combinator.untyped)
    end
  end

  describe "Tier C path (no origin_module)" do
    it "stays at Dynamic[T] — slice 6b ADR-13 resolver chain is the future precision path" do
      sm = synthetic_for(
        class_name: "Address",
        method_name: :city,
        provenance: { plugin_id: "dry-struct", template_method: "attribute" }
      )
      env = environment_with(Rigor::Inference::SyntheticMethodIndex.new(entries: [sm]))

      result = described_class.dispatch(
        receiver_type: Rigor::Type::Combinator.nominal_of("Address"),
        method_name: :city,
        arg_types: [], environment: env
      )
      expect(result).to eq(Rigor::Type::Combinator.untyped)
    end
  end
end
