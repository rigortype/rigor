# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Scope::DiscoveryIndex do
  describe ".declares_surface?" do
    it "reads a per-method entry and the module mark as declaring" do
      expect(described_class.declares_surface?({ %i[instance a] => :opaque })).to be(true)
      expect(described_class.declares_surface?({ described_class::ENVELOPE_MODULE_MARK => :opaque })).to be(true)
    end

    # Issue #2901 — a class-body call on `self`, or a method that runs a computed `define_method`, names no member.
    it "does not read a class-macro body call or computed definer entry as declaring" do
      bucket = { %i[body_call my_attr] => :opaque, %i[computed_definer singleton my_attr] => :opaque,
                 described_class::ENVELOPE_REFINED_MARK => :opaque }

      expect(described_class.declares_surface?(bucket)).to be(false)
    end
  end
end
