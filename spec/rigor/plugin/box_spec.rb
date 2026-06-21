# frozen_string_literal: true

require "spec_helper"

# ADR-39 slice 5 — the Ruby::Box isolation boundary for target-library
# invocation. The box is opt-in (`RUBY_BOX=1` at process start), so the
# default suite runs with it OFF: the box-only examples skip unless the
# feature is active, and the off-path examples confirm the default
# (non-box) behaviour is unchanged. To exercise the box path:
#   RUBY_BOX=1 bundle exec rspec spec/rigor/plugin/box_spec.rb
RSpec.describe Rigor::Plugin::Box do
  # Helper to reset memoized ivars between examples when the box
  # is active, since module_function stores them on the module.
  def reset_box!
    described_class.remove_instance_variable(:@shared) if described_class.instance_variable_defined?(:@shared)
    described_class.remove_instance_variable(:@required) if described_class.instance_variable_defined?(:@required)
  end

  let(:box_instance) { instance_double(Ruby::Box, require: true, eval: "mocked-result") }

  context "when Ruby::Box is stubbed as active" do
    before do
      box_class = Class.new
      stub_const("Ruby::Box", box_class)
      allow(Ruby::Box).to receive_messages(new: box_instance, enabled?: true)
      allow(Ruby::Box).to receive(:respond_to?).with(:enabled?).and_return(true)
      reset_box!
    end

    after { reset_box! }

    describe ".shared" do
      it "creates and returns a new box" do
        expect(described_class.shared).to eq(box_instance)
      end

      it "memoizes the shared box reference" do
        described_class.shared
        described_class.shared
        expect(Ruby::Box).to have_received(:new).once
      end
    end

    describe ".require_feature" do
      it "loads a feature through the shared box" do
        expect(described_class.require_feature("my_gem")).to be(true)
        expect(box_instance).to have_received(:require).with("my_gem")
      end

      it "memoizes the load result" do
        described_class.require_feature("my_gem")
        expect(box_instance).to have_received(:require).once
        described_class.require_feature("my_gem")
        expect(box_instance).to have_received(:require).once
      end

      it "caches a failed load as false" do
        allow(box_instance).to receive(:require).and_raise(StandardError, "load failed")
        expect(described_class.require_feature("missing")).to be(false)
      end
    end

    describe ".eval" do
      it "evaluates code in the shared box" do
        expect(described_class.eval("1+1")).to eq("mocked-result")
      end
    end
  end

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
