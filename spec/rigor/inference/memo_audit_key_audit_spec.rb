# frozen_string_literal: true

require "spec_helper"

# ADR-129 WD1 — the key audit. A memo miss computation that reads a Frame its key does not carry is a
# `MemoAudit::KeyMismatch` on the thread's list, unless the computation installed the Frame itself, the site forces it
# at its entry, or the site names it a known gap. The yield-value frame stands in for any Frame here: it has a public
# install ({ExpressionTyper.with_yield_value_type}) and a public read ({ExpressionTyper.current_yield_value_type}).
RSpec.describe Rigor::Inference::MemoAudit, ".key_audit" do
  let(:audit) { described_class }
  let(:typer) { Rigor::Inference::ExpressionTyper }
  let(:value) { Rigor::Type::Combinator.constant_of(1) }
  let(:state) { Rigor::TypingState.current }
  let(:yield_slot) { Rigor::TypingState.slot(:yield_value_type).index }

  around do |example|
    audit.enable!
    audit.drain
    example.run
  ensure
    audit.drain
    audit.disable!
    Rigor::TypingState.release_run_scoped
  end

  def mismatches = audit.drain.grep(described_class::KeyMismatch)

  def read_yield = typer.current_yield_value_type

  it "reports a Frame the computation reads and the key does not carry" do
    answer = typer.with_yield_value_type(value) { audit.key_audit("probe") { read_yield } }

    expect(answer).to eq(value)
    expect(mismatches.map(&:message))
      .to eq(["key audit: the probe miss read the Frame yield_value_type, which its key does not carry"])
  end

  it "reports a key mismatch once per message until the list is drained" do
    typer.with_yield_value_type(value) { 2.times { audit.key_audit("probe") { read_yield } } }

    expect(mismatches.size).to eq(1)
  end

  it "carries the miss site's backtrace, so the crash row names where the memo missed" do
    typer.with_yield_value_type(value) { audit.key_audit("probe") { read_yield } }

    expect(mismatches.first.backtrace.first).to include("memo_audit_key_audit_spec.rb")
  end

  it "accepts a Frame the key read through key_frame" do
    typer.with_yield_value_type(value) do
      key = audit.key { [state.key_frame(yield_slot)] }
      audit.key_audit("probe", nil, key) { read_yield }
    end

    expect(mismatches).to be_empty
  end

  it "accepts every Frame when the key carries the state id" do
    typer.with_yield_value_type(value) do
      key = audit.key { [state.key_state_id] }
      audit.key_audit("probe", nil, key) { read_yield }
    end

    expect(mismatches).to be_empty
  end

  it "does not take the terms of another key: they belong to the key built last" do
    typer.with_yield_value_type(value) do
      audit.key { [state.key_frame(yield_slot)] }
      audit.key_audit("probe", nil, [:another]) { read_yield }
    end

    expect(mismatches.size).to eq(1)
  end

  it "treats a Frame the computation installed itself as internal" do
    audit.key_audit("probe") { typer.with_yield_value_type(value) { read_yield } }

    expect(mismatches).to be_empty
  end

  it "accepts a Frame the site declares forced at its entry" do
    declaration = audit.key_declaration(forced: %i[yield_value_type])
    typer.with_yield_value_type(value) { audit.key_audit("probe", declaration) { read_yield } }

    expect(mismatches).to be_empty
  end

  it "does not count a forcing read, which only decides whether to force the Frame" do
    typer.with_yield_value_type(value) { audit.key_audit("probe") { state.forcing_read(yield_slot) } }

    expect(mismatches).to be_empty
  end

  describe "named exceptions" do
    let(:declaration) { audit.key_declaration(gaps: { yield_value_type: "#0: a planted gap" }) }

    it "reports a declared gap as a named exception, not a mismatch" do
      typer.with_yield_value_type(value) { audit.key_audit("probe", declaration) { read_yield } }

      expect(mismatches).to be_empty
      expect(audit.key_exceptions).to eq(["probe", :yield_value_type] => "#0: a planted gap")
    end

    it "reaches the audits around the gap's site through the inner label" do
      typer.with_yield_value_type(value) do
        audit.key_audit("outer") { audit.key_audit("inner", declaration) { read_yield } }
      end

      expect(mismatches).to be_empty
      expect(audit.key_exceptions[["outer", :yield_value_type]]).to eq("through the inner miss: #0: a planted gap")
    end

    it "still reports an outer read of the same Frame outside the inner miss" do
      typer.with_yield_value_type(value) do
        audit.key_audit("outer") do
          audit.key_audit("inner", declaration) { read_yield }
          read_yield
        end
      end

      expect(mismatches.map(&:message)).to eq(
        ["key audit: the outer miss read the Frame yield_value_type, which its key does not carry"]
      )
    end

    it "names the audit's own switch, read by a nested hit's check" do
      audit.key_audit("probe") { audit.suspended? }

      expect(mismatches).to be_empty
      expect(audit.key_exceptions).to have_key(["probe", :memo_audit_suspended])
    end

    it "keeps a gap declared at an inner site whether the inner memo missed or hit" do
      inner = -> { audit.key_audit("inner", declaration) { read_yield } }
      typer.with_yield_value_type(value) { audit.key_audit("outer") { inner.call } }
      missed = [mismatches, audit.key_exceptions[["outer", :yield_value_type]]]
      Rigor::TypingState.release_run_scoped

      # A hit's check recomputes the inner value suspended: the inner declaration still opens, unjudged.
      typer.with_yield_value_type(value) { audit.key_audit("outer") { audit.check("inner", value, :k) { inner.call } } }
      hit = [mismatches, audit.key_exceptions[["outer", :yield_value_type]]]

      expect(missed).to eq([[], "through the inner miss: #0: a planted gap"])
      expect(hit).to eq(missed)
      expect(audit.key_exceptions).not_to have_key(["inner", :yield_value_type])
    end
  end

  it "accepts a Frame the site declares carried by another key term" do
    declaration = audit.key_declaration(carried: { yield_value_type: "the bucket's generation carries it" })
    typer.with_yield_value_type(value) { audit.key_audit("probe", declaration) { read_yield } }

    expect(mismatches).to be_empty
    expect(audit.key_exceptions).to be_empty
  end

  it "treats a Frame the computation cleared itself with `without` as internal" do
    slots = [yield_slot].freeze
    typer.with_yield_value_type(value) { audit.key_audit("probe") { state.without(slots) { read_yield } } }

    expect(mismatches).to be_empty
  end

  describe "a computation left by a throw" do
    it "closes its audit, so the audit around it judges its own reads and the thread keeps none open" do
      typer.with_yield_value_type(value) do
        audit.key_audit("outer") do
          catch(:over) { audit.key_audit("inner") { throw :over } }
          read_yield
        end
      end

      expect(mismatches.map(&:message))
        .to eq(["key audit: the outer miss read the Frame yield_value_type, which its key does not carry"])
      expect(state.instance_variable_get(:@key_audits)).to be_empty
    end

    it "judges nothing for the computation the throw left" do
      typer.with_yield_value_type(value) do
        catch(:over) do
          audit.key_audit("inner") do
            read_yield
            throw :over
          end
        end
      end

      expect(mismatches).to be_empty
    end
  end

  describe "while the audit is off" do
    it "audits nothing" do
      audit.disable!
      typer.with_yield_value_type(value) { audit.key_audit("probe") { read_yield } }
      audit.enable!

      expect(mismatches).to be_empty
    end

    # A fresh thread has a fresh state: with the audit off, a key and a miss leave it a plain State and allocate
    # nothing per call (a run of 200 allocates what a run of 100 does: only the measurement's own objects).
    it "leaves the thread's state unextended and allocates nothing" do
      audit.disable!
      extended, allocated = Thread.new do
        fresh = Rigor::TypingState.current
        runs = [100, 200, 100, 200].map do |count|
          before = GC.stat(:total_allocated_objects)
          count.times { audit.key_audit("probe") { audit.key { nil } } }
          GC.stat(:total_allocated_objects) - before
        end
        [fresh.is_a?(Rigor::TypingState::KeyAudit), runs[3] - runs[2]]
      end.value
      audit.enable!

      expect([extended, allocated]).to eq([false, 0])
    end
  end

  # The two declared sites, read Frame by Frame: each forced or carried Frame passes silently, each gap is named with
  # its issue. The expected lists are written out here, so dropping a Frame from a declaration fails.
  describe "the declared sites" do
    def judged(label, declaration, name)
      slot = Rigor::TypingState.slot(name).index
      audit.key_audit(label, declaration) { state[slot] }
      [mismatches.map(&:message), audit.key_exceptions[[label, name]]&.slice(/\A#\d+/)]
    end

    let(:return_memo) { typer.const_get(:RETURN_MEMO_KEY_AUDIT) }
    let(:census) { Rigor::Inference::StatementEvaluator.const_get(:RESOLVED_CENSUS_KEY_AUDIT) }

    it "forces or carries the return memo's call-site Frames" do
      names = %i[forwarded_call_arg_types reflective_ivar_write_repeating key_presence_walk next_sink break_sink
                 break_value_sink retry_frames interface_erasure interface_dispatch_off]
      expect(names.to_h { |name| [name, judged("return memo", return_memo, name)] })
        .to eq(names.to_h { |name| [name, [[], nil]] })
    end

    it "names the return memo's two gaps by their issues" do
      expect(judged("return memo", return_memo, :threaded_block_body)).to eq([[], "#2782"])
      expect(judged("return memo", return_memo, :acceptance_unread_shape_refused)).to eq([[], "#2866"])
    end

    it "names each Frame the resolved census types under as #2867" do
      names = %i[threaded_block_body key_presence_walk return_sink next_sink break_sink break_value_sink retry_frames
                 interface_erasure interface_dispatch_off]
      expect(names.to_h { |name| [name, judged("resolved census", census, name)] })
        .to eq(names.to_h { |name| [name, [[], "#2867"]] })
    end
  end

  # The resolved census's #2867 gap reaches an enclosing miss the same way whether the census missed or hit: a hit's
  # check recomputes under the census's own declaration.
  describe "the resolved census inside another miss" do
    let(:evaluator) { Rigor::Inference::StatementEvaluator.new(scope: Rigor::Scope.empty) }
    let(:def_node) { Prism.parse("def m = 1").value.statements.body.first }
    let(:threaded) { Rigor::TypingState.slot(:threaded_block_body).index }

    def census_in_outer
      audit.key_audit("outer") { evaluator.send(:resolved_census, :probe, def_node) { state[threaded] } }
      [mismatches, audit.key_exceptions[["outer", :threaded_block_body]]&.slice(/\A.*#\d+/)]
    end

    it "names the census's gap through it on a miss and on a hit alike" do
      missed = census_in_outer
      hit = census_in_outer

      expect(missed).to eq([[], "through the resolved census miss: #2867"])
      expect(hit).to eq(missed)
    end
  end

  # ADR-129 WD1 — the return memo forces the caller's jump sinks and retry frames off at its entry: a callee body
  # re-typed for its return records no `next`, `break` or raise point into its caller's constructs.
  it "re-types a callee outside its caller's jump sinks and retry frames" do
    sinks = %i[next_sink break_sink break_value_sink retry_frames].map { |name| Rigor::TypingState.slot(name).index }
    seen = Rigor::Inference::StatementEvaluator.with_next_sink do
      Rigor::Inference::ExpressionTyper.with_call_site_frame(nil, nil) { sinks.map { |slot| state[slot] } }
    end.first

    expect(seen).to eq([nil, nil, nil, nil])
  end

  # The return memo counts ADR-130's run-level flags as carried by its run-generation key; the claim is checked where
  # a flag is installed, so an install in the middle of a run fails under the audit instead of mixing answers.
  describe "a run-level flag installed while the return memo holds entries" do
    let(:memo_slot) { Rigor::TypingState.slot(:user_method_return_memo).index }
    let(:installs) do
      {
        interface_erasure: -> { Rigor::Inference::RbsTypeTranslator.with_interface_erasure { :ran } },
        interface_dispatch_off: -> { Rigor::Inference::MethodDispatcher::InterfaceShape.without_dispatch { :ran } }
      }
    end

    it "raises under the audit" do
      state[memo_slot] = [Object.new, { def_node: :entry }]
      installs.each do |flag, install|
        expect(&install).to raise_error(described_class::Mismatch, /#{flag} installed while the return memo holds/)
      end
    end

    it "installs around a run whose return memo is empty" do
      state[memo_slot] = [Object.new, {}]
      expect(installs.values.map(&:call)).to eq(%i[ran ran])
    end

    it "installs without checking while the audit is off" do
      state[memo_slot] = [Object.new, { def_node: :entry }]
      audit.disable!
      ran = installs.values.map(&:call)
      audit.enable!
      expect(ran).to eq(%i[ran ran])
    end
  end
end
