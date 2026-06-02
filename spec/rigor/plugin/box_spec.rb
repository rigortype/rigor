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
    it "is disabled, so the ruby_box strategy is unavailable" do
      expect(described_class.enabled?).to be(false)
    end
  end

  context "when Ruby::Box is active (RUBY_BOX=1)", if: described_class.enabled? do
    it "loads a target library inside the box, not the main space" do
      expect(described_class.require_feature("active_support/inflector")).to be(true)
      # The shared box answers the call...
      expect(described_class.eval("ActiveSupport::Inflector.pluralize(\"person\")")).to eq("people")
      # ...without ActiveSupport leaking into Rigor's main space. (Guarded:
      # another example in this process may have loaded it via the `none`
      # strategy, which pollutes this process-global check; the no-leak
      # property holds when this spec runs standalone.)
      skip "ActiveSupport already loaded in this process" if defined?(ActiveSupport)
      expect(defined?(ActiveSupport)).to be_nil
    end
  end
end
