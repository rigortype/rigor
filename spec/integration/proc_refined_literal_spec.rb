# frozen_string_literal: true

# Issue #1666 — `Proc#refined` on a Proc literal activates the given modules' refinements inside that literal's body.
#
# Ruby 4.1's `Proc#refined(*modules)` returns a copy of the Proc whose body runs with the modules' refinements in
# effect (CRuby duplicates the block's cref and appends them). When the literal is directly the receiver, which
# block the call refines is syntax, so a refined call in its body no longer reports `call.undefined-method`:
#
#   proc { "hi".shout }.refined(Shout)
#
# Every expectation below is the answer CRuby gives for the same source (`test_refined*` in `test/ruby/test_proc.rb`):
# a silent line runs, a reported line raises `NoMethodError` when the Proc is called.

require "spec_helper"

RSpec.describe "Proc#refined on a Proc literal (#1666)", type: :runner do
  let(:refinements) do
    <<~RUBY
      module Shout
        refine(String) { def shout = upcase + "!" }
      end

      module Whisper
        refine(Integer) { def whisper = to_s }
      end
    RUBY
  end

  # `[line, method name]` for every `call.undefined-method` in `app.rb`; the refining modules live in another file.
  def undefined_rows(source)
    result = analyze(files: { "refinements.rb" => refinements, "app.rb" => source })
    result.diagnostics.select { |d| d.qualified_rule == "call.undefined-method" && d.path.to_s.end_with?("app.rb") }
          .map { |d| [d.line, d.method_name.to_s] }
          .sort
  end

  it "silences the issue's repro and a nested block, and keeps reporting the same calls unrefined" do
    expect(undefined_rows(<<~RUBY)).to eq([[5, "shout"], [6, "shout"]])
      ->(s) { s.shout }.refined(Shout)
      proc { "hi".shout }.refined(Shout)
      ->(a) { a.map { |s| "x".shout } }.refined(Shout)
      Proc.new { "hi".shout }.refined(Shout)
      proc { "hi".shout }
      "hi".shout
    RUBY
  end

  # The control the gate names: a module that refines a different class activates nothing for `String`.
  it "keeps reporting under a module that refines a different class" do
    expect(undefined_rows(<<~RUBY)).to eq([[1, "shout"], [2, "whisper"]])
      proc { "hi".shout }.refined(Whisper)
      lambda { 1.whisper }.refined(Shout)
    RUBY
  end

  it "activates every module of a chain, and appends a nested literal's modules to the inherited ones" do
    expect(undefined_rows(<<~RUBY)).to eq([[6, "whisper"]])
      proc { "a".shout; 1.whisper }.refined(Shout).refined(Whisper)
      proc do
        1.whisper
        proc { "b".shout; 2.whisper }.refined(Shout)
      end.refined(Whisper)
      proc { 3.whisper; proc { "c".shout }.refined(Shout) }
    RUBY
  end

  # As a `using` of a non-constant does file-wide, a `.refined` argument that is not a constant may name any module,
  # so every refinement counts as in effect — inside that literal only.
  it "declines inside the literal only for an argument that is not a constant" do
    expect(undefined_rows(<<~RUBY)).to eq([[4, "shout"]])
      def build(mod)
        proc { "hi".shout }.refined(mod)
      end
      "hi".shout
    RUBY
  end

  # ADR-121 WD1's accepted gap: which block a variable holds is not syntax.
  it "keeps reporting a Proc held in a local and refined later" do
    expect(undefined_rows(<<~RUBY)).to eq([[1, "shout"]])
      l = -> { "hi".shout }
      l.refined(Shout)
    RUBY
  end
end
