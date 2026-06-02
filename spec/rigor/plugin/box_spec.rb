# frozen_string_literal: true

require "spec_helper"

# ADR-39 slice 5 — the Ruby::Box isolation boundary for target-library
# invocation. The box is opt-in (`RUBY_BOX=1` at process start), so the
# default suite runs with it OFF: the box-only examples skip unless the
# feature is active, and the off-path examples confirm the default
# (non-box) behaviour is unchanged. To exercise the box path:
#   RUBY_BOX=1 bundle exec rspec spec/rigor/plugin/box_spec.rb
RSpec.describe Rigor::Plugin::Box do
  describe ".enabled?" do
    it "reflects whether the Ruby::Box feature is active for this process" do
      expected = defined?(Ruby::Box) && Ruby::Box.respond_to?(:enabled?) && Ruby::Box.enabled?
      expect(described_class.enabled?).to be(expected)
    end
  end

  context "when Ruby::Box is NOT active (default)", unless: described_class.enabled? do
    it "is disabled, so consumers keep their non-box path" do
      expect(described_class.enabled?).to be(false)
    end

    it "Plugin::Inflector still resolves via the main-space path" do
      expect(Rigor::Plugin::Inflector.pluralize("person")).to eq("people")
    end
  end

  context "when Ruby::Box is active (RUBY_BOX=1)", if: described_class.enabled? do
    it "loads a target library inside the box, not the main space" do
      expect(described_class.require_feature("active_support/inflector")).to be(true)
      # The shared box answers the call...
      expect(described_class.eval("ActiveSupport::Inflector.pluralize(\"person\")")).to eq("people")
      # ...without ActiveSupport leaking into Rigor's main space.
      expect(defined?(ActiveSupport)).to be_nil
    end

    it "routes Plugin::Inflector through the box (arg passed safely)" do
      expect(Rigor::Plugin::Inflector.pluralize("analysis")).to eq("analyses")
      expect(Rigor::Plugin::Inflector.underscore("Admin::DomainBlocksController"))
        .to eq("admin/domain_blocks_controller")
      expect(defined?(ActiveSupport)).to be_nil
    end
  end
end
