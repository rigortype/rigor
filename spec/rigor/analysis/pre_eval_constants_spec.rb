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
        runner = Rigor::Analysis::Runner.new(
          configuration: Rigor::Configuration.new(config), cache_store: nil
        )
        result = guarded_run(runner)
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

  describe "an unlisted declaring file" do
    it "publishes the #644 frozen-scalar literals across the file boundary, and nothing else" do
      # This example used to assert that NOTHING value-shaped crossed without `pre_eval:`. Issue #644 gave
      # the whole project a literal-constant table, so the two Integer probes cross now — that is the
      # feature, not a regression.
      #
      # The guard the example exists for survives intact in the second half: `pre_eval:` is still what
      # publishes a String, an Array, a Hash or a class alias, so a change that published unconditionally
      # would surface here as a non-nil probe.
      expect(receiver_for(unlisted, "probe_cross_int")).to eq("42")
      expect(receiver_for(unlisted, "probe_cross_nested")).to eq("7")
      %w[probe_cross_str probe_cross_arr probe_cross_hsh probe_cross_alias].each do |probe|
        expect(receiver_for(unlisted, probe)).to be_nil, probe
      end
    end

    it "still crosses the meta-new class-shaped form (ScopeIndexer#record_class_new_constant_decl)" do
      expect(receiver_for(unlisted, "probe_cross_class_new")).to eq("singleton(StandardError)")
    end
  end

  describe "a listed declaring file" do
    it "widens what the #644 literal table declines, and keeps the value where that table publishes" do
      # The rule this example used to state — "the WIDENED type, never the value-pinned one" — was written
      # when `pre_eval:` was the ONLY cross-file constant publisher. Issue #644 added a second one, and where
      # both answer the literal table wins. Two reasons, both recorded in `PreEvalConstants`' own rationale:
      #
      # 1. Its basis is narrower and more certain. `pre_eval:` publishes what an rvalue TYPES TO after the
      #    walk evaluates it, so it must widen to stay honest about what it evaluated; #644 publishes only a
      #    syntactic frozen-scalar literal, single-write, single-file — which that rationale names as "a
      #    strictly later question; it needs its own FP measurement", not as something forbidden. #644 is
      #    that question, and the measurement is in its own specs and the PR.
      # 2. The hazards the widening was written against are the composite and mutable literals — a closed
      #    `HashShape` making `CONFIG.fetch(:b)` fire, a `Tuple` displacing an RBS overload. #644's table
      #    declines every one of those, so widening its output would spend no false-positive budget and buy
      #    nothing.
      #
      # The alternative — standing the literal table down for a listed file — is incoherent: opting a file
      # into `pre_eval:` would then make `INT_LIT` read `Integer` where an unlisted project reads `42`, so an
      # opt-in intended to add cross-file knowledge would remove some.
      expect(receiver_for(listed, "probe_cross_int")).to eq("42")
      expect(receiver_for(listed, "probe_cross_nested")).to eq("7")
      # `String` is the half `pre_eval:` still owns: #644 declines a mutable literal, so the widened class is
      # what crosses, and it crosses ONLY because the file is listed (the unlisted half above is nil).
      expect(receiver_for(listed, "probe_cross_str")).to eq("String")
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

  # This block is also what pins the shape of #663's retraction below: the rule there is "a writer outside
  # the LISTED set retracts", not "a second writer retracts", precisely so the agreeing pair here keeps
  # publishing `Integer` under `PreEvalConstants`' own widen-then-compare rule.
  describe "the multi-file write rule (widen on conflict)" do
    def two_publisher_receiver(second_value)
      messages = Dir.mktmpdir("rigor-pre-eval-conflict-") do |tmpdir|
        lib = File.join(tmpdir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "a.rb"), "SHARED = 1\n")
        File.write(File.join(lib, "b.rb"), "SHARED = #{second_value}\n")
        File.write(File.join(lib, "uses.rb"), "SHARED.probe_conflict\n")
        Dir.chdir(tmpdir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              "paths" => [lib],
              "pre_eval" => [File.join(lib, "a.rb"), File.join(lib, "b.rb")]
            ),
            cache_store: nil
          )
          guarded_run(runner).diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
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

  # Issue #663 — a `pre_eval:` publication answered even when a file OUTSIDE the listed set assigned the
  # same name a different, incompatible value. At runtime the winner is whichever file loaded last, so the
  # reader got a confident WRONG type where the honest answer is gradual — not lost precision, and the one
  # asymmetry #644's precedence work left standing. #644's write attribution (`constant_sources`, a census
  # over EVERY constant assignment rather than only the publishable ones) is what can now see it.
  describe "the unlisted-writer retraction" do
    # `decls.rb` is listed; `other.rb` never is. The reader sits in a third file so what it reads is the
    # PUBLISHED answer rather than a same-file table. `paths:` covers `lib/` either way, so `decls.rb` is
    # censused alongside its sibling unless `listed_outside_paths:` moves it out of the analysed tree.
    def cross_receiver(declared, other: nil, listed_outside_paths: false)
      Dir.mktmpdir("rigor-pre-eval-663-") do |tmpdir|
        lib = File.join(tmpdir, listed_outside_paths ? "boot" : "lib")
        uses = File.join(tmpdir, "lib")
        FileUtils.mkdir_p(lib)
        FileUtils.mkdir_p(uses)
        File.write(File.join(lib, "decls.rb"), declared)
        File.write(File.join(uses, "other.rb"), other) if other
        File.write(File.join(uses, "uses.rb"), "SHARED.probe_663\n")
        Dir.chdir(tmpdir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              "paths" => [uses], "pre_eval" => [File.join(lib, "decls.rb")]
            ),
            cache_store: nil
          )
          messages = guarded_run(runner).diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
          receiver_for(messages, "probe_663")
        end
      end
    end

    # The issue's repro. `Symbol` before the fix, from the listed file alone.
    it "retracts a listed name an unlisted file assigns a different value" do
      expect(cross_receiver("SHARED = :a\n", other: "SHARED = \"str\"\n")).to be_nil
    end

    # The rule is #644's, not `PreEvalConstants`' widen-then-compare: an unlisted write retracts on the
    # existence of a second WRITER, whatever its rvalue, because the census records a form's reach rather
    # than the value it carries. An unlisted `SHARED += 1` decides the runtime value exactly as a plain
    # reassignment does.
    it "retracts on an unlisted write whose form carries no value at all" do
      expect(cross_receiver("SHARED = [1, 2]\n", other: "SHARED += 1\n")).to be_nil
    end

    # Must-still-succeed, and the arm that keeps the opt-in worth taking: a name only the listed file writes
    # still answers from `pre_eval:`. `Array` is the discriminating value — the #644 literal table declines
    # a mutable literal, so nothing but `pre_eval:` can be answering here.
    it "still publishes a listed name no unlisted file writes" do
      expect(cross_receiver("SHARED = [1, 2]\n")).to eq("Array")
      expect(cross_receiver("SHARED = [1, 2]\n", other: "KEPT = :kept\n")).to eq("Array")
    end

    # ADR-17 WD5 permits listing a file under `pre_eval:` and NOT under `paths:`. Such a file contributes no
    # censused name of its own, so a rule counting writers would see ONE — the unlisted sibling — and keep
    # publishing. What the rule asks instead is whether any writer is outside the listed set.
    it "retracts for a listed file kept out of `paths:`, whose own write the census never sees" do
      expect(cross_receiver("SHARED = :a\n", other: "SHARED = \"str\"\n", listed_outside_paths: true)).to be_nil
      expect(cross_receiver("SHARED = [1, 2]\n", listed_outside_paths: true)).to eq("Array")
    end
  end

  describe "the pool path (ADR-15 sequential equivalence)" do
    def pool_probe_receiver(workers)
      Dir.mktmpdir("rigor-pre-eval-pool-") do |tmpdir|
        lib = File.join(tmpdir, "lib")
        FileUtils.mkdir_p(lib)
        File.write(File.join(lib, "decls.rb"), "TIMEOUT = 30\n")
        File.write(File.join(lib, "uses.rb"), "TIMEOUT.probe_pool\n")
        Dir.chdir(tmpdir) do
          runner = Rigor::Analysis::Runner.new(
            configuration: Rigor::Configuration.new(
              "paths" => [lib], "pre_eval" => [File.join(lib, "decls.rb")]
            ),
            cache_store: nil, workers: workers
          )
          result = guarded_run(runner)
          messages = result.diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:message)
          receiver_for(messages, "probe_pool")
        end
      end
    end

    it "seeds a fork-worker scope with the same published table the sequential path uses" do
      # The property is EQUIVALENCE, so it is asserted as equivalence rather than against a literal the
      # precedence rule could quietly move: a seed that failed to reach the workers would answer nil here
      # while the sequential run answered something. The concrete value is pinned too, so an empty table on
      # BOTH paths cannot pass — and it is `30`, not `Integer`, because the #644 literal table wins over the
      # `pre_eval:` widening (see "a listed declaring file" above).
      expect(pool_probe_receiver(2)).to eq(pool_probe_receiver(0))
      expect(pool_probe_receiver(2)).to eq("30")
    end
  end
end
