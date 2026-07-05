# frozen_string_literal: true

require "spec_helper"

# ADR-39 slice 5 — the selectable isolation strategy for target-library invocation (none / ruby_box / process). The
# strategy is read from `RIGOR_PLUGIN_ISOLATION`; examples set it per-case. `process` (fork) is exercised directly;
# `ruby_box` needs `RUBY_BOX=1` at process start, so those examples skip unless the feature is active.
RSpec.describe Rigor::Plugin::Isolation do
  let(:feature) { "active_support/inflector" }
  let(:inflector) { "ActiveSupport::Inflector" }

  around do |example|
    original = ENV.fetch("RIGOR_PLUGIN_ISOLATION", nil)
    described_class::Process.instance_variable_set(:@worker, nil)
    example.run
  ensure
    original.nil? ? ENV.delete("RIGOR_PLUGIN_ISOLATION") : (ENV["RIGOR_PLUGIN_ISOLATION"] = original)
    described_class::Process.instance_variable_set(:@worker, nil)
  end

  def with_strategy(name)
    ENV["RIGOR_PLUGIN_ISOLATION"] = name
    expect(described_class.strategy_name).to eq(name)
    yield
  end

  describe "strategy selection" do
    it "defaults to process for unset / unrecognised values" do
      ENV.delete("RIGOR_PLUGIN_ISOLATION")
      expect(described_class.strategy_name).to eq("process")
    end

    it "falls back to Direct when fork is unavailable", unless: Process.respond_to?(:fork) do
      ENV.delete("RIGOR_PLUGIN_ISOLATION")
      expect(described_class.backend).to eq(described_class::Direct)
    end

    it "uses the Process backend by default where fork is available", if: Process.respond_to?(:fork) do
      ENV.delete("RIGOR_PLUGIN_ISOLATION")
      expect(described_class.backend).to eq(described_class::Process)
    end
  end

  describe "none (explicit, direct)" do
    it "calls the real library directly in the main space" do
      with_strategy("none") do
        expect(described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["person"]))
          .to eq("people")
      end
    end
  end

  describe "direct (no isolation) — error path" do
    it "raises Unavailable when a resolved constant is not found" do
      expect do
        described_class::Direct.call(feature: feature, receiver: "NonExistentConst", method: :x, args: [])
      end.to raise_error(described_class::Unavailable)
    end
  end

  describe "process (fork)", if: Process.respond_to?(:fork) do
    it "calls the library in a forked worker and returns the result" do
      with_strategy("process") do
        expect(described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["analysis"]))
          .to eq("analyses")
        # A second call reuses the persistent worker.
        expect(described_class.call(feature: feature, receiver: inflector, method: :singularize, args: ["categories"]))
          .to eq("category")
      end
    end

    # The worker is forked ONCE and reused — never one fork per call.
    it "forks a single persistent worker across many calls" do
      with_strategy("process") do
        described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
        first_pid = described_class::Process.instance_variable_get(:@worker).fetch(:pid)

        10.times do |i|
          described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["word#{i}"])
        end

        later_pid = described_class::Process.instance_variable_get(:@worker).fetch(:pid)
        expect(later_pid).to eq(first_pid) # same worker — no per-call fork
      end
    end

    it "raises Unavailable when the worker call errors (no crash)" do
      with_strategy("process") do
        expect { described_class.call(feature: feature, receiver: "Nonexistent::Const", method: :x, args: []) }
          .to raise_error(described_class::Unavailable, /worker error/)
      end
    end

    # The whole point of process isolation: a worker crash is contained — the parent survives, declines, and recovers on
    # the next call.
    it "contains a worker crash and recovers" do
      with_strategy("process") do
        described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
        pid = described_class::Process.instance_variable_get(:@worker).fetch(:pid)
        Process.kill("KILL", pid)
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end

        expect { described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"]) }
          .to raise_error(described_class::Unavailable)
        # The parent is alive and respawns a fresh worker on the next call.
        expect(described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"]))
          .to eq("posts")
      end
    end
  end

  describe "ruby_box", if: Rigor::Plugin::Box.enabled? do
    # The no-leak property (boxing does not load the library into the main space) is a process-global negative that
    # other examples in the suite pollute, so it is asserted in box_spec (run standalone) rather than here; this checks
    # the strategy returns the correct result.
    it "answers correctly through the box" do
      with_strategy("ruby_box") do
        expect(described_class.call(feature: feature, receiver: inflector, method: :pluralize, args: ["person"]))
          .to eq("people")
        expect(described_class.call(feature: feature, receiver: inflector, method: :singularize, args: ["analyses"]))
          .to eq("analysis")
      end
    end
  end

  # Unit-exercise the RubyBox backend's branches with a stubbed Box, so the error gates and the inspect-rendered
  # expression are covered without the process-global `RUBY_BOX=1` the integration example above requires.
  describe "RubyBox (unit, stubbed Box)" do
    let(:box) { Rigor::Plugin::Box }

    it "raises Unavailable when the Ruby::Box is not active" do
      allow(box).to receive(:enabled?).and_return(false)
      expect do
        described_class::RubyBox.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
      end.to raise_error(described_class::Unavailable, /RUBY_BOX/)
    end

    it "raises Unavailable when the feature cannot be loaded into the box" do
      allow(box).to receive(:enabled?).and_return(true)
      allow(box).to receive(:require_feature).with(feature).and_return(false)
      expect do
        described_class::RubyBox.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
      end.to raise_error(described_class::Unavailable, /could not be loaded/)
    end

    it "evals the inspect-rendered call expression and returns the box result" do
      allow(box).to receive_messages(enabled?: true, require_feature: true)
      allow(box).to receive(:eval).with('ActiveSupport::Inflector.pluralize("post")').and_return("posts")
      result = described_class::RubyBox.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
      expect(result).to eq("posts")
    end

    it "joins multiple inspect-rendered args with ', ' in the expression" do
      allow(box).to receive_messages(enabled?: true, require_feature: true)
      # Two args so the join separator is observable (a single arg renders the same under any separator, masking a
      # dropped/altered one).
      allow(box).to receive(:eval).with('ActiveSupport::Inflector.camelize("a", "b")').and_return("ok")
      result = described_class::RubyBox.call(feature: feature, receiver: inflector, method: :camelize, args: %w[a b])
      expect(result).to eq("ok")
    end
  end

  describe "Process backend (fork unavailable)" do
    it "raises Unavailable when fork is not supported on the platform" do
      allow(described_class::Process).to receive(:available?).and_return(false)
      expect do
        described_class::Process.call(feature: feature, receiver: inflector, method: :pluralize, args: ["post"])
      end.to raise_error(described_class::Unavailable, /fork is not supported/)
    end
  end
end
