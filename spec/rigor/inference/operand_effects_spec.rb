# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::OperandEffects do
  def written(source) = described_class.written_variables(Prism.parse(source).value)

  describe ".written_variables" do
    it "names locals, instance variables and globals in first-write order" do
      expect(written("x = 1; @y = 2; $z = 3; x = 4")).to eq(%i[x @y $z])
    end

    # Issue #1362 — `$>` is `$stdout`, and a scope keeps its binding under `$stdout` (`Scope::GLOBAL_ALIASES`), so a
    # write to it names `$stdout`: a caller that skips what the operands wrote must skip that binding.
    it "names a write to `$>` by the key its binding is kept under" do
      expect(written("cond && ($> = io)")).to eq(%i[$stdout])
      expect(written("$stdout = io; $> = other")).to eq(%i[$stdout])
    end
  end
end
