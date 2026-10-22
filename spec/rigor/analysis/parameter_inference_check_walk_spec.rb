# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "tmpdir"

# ADR-67 WD6 — check-walk activation of the call-site parameter-inference table.
#
# WD6a wires the collector into `rigor check` behind the `parameter_inference:` gate (off by default);
# WD6b stamps the "inferred, not declared" provenance mark on every seeded parameter and guards the
# negative in-body rules from firing against the open-call-site lower bound. These specs drive the real
# Runner (a disk run, so the cross-file discovery + collector pre-pass run exactly as `rigor check` does).
RSpec.describe "ADR-67 WD6 check-walk parameter inference" do
  def run(source, parameter_inference:)
    config = Rigor::Configuration.new("paths" => [], "parameter_inference" => parameter_inference)
    Tempfile.create(["probe", ".rb"]) do |file|
      file.write(source)
      file.flush
      runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
      return guarded_run(runner, [file.path]).diagnostics
    end
  end

  def rules(diagnostics)
    diagnostics.map(&:rule)
  end

  # A parameter reached only by a concrete-literal call site: `operate` is called with a String, so WD3
  # infers `w : String`. `w.no_such_string_method` would resolve against String and fire undefined-method
  # — but the WD6b guard declines because the inferred type is an open-call-site lower bound.
  let(:param_source) do
    <<~RUBY
      class Widget
        def go
          operate("hello")
          take(42)
        end

        def operate(w)
          w.no_such_string_method
        end

        def take(n)
          n.no_such_int_method
        end
      end
    RUBY
  end

  # The positive control: the SAME undefined calls on a directly-typed receiver DO fire undefined-method,
  # regardless of the gate. This proves the rule is active on the inferred classes, so the param case's
  # silence is the WD6b guard at work — not the rule being inert.
  let(:direct_source) do
    <<~RUBY
      class Widget
        def go
          "hello".no_such_string_method
          42.no_such_int_method
        end
      end
    RUBY
  end

  it "does not fire the negative in-body rules on an inferred-parameter receiver (gate on)" do
    diagnostics = run(param_source, parameter_inference: true)
    expect(rules(diagnostics)).not_to include("call.undefined-method")
  end

  it "is byte-identical to the gate-off run for the inferred-parameter source" do
    on = run(param_source, parameter_inference: true).map(&:to_h)
    off = run(param_source, parameter_inference: false).map(&:to_h)
    expect(on).to eq(off)
  end

  it "still fires undefined-method on a directly-typed receiver (the guard is not a blanket suppression)" do
    on = rules(run(direct_source, parameter_inference: true))
    off = rules(run(direct_source, parameter_inference: false))
    expect(on).to eq(off)
    expect(on.count("call.undefined-method")).to eq(2)
  end

  it "the gate-off run surfaces no call-diagnostics (the untyped parameter is a no-op)" do
    call_rules = rules(run(param_source, parameter_inference: false)).select { |rule| rule.to_s.start_with?("call.") }
    expect(call_rules).to be_empty
  end

  # WD6b, receiver side — argument-type-mismatch must decline when the RECEIVER roots at an inferred
  # parameter: the method whose parameter contract the argument was checked against was resolved through a
  # lower-bound type, so the verdict is speculative. Found by the 2026-07-30 self-check: seeding
  # `env : RBS::Environment` flagged `env.unload(culprits)`'s Array argument against `unload`'s declared
  # `Set[Pathname]` — a signature stricter than upstream's implementation, the FP class WD6b suppresses.
  describe "argument-type-mismatch on an inferred-parameter receiver" do
    let(:receiver_source) do
      <<~RUBY
        class Widget
          def go
            pick([1, 2])
          end

          def pick(items)
            items.fetch("x")
          end
        end
      RUBY
    end

    it "declines under the gate (the receiver's type is an open-call-site lower bound)" do
      diagnostics = run(receiver_source, parameter_inference: true)
      expect(rules(diagnostics)).not_to include("call.argument-type-mismatch")
    end

    it "is byte-identical to the gate-off run" do
      on = run(receiver_source, parameter_inference: true).map(&:to_h)
      off = run(receiver_source, parameter_inference: false).map(&:to_h)
      expect(on).to eq(off)
    end

    # The positive control: the same bad argument on a directly-typed receiver DOES fire, so the silence
    # above is the guard, not the rule being inert on Array#fetch.
    it "still fires on a directly-typed receiver" do
      direct = "class Widget\n  def go\n    [1, 2].fetch(\"x\")\n  end\nend\n"
      expect(rules(run(direct, parameter_inference: true))).to include("call.argument-type-mismatch")
    end
  end

  # Issue #2189 — a value derived from an inferred parameter through an array or hash literal read back, or
  # through an ivar the same method wrote from it, is the same open-call-site lower bound, so the guard declines
  # there as it does on the parameter. `Shouter` is the same-file positive control: identical bodies whose
  # parameter an RBS signature declares `Integer` keep reporting, so the silence is the guard and not the
  # rule being inert on these shapes.
  describe "values derived from an inferred parameter" do
    let(:derived_source) do
      <<~RUBY
        class Greeter
          def via_array(name)
            [name].first.upcase
          end

          def via_ivar(name)
            @x = name
            @x.upcase
          end

          def via_hash(name)
            {a: name}[:a].upcase
          end

          def via_rewritten_ivar(name)
            @y = name
            @y = 5
            @y.upcase
          end

          def store(name)
            @z = name
          end

          def read_stored
            @z.upcase
          end
        end

        class Shouter
          def via_array(name)
            [name].first.upcase
          end

          def via_ivar(name)
            @x = name
            @x.upcase
          end

          def via_hash(name)
            {a: name}[:a].upcase
          end
        end

        class KeyedGreeter
          def via_keyword_hash(name)
            [a: name].first[:a].upcase
          end

          def via_hash_key(name)
            {name => 1}.keys.first.upcase
          end
        end

        g = Greeter.new
        g.via_array(1)
        g.via_ivar(1)
        g.via_hash(1)
        g.via_rewritten_ivar(1)
        g.store(1)
        k = KeyedGreeter.new
        k.via_keyword_hash(1)
        k.via_hash_key(1)
      RUBY
    end

    let(:shouter_rbs) do
      <<~RBS
        class Shouter
          def via_array: (Integer name) -> untyped
          def via_ivar: (Integer name) -> untyped
          def via_hash: (Integer name) -> untyped
        end
      RBS
    end

    let(:lines) do
      run_with_signature(derived_source, shouter_rbs).select { |d| d.rule == "call.undefined-method" }.map(&:line)
    end

    def run_with_signature(source, rbs)
      Dir.mktmpdir("rigor-2189") do |dir|
        Dir.mkdir(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "shouter.rbs"), rbs)
        path = File.join(dir, "probe.rb")
        File.write(path, source)
        config = Rigor::Configuration.new(
          "paths" => [], "parameter_inference" => true, "signature_paths" => [File.join(dir, "sig")]
        )
        runner = Rigor::Analysis::Runner.new(configuration: config, cache_store: nil)
        return guarded_run(runner, [path]).diagnostics
      end
    end

    it "declines on an array literal element read back" do
      expect(lines).not_to include(3)
    end

    it "declines on an ivar the same method wrote from the parameter" do
      expect(lines).not_to include(8)
    end

    it "declines on a hash literal value read back" do
      expect(lines).not_to include(12)
    end

    # The ivar mark clears on a write from an independent value: `@y = 5` is not a lower bound.
    it "still reports an ivar rewritten from a non-parameter value" do
      expect(lines).to include(18)
    end

    # Guard: the class-ivar census seeds `@z` in `read_stored` without the inference seed, so it is not a
    # lower bound and never fired. Pinned so a census that starts reading the seed shows up here.
    it "does not report a sibling method's read of an ivar written from an inferred parameter" do
      expect(lines).not_to include(26)
    end

    it "declines on a keyword-hash element of an array literal read back" do
      expect(lines).not_to include(47)
    end

    it "declines on a hash literal key read back" do
      expect(lines).not_to include(51)
    end

    it "still reports the same derivations on a parameter a signature declares" do
      expect(lines).to include(32, 37, 41)
    end
  end
end
