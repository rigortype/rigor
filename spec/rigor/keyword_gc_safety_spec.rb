# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

# Issue #2850 / ruby/ruby Bug #22500. CRuby records which keywords a call left out in a bit field of
# `VM_KW_SPECIFIED_BITS_MAX` (31) bits. A keyword at index 31 or later (required keywords first, then optional,
# as CRuby counts them) whose default is not a literal makes a call that omits it allocate a record during
# argument setup instead. On CRuby 4.0 the fast keyword paths have already moved the passed values into
# keyword locals above the VM stack pointer at that moment, so a GC started by the allocation frees them:
# `Scope.new(..., match_frame: MatchRebinding::Frame.new(...))` stored a freed Frame and the next send on it
# crashed the VM. A literal default (`nil`, `true`, `false`, an Integer, a Symbol) never takes that path.
module KeywordGcSafetySpecHelpers
  SPECIFIED_BITS_MAX = 31
  ROOT = File.expand_path("../..", __dir__)

  def gc_safety_sources
    Dir[File.join(ROOT, "lib/**/*.rb")] + Dir[File.join(ROOT, "plugins/*/lib/**/*.rb")]
  end

  # Each `[path:line, name, offending keywords]` for a method whose keyword at index >= 31 has a non-literal
  # default. In `RubyVM::InstructionSequence#to_a`'s parameter hash, `:keyword` lists a required keyword as a
  # bare Symbol, a literal default as `[name, value]` and any other default as `[name]`. Only `def` bodies count:
  # a block's keywords go through CRuby's general argument setup, which extends the stack pointer first.
  def offending_methods(sources)
    sources.flat_map do |path|
      found = []
      pending = [RubyVM::InstructionSequence.compile_file(path)]
      until pending.empty?
        current = pending.pop
        current.each_child { |child| pending << child }
        found << offence(path, current) if current.to_a[9] == :method
      end
      found.compact
    end
  end

  def offence(path, iseq)
    keywords = iseq.to_a[11][:keyword]
    return nil if keywords.nil? || keywords.size <= SPECIFIED_BITS_MAX

    late = keywords.drop(SPECIFIED_BITS_MAX).select { |entry| entry.is_a?(Array) && entry.size == 1 }.map(&:first)
    late.empty? ? nil : ["#{path.delete_prefix("#{ROOT}/")}:#{iseq.first_lineno}", iseq.label, late]
  end

  # The call shape of `ExpressionTyper#build_user_method_body_scope`: the leading keywords only, with fresh values
  # (the Frame, the fold-safe set) whose one reference is the keyword. `GC.stress` runs only around the call.
  def stress_probe_script
    <<~RUBY
      require "rigor"
      body = Prism.parse("def m(a) = a").value.statements.body.first
      frame_class = Rigor::Inference::MatchRebinding::Frame
      intact = 0
      5.times do
        GC.stress = true
        scope = Rigor::Scope.new(
          environment: :env, locals: {}.freeze, self_type: nil, lexical_nesting: nil,
          discovery: Rigor::Scope::DiscoveryIndex::EMPTY, struct_fold_safe_locals: Set[:self].freeze,
          dynamic_origins: {}.compare_by_identity,
          match_frame: frame_class.new(body.body, body.parameters)
        )
        GC.stress = false
        frame = scope.match_frame
        intact += 1 if frame_class === frame && frame.body.equal?(body.body) &&
                       scope.struct_fold_safe_locals == Set[:self]
      end
      puts "intact=\#{intact}"
    RUBY
  end
end

RSpec.describe "Keyword parameters past CRuby's specified-bits limit" do
  include KeywordGcSafetySpecHelpers

  it "gives every keyword at index 31 or later a literal default" do
    expect(gc_safety_sources).not_to be_empty
    expect(offending_methods(gc_safety_sources)).to eq([])
  end

  it "reads the iseq keyword list as the gate assumes" do
    probe = RubyVM::InstructionSequence.compile(
      "LIMIT_PROBE = {}.freeze; def probe(a:, b: nil, c: LIMIT_PROBE, d: 1); end"
    )
    method_iseq = nil
    probe.each_child { |child| method_iseq = child if child.label == "probe" }
    expect(method_iseq.to_a[9]).to eq(:method)
    expect(method_iseq.to_a[11][:keyword]).to eq([:a, [:b, nil], [:c], [:d, 1]])
  end

  # An unfixed `Scope#initialize` crashes the VM on the first stressed call, so the probe runs in a subprocess and
  # the example reads its exit status rather than losing the rspec process.
  it "keeps freshly built keyword values alive through Scope.new under GC.stress" do
    root = KeywordGcSafetySpecHelpers::ROOT
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", stress_probe_script,
                                            chdir: root, stdin_data: "")
    expect(status.success?).to be(true), "probe subprocess failed (#{status}):\n#{stderr.lines.first(5).join}"
    expect(stderr).not_to include("[BUG]")
    expect(stdout.lines.last&.chomp).to eq("intact=5")
  end
end
