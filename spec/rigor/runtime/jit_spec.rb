# frozen_string_literal: true

require "spec_helper"
require "rigor/runtime/jit"

RSpec.describe Rigor::Runtime::Jit do
  # Snapshot + restore the two env switches this module reads so an example
  # that sets them never leaks state into the rest of the suite.
  # The recorded monotonic deadline is module state that outlives an example (and that any earlier spec
  # arming a real deadline would have set), so it is snapshotted and cleared here too.
  around do |example|
    keys = [described_class::DISABLE_ENV, described_class::DEADLINE_ENV]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    keys.each { |k| ENV.delete(k) }
    saved_deadline = described_class.instance_variable_get(:@deadline_at)
    described_class.instance_variable_set(:@deadline_at, nil)
    example.run
  ensure
    described_class.instance_variable_set(:@deadline_at, saved_deadline)
    saved.each do |k, v|
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Pretends the parent armed a window closing `seconds` from now, without sleeping through a real one.
  def arm_deadline_in(seconds)
    described_class.instance_variable_set(
      :@deadline_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    )
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

  # `fork` copies only the calling thread, so a child never inherits the parent's sleeping deadline. Re-arming
  # with a FRESH full deadline (what both fork pools did before) makes every worker sit out the whole window
  # again even though the parent had already burned most of it — warm-up loss paid once per worker. These
  # examples pin the remaining-deadline arithmetic; the deadline is set directly rather than slept through.
  describe ".rearm_after_fork" do
    before { skip "YJIT unavailable on this Ruby" unless defined?(RubyVM::YJIT.enable) }

    it "re-arms with what is LEFT of the parent's window, not a fresh one" do
      stub_yjit_off
      arm_deadline_in(1.25)
      allow(described_class).to receive(:enable_after)

      described_class.rearm_after_fork

      expect(described_class).to have_received(:enable_after).with(be_within(0.25).of(1.25))
    end

    it "honours a deadline recorded by a real .enable_after call" do
      stub_yjit_off
      described_class.enable_after(30).kill
      allow(described_class).to receive(:enable_after)

      described_class.rearm_after_fork

      expect(described_class).to have_received(:enable_after).with(be_within(0.25).of(30))
    end

    it "enables YJIT immediately when the deadline passed while forking" do
      stub_yjit_off
      arm_deadline_in(-0.5)

      expect(described_class.rearm_after_fork).to be_nil
      expect(RubyVM::YJIT).to have_received(:enable)
    end

    it "falls back to a fresh full deadline when the parent never armed one" do
      stub_yjit_off
      allow(described_class).to receive(:enable_after)

      described_class.rearm_after_fork

      expect(described_class).to have_received(:enable_after).with(described_class.deadline_seconds)
    end

    it "is a no-op when YJIT is already enabled (the child inherited it)" do
      allow(RubyVM::YJIT).to receive(:enabled?).and_return(true)
      allow(RubyVM::YJIT).to receive(:enable)
      arm_deadline_in(-0.5)

      expect(described_class.rearm_after_fork).to be_nil
      expect(RubyVM::YJIT).not_to have_received(:enable)
    end

    it "is a no-op when opted out via RIGOR_DISABLE_YJIT=1" do
      stub_yjit_off
      ENV[described_class::DISABLE_ENV] = "1"
      arm_deadline_in(-0.5)

      expect(described_class.rearm_after_fork).to be_nil
      expect(RubyVM::YJIT).not_to have_received(:enable)
    end

    it "is a no-op when YJIT is unavailable" do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.rearm_after_fork).to be_nil
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
