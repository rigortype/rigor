# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #352 / ADR-17 — a file listed under `pre_eval:` publishes its top-level constants project-wide, not
# only its patched methods.
#
# Every example runs the SAME two-file project twice — once with the declaring file listed under `pre_eval:`
# and once without — and asserts on both halves. The unlisted half is the regression guard for "a file not
# listed behaves exactly as today"; asserting only the listed half would let a change that publishes
# unconditionally pass.
#
# Each fixture also carries a SAME-FILE positive control in the declaring file, so a cross-file silence can
# never be read as evidence: if the control is missing from the output, the harness stopped measuring the
# engine and the example is void. (`rigor type-of` cannot answer any of this — it parses one file with no
# project-wide pre-pass, so even a plain `class Foo` reads `Dynamic[top]` under it.)
RSpec.describe "pre_eval: constant publication" do
  # Runs `{ "decls.rb" => …, "uses.rb" => … }` as a project and returns the `call.undefined-method` messages.
  # `publish:` toggles ONLY the `pre_eval:` entry — same sources, same paths, same run shape either way.
  def undefined_method_messages(sources, publish:)
    Dir.mktmpdir("rigor-pre-eval-constants-") do |tmpdir|
      lib = File.join(tmpdir, "lib")
      FileUtils.mkdir_p(lib)
      sources.each { |name, body| File.write(File.join(lib, name), body) }
      Dir.chdir(tmpdir) do
        config = { "paths" => [lib] }
        config["pre_eval"] = [File.join(lib, "decls.rb")] if publish
        result = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(config), cache_store: nil
        ).run
        result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
      end
    end
  end

  # The receiver descriptor the `call.undefined-method` message reports for `NAME.probe_x`, or nil when the
  # call produced no diagnostic at all (the `Dynamic[top]` reading).
  def receiver_for(messages, probe)
    messages.grep(/`#{probe}'/).first&.slice(/for (.+)\z/, 1)
  end

  # Every publishable form, with a same-file control per constant.
  let(:decls) do
    <<~RUBY
      INT_LIT = 42
      STR_LIT = "hello"
      ARR_LIT = [1, 2]
      HSH_LIT = { a: 1 }
      ALIAS_CLS = String
      CLASS_NEW = Class.new(StandardError)
      NIL_CONST = nil

      module Nest
        NESTED_INT = 7
      end

      INT_LIT.probe_same_int
      STR_LIT.probe_same_str
      ARR_LIT.probe_same_arr
      HSH_LIT.probe_same_hsh
      ALIAS_CLS.probe_same_alias
      NIL_CONST.probe_same_nil
      Nest::NESTED_INT.probe_same_nested
    RUBY
  end

  let(:uses) do
    <<~RUBY
      INT_LIT.probe_cross_int
      STR_LIT.probe_cross_str
      ARR_LIT.probe_cross_arr
      HSH_LIT.probe_cross_hsh
      ALIAS_CLS.probe_cross_alias
      CLASS_NEW.probe_cross_class_new
      NIL_CONST.probe_cross_nil
      Nest::NESTED_INT.probe_cross_nested
    RUBY
  end

  let(:listed) { undefined_method_messages({ "decls.rb" => decls, "uses.rb" => uses }, publish: true) }
  let(:unlisted) { undefined_method_messages({ "decls.rb" => decls, "uses.rb" => uses }, publish: false) }

  describe "the same-file positive controls" do
    it "fires value-pinned in the declaring file whether or not the file is listed" do
      %w[unlisted listed].each do |half|
        messages = send(half)
        expect(receiver_for(messages, "probe_same_int")).to eq("42"), half
        expect(receiver_for(messages, "probe_same_str")).to eq('"hello"'), half
        expect(receiver_for(messages, "probe_same_arr")).to eq("[1, 2]"), half
        expect(receiver_for(messages, "probe_same_hsh")).to eq("{ a: 1 }"), half
        expect(receiver_for(messages, "probe_same_alias")).to eq("singleton(String)"), half
        expect(receiver_for(messages, "probe_same_nested")).to eq("7"), half
      end
    end
  end

  describe "an unlisted declaring file (today's behaviour, unchanged)" do
    it "publishes nothing value-shaped across the file boundary" do
      %w[probe_cross_int probe_cross_str probe_cross_arr
         probe_cross_hsh probe_cross_alias probe_cross_nested].each do |probe|
        expect(receiver_for(unlisted, probe)).to be_nil, probe
      end
    end

    it "still crosses the meta-new class-shaped form (ScopeIndexer#record_class_new_constant_decl)" do
      expect(receiver_for(unlisted, "probe_cross_class_new")).to eq("singleton(StandardError)")
    end
  end

  describe "a listed declaring file" do
    it "publishes the WIDENED type, never the value-pinned one" do
      expect(receiver_for(listed, "probe_cross_int")).to eq("Integer")
      expect(receiver_for(listed, "probe_cross_str")).to eq("String")
      expect(receiver_for(listed, "probe_cross_nested")).to eq("Integer")
    end

    it "erases a Tuple to raw Array and a HashShape to raw Hash" do
      expect(receiver_for(listed, "probe_cross_arr")).to eq("Array")
      expect(receiver_for(listed, "probe_cross_hsh")).to eq("Hash")
    end

    it "publishes a class-alias constant, which no meta-new promotion covers" do
      expect(receiver_for(listed, "probe_cross_alias")).to eq("singleton(String)")
    end

    it "leaves the meta-new form's existing cross-file answer untouched" do
      expect(receiver_for(listed, "probe_cross_class_new")).to eq("singleton(StandardError)")
    end

    it "declines a nil-valued constant in both directions" do
      expect(receiver_for(listed, "probe_cross_nil")).to be_nil
      expect(receiver_for(unlisted, "probe_cross_nil")).to be_nil
    end
  end

  describe "the multi-file write rule (widen on conflict)" do
    def two_publisher_receiver(second_value)
      messages = Dir.mktmpdir("rigor-pre-eval-conflict-") do |tmpdir|
        lib = File.join(tmpdir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "a.rb"), "SHARED = 1\n")
        File.write(File.join(lib, "b.rb"), "SHARED = #{second_value}\n")
        File.write(File.join(lib, "uses.rb"), "SHARED.probe_conflict\n")
        Dir.chdir(tmpdir) do
          Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              "paths" => [lib],
              "pre_eval" => [File.join(lib, "a.rb"), File.join(lib, "b.rb")]
            ),
            cache_store: nil
          ).run.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
        end
      end
      receiver_for(messages, "probe_conflict")
    end

    it "publishes the shared class when both writes widen to it (never `1 | 2`)" do
      expect(two_publisher_receiver("2")).to eq("Integer")
    end

    it "drops the name entirely when two publishers disagree" do
      expect(two_publisher_receiver('"two"')).to be_nil
    end
  end

  describe "the pool path (ADR-15 sequential equivalence)" do
    it "seeds a fork-worker scope with the same published table" do
      Dir.mktmpdir("rigor-pre-eval-pool-") do |tmpdir|
        lib = File.join(tmpdir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "decls.rb"), "TIMEOUT = 30\n")
        File.write(File.join(lib, "uses.rb"), "TIMEOUT.probe_pool\n")
        Dir.chdir(tmpdir) do
          result = Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              "paths" => [lib], "pre_eval" => [File.join(lib, "decls.rb")]
            ),
            cache_store: nil, workers: 2
          ).run
          messages = result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
          expect(receiver_for(messages, "probe_pool")).to eq("Integer")
        end
      end
    end
  end
end
