# frozen_string_literal: true

require "spec_helper"
require "tempfile"

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
      return Rigor::Analysis::Runner.new(configuration: config, cache_store: nil).run([file.path]).diagnostics
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
end
