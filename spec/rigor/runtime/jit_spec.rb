# frozen_string_literal: true

require "spec_helper"
require "rigor/runtime/jit"

RSpec.describe Rigor::Runtime::Jit do
  # Snapshot + restore the two env switches this module reads so an example
  # that sets them never leaks state into the rest of the suite.
  around do |example|
    keys = [described_class::DISABLE_ENV, described_class::DEADLINE_ENV]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    keys.each { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Every example that exercises the enable path stubs both YJIT methods so the
  # suite never actually turns YJIT on (it would persist for the process) and so
  # the "already enabled" branch is deterministic regardless of the real state.
  def stub_yjit_off
    allow(RubyVM::YJIT).to receive(:enabled?).and_return(false)
    allow(RubyVM::YJIT).to receive(:enable)
  end

  describe ".available?" do
    it "is true on a Ruby exposing RubyVM::YJIT.enable" do
      skip "YJIT unavailable on this Ruby" unless defined?(RubyVM::YJIT.enable)

      expect(described_class.available?).to be(true)
    end
  end

  describe ".disabled?" do
    it "reflects RIGOR_DISABLE_YJIT=1" do
      ENV[described_class::DISABLE_ENV] = "1"
      expect(described_class.disabled?).to be(true)
    end

    it "is false when the switch is unset or not exactly \"1\"" do
      expect(described_class.disabled?).to be(false)
      ENV[described_class::DISABLE_ENV] = "0"
      expect(described_class.disabled?).to be(false)
    end
  end

  describe ".enable_now" do
    before { skip "YJIT unavailable on this Ruby" unless defined?(RubyVM::YJIT.enable) }

    it "enables YJIT and returns true when available, not disabled, not enabled" do
      stub_yjit_off

      expect(described_class.enable_now).to be(true)
      expect(RubyVM::YJIT).to have_received(:enable)
    end

    it "is a no-op returning false when opted out via RIGOR_DISABLE_YJIT=1" do
      stub_yjit_off
      ENV[described_class::DISABLE_ENV] = "1"

      expect(described_class.enable_now).to be(false)
      expect(RubyVM::YJIT).not_to have_received(:enable)
    end

    it "is a no-op returning false when YJIT is already enabled" do
      allow(RubyVM::YJIT).to receive(:enabled?).and_return(true)
      allow(RubyVM::YJIT).to receive(:enable)

      expect(described_class.enable_now).to be(false)
      expect(RubyVM::YJIT).not_to have_received(:enable)
    end

    it "is a no-op returning false when YJIT is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.enable_now).to be(false)
    end
  end

  describe ".enable_after" do
    before { skip "YJIT unavailable on this Ruby" unless defined?(RubyVM::YJIT.enable) }

    it "spawns a thread that enables YJIT after the delay" do
      stub_yjit_off

      thread = described_class.enable_after(0.01)
      expect(thread).to be_a(Thread)
      thread.join

      expect(RubyVM::YJIT).to have_received(:enable)
    end

    it "does not enable before the deadline elapses (the penalty zone)" do
      stub_yjit_off

      thread = described_class.enable_after(5)
      # Immediately after arming, the thread is still sleeping — a run that
      # finishes now never pays JIT compile.
      expect(RubyVM::YJIT).not_to have_received(:enable)
      thread.kill
    end

    it "silences background exceptions (report_on_exception is off)" do
      stub_yjit_off

      thread = described_class.enable_after(5)
      expect(thread.report_on_exception).to be(false)
      thread.kill
    end

    it "returns nil and spawns no thread when opted out" do
      allow(RubyVM::YJIT).to receive(:enabled?).and_return(false)
      ENV[described_class::DISABLE_ENV] = "1"

      expect(described_class.enable_after(0.01)).to be_nil
    end

    it "returns nil when YJIT is already enabled" do
      allow(RubyVM::YJIT).to receive(:enabled?).and_return(true)

      expect(described_class.enable_after(0.01)).to be_nil
    end

    it "returns nil when YJIT is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.enable_after(0.01)).to be_nil
    end
  end

  describe ".deadline_seconds" do
    it "defaults to DEFAULT_DEADLINE_SECONDS when the override is unset" do
      expect(described_class.deadline_seconds).to eq(described_class::DEFAULT_DEADLINE_SECONDS)
    end

    it "reads a non-negative float from RIGOR_YJIT_DEADLINE" do
      ENV[described_class::DEADLINE_ENV] = "1.5"
      expect(described_class.deadline_seconds).to eq(1.5)
    end

    it "falls back to the default on an unparseable, empty, or negative value" do
      ["abc", "-2", ""].each do |bad|
        ENV[described_class::DEADLINE_ENV] = bad
        expect(described_class.deadline_seconds).to eq(described_class::DEFAULT_DEADLINE_SECONDS)
      end
    end
  end
end
