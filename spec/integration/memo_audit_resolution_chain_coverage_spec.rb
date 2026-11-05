# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-129 G2 — CI's audited `rigor check --no-cache lib` reaches no hit of these memos: the recorded ancestor constant
# scopes are read only while a dependency recorder runs, and the resolution chain's marks and interned entries hit
# only when a retro world recomputes a node. This tree reaches a hit of each in an audited dependency-recording run
# (`IncrementalSession#baseline`), so a key that drops an input fails here as a MemoAudit mismatch:
#
# - `C`, `D` and `E` read constants through their ancestors in one file, so a recorded-scopes key without the class
#   name serves one class's scopes to another;
# - `C` re-includes `M`, which `Base` already includes: one skip, so its chain builds a retro world, recomputing every
#   node — the instance entries, `Base`'s external `Comparable` and `C`'s `:extend_hook` mark (its extended
#   `ClassMethods` includes on `extended`, the one mark kind that leaves the retro world standing);
# - `E` carries an `:extend_hook` and an `:include` mark, so a mark key without the kind serves one for the other;
# - `Err`'s external superclass `StandardError` is read on both sides, so an external-entry key without the side
#   serves the instance entry to the singleton chain;
# - `helper` and `other` are top-level defs a receiverless call hands an argument to, so the callee floor asks the
#   alias names twice.
#
# Each key defect was checked to fail here: the recorded scopes keyed on a constant, the project entries, marks and
# external entries each keyed without their side or kind.
RSpec.describe "MemoAudit reaches the resolution chain's and the recorded scopes' memos", type: :runner do
  around do |example|
    Rigor::Inference::MemoAudit.enable!
    example.run
  ensure
    Rigor::Inference::MemoAudit.disable!
  end

  let(:tree) do
    {
      "m.rb" => "module M\n  def m = 1\nend\n",
      "cm.rb" => "module ClassMethods\n  def self.extended(base)\n    base.include(M)\n  end\nend\n",
      "base.rb" => "class Base\n  include Comparable\n  include M\n  X = 1\n  def <=>(other) = 0\nend\n",
      "c.rb" => <<~RUBY,
        class C < Base
          extend ClassMethods
          include M
          def c = X
          def d = X
          def e = m
        end

        class D < Base
          def x = X
        end

        class E
          extend ClassMethods
          include M if ENV["X"]
        end
        E.new.m

        class Err < StandardError
          def self.make = new
        end
        Err.make.message
      RUBY
      "top.rb" => <<~RUBY
        def helper(a) = a << 1
        def other(a) = a << 2
        alias helper2 helper
        acc = []
        helper(acc)
        other(acc)
        C.new.c
        C.new.e
      RUBY
    }
  end

  let(:labels) do
    ["recorded ancestor constant scopes", "method alias names", "resolution chain mark", "resolution chain entry",
     "resolution chain external entry"]
  end

  it "audits a hit of each memo without a mismatch" do
    hits = Hash.new(0)
    allow(Rigor::Inference::MemoAudit).to receive(:check).and_wrap_original do |original, label, *rest, &block|
      hits[label] += 1 unless Rigor::Inference::MemoAudit.suspended?
      original.call(label, *rest, &block)
    end
    Dir.mktmpdir do |dir|
      tree.each { |name, source| File.write(File.join(dir, name), source) }
      session = Rigor::Analysis::IncrementalSession.new(
        configuration: Rigor::Configuration.new("paths" => [dir]), paths: [dir],
        environment: Rigor::Environment.for_project
      )
      guarded_baseline(session)
    end
    expect(hits.values_at(*labels)).to all(be_positive), hits.inspect
  end
end
