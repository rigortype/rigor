# frozen_string_literal: true

require "spec_helper"

# ADR-129 stage 2 — the ADR-46 dependency reads are a bound Table whose stores are the installed accumulator and each
# open ADR-84 capture: every event that files into a store is journaled while a capture is open (a read of its key,
# then the write when it adds), and refuses nothing.
RSpec.describe "the dependency reads as a journaled bound Table (ADR-129 stage 2)" do
  let(:recorder) { Rigor::Analysis::DependencyRecorder }
  let(:state) { Rigor::TypingState.current }
  let(:absent) { Rigor::TypingState::ABSENT }
  let(:table) { Rigor::TypingState.slot(:dependency_reads).index }

  def captured
    state.open_capture
    begin
      yield
    ensure
      refused, records = state.close_capture
    end
    [refused, records.each_slice(4).to_a]
  end

  # The records as `[kind, store, key, value]`, with each store named by `names` (identity) and the slot checked.
  def described(records, names)
    records.map do |kind, slot, (store, key), value|
      expect(slot).to eq(table)
      [kind, names.fetch(names.keys.find { |candidate| candidate.equal?(store) }), key, value]
    end
  end

  def accumulator = state[Rigor::TypingState.slot(:dependency_recorder).index]

  def innermost_capture = state[Rigor::TypingState.slot(:dependency_capture_stack).index].last

  # A read set a producer's window captured: a positive read and a name-keyed one.
  def produced_read_set
    read_set = nil
    recorder.record_for("producer.rb") do
      _, read_set = recorder.capture do
        recorder.read_site("base.rb:3", "Base#greet")
        recorder.read_name(:method, "foo")
      end
    end
    read_set
  end

  it "journals a positive read's first filing as a write and a repeat as a read, skipping the self-read" do
    result = nil
    store = nil
    recorder.record_for("consumer.rb") do
      store = accumulator
      result = captured do
        recorder.read_site("base.rb:3", "Base#greet")
        recorder.read_site("base.rb:3", "Base#greet")
        recorder.read_site("base.rb:9")
        recorder.read_site("consumer.rb:1")
      end
    end
    refused, records = result
    expect(refused).to be(false)
    expect(described(records, { store => :acc })).to eq(
      [[:read, :acc, ["base.rb", "Base#greet"], absent], [:write, :acc, ["base.rb", "Base#greet"], true],
       [:read, :acc, ["base.rb", "Base#greet"], true],
       [:read, :acc, ["base.rb", nil], absent], [:write, :acc, ["base.rb", nil], true]]
    )
  end

  it "journals name-keyed reads, single and prebuilt" do
    result = nil
    store = nil
    recorder.record_for("consumer.rb") do
      store = accumulator
      result = captured do
        recorder.read_name(:method, "foo")
        recorder.read_keys(["method:foo", "class:Bar"])
      end
    end
    refused, records = result
    expect(refused).to be(false)
    expect(described(records, { store => :acc })).to eq(
      [[:read, :acc, "method:foo", absent], [:write, :acc, "method:foo", true],
       [:read, :acc, "method:foo", true],
       [:read, :acc, "class:Bar", absent], [:write, :acc, "class:Bar", true]]
    )
  end

  it "journals a read into each open capture it is new to, innermost first, and stops at the first holder" do
    result = nil
    names = {}
    recorder.record_for("consumer.rb") do
      names[accumulator] = :acc
      recorder.capture do
        names[innermost_capture] = :outer
        recorder.read_site("base.rb:3", "Base#greet")
        recorder.capture do
          names[innermost_capture] = :inner
          result = captured do
            recorder.read_site("base.rb:3", "Base#greet")
            recorder.read_name(:class, "Missing")
          end
        end
      end
    end
    refused, records = result
    key = ["base.rb", "Base#greet"]
    expect(refused).to be(false)
    expect(described(records, names)).to eq(
      [[:read, :inner, key, absent], [:write, :inner, key, true], [:read, :outer, key, true], [:read, :acc, key, true],
       [:read, :inner, "class:Missing", absent], [:write, :inner, "class:Missing", true],
       [:read, :outer, "class:Missing", absent], [:write, :outer, "class:Missing", true],
       [:read, :acc, "class:Missing", absent], [:write, :acc, "class:Missing", true]]
    )
  end

  # The decision #2852 took (ratified 2026-11-06): a filing logs only the captures it probes,
  # so a capture outside the first holder is neither probed nor logged (it holds the key by the subset property).
  it "probes no capture outside the first one that holds the key" do
    result = nil
    names = {}
    recorder.record_for("consumer.rb") do
      names[accumulator] = :acc
      recorder.capture do
        names[innermost_capture] = :outer
        recorder.capture do
          names[innermost_capture] = :middle
          recorder.read_site("base.rb:3", "Base#greet")
          recorder.capture do
            names[innermost_capture] = :inner
            result = captured { recorder.read_site("base.rb:3", "Base#greet") }
          end
        end
      end
    end
    _, records = result
    key = ["base.rb", "Base#greet"]
    expect(described(records, names)).to eq(
      [[:read, :inner, key, absent], [:write, :inner, key, true], [:read, :middle, key, true], [:read, :acc, key, true]]
    )
  end

  it "journals a replay's filings into the open capture and the accumulator, and a held replay as nothing" do
    read_set = produced_read_set
    result = nil
    names = {}
    recorder.record_for("consumer.rb") do
      names[accumulator] = :acc
      recorder.capture do
        names[innermost_capture] = :cap
        result = captured do
          recorder.replay(read_set)
          recorder.replay(read_set)
        end
      end
    end
    refused, records = result
    key = ["base.rb", "Base#greet"]
    expect(refused).to be(false)
    expect(described(records, names)).to eq(
      [[:read, :cap, key, absent], [:write, :cap, key, true],
       [:read, :cap, "method:foo", absent], [:write, :cap, "method:foo", true],
       [:read, :acc, key, absent], [:write, :acc, key, true],
       [:read, :acc, "method:foo", absent], [:write, :acc, "method:foo", true]]
    )
  end

  it "journals nothing for a resolution chain filing the stores already hold" do
    result = nil
    chain = Object.new
    recorder.record_for("consumer.rb") do
      recorder.file_chain_once(chain, nil, 0) { recorder.read_name(:method, "hook") }
      result = captured do
        recorder.file_chain_once(chain, nil, 0) { recorder.read_name(:method, "hook") }
        recorder.file_chain_once(chain, nil, 1) { recorder.read_name(:method, "hook") }
      end
    end
    refused, records = result
    expect(refused).to be(false)
    expect(records.map { |kind, _, (_, key), value| [kind, key, value] }).to eq([[:read, "method:hook", true]])
  end

  it "refuses a capture open across a change of the capture stack" do
    refused = nil
    recorder.record_for("consumer.rb") do
      refused, = captured { recorder.capture { nil } }
    end
    expect(refused).to be(true)
  end

  it "takes a fresh state id for each change of the capture stack, and leaves the stack exempt to read" do
    ids = []
    recorder.record_for("consumer.rb") do
      ids << state.id
      recorder.capture do
        ids << state.id
        recorder.withhold { ids << state.id }
        ids << state.id
      end
      ids << state.id
    end
    expect(ids.uniq.size).to eq(ids.size)
  end

  # The installed recorder's own frame already gives withhold's body a fresh id, so the id alone cannot show that both
  # halves of the swap are rewrites; each is one.
  it "rewrites the capture stack where withhold swaps it in and where it restores it" do
    stack = Rigor::TypingState.slot(:dependency_capture_stack).index
    allow(state).to receive(:rewrite).and_call_original
    recorder.record_for("consumer.rb") { recorder.withhold { nil } }
    expect(state).to have_received(:rewrite).with(stack).twice
  end
end
