# frozen_string_literal: true

require "spec_helper"

# An unbound variable `||=` reads as its rvalue: the memoization idiom (`def self.default = @default ||= new`),
# ADR-5's optimistic reading. The reading needs an rvalue that can store something truthy. A `||=` whose rvalue
# has none is a guard: `@settings ||= raise("boot first")` returns only when something the analyzer did not see
# set `@settings`, so its value is that binding. Typed as the rvalue, it was `bot`, and `rigor sig-gen` declared
# `def self.settings: () -> bot` on a reader that returns the configured settings.
#
# Every guard example is paired with a control that must keep its answer: a memo whose rvalue can be truthy, and
# a guard on a target the analyzer sees bound.
RSpec.describe "variable `||=` guard value", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  describe "an unbound guard" do
    it "reads the binding it guards, not the rvalue's bot, for every variable kind" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"] * 4)
        class App
          def self.settings = dump_type(@settings ||= raise("boot first"))
          def self.configure(h) = (@settings = h)

          def registry = dump_type(@@registry ||= raise("boot first"))
          def logger = dump_type($app_logger ||= raise("boot first"))

          def local
            dump_type(conf ||= raise("boot first"))
          end
        end
      RUBY
    end

    it "gives the statement form the same answer as the expression form" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]", "Dynamic[top]"])
        class App
          def self.settings
            s = (@settings ||= raise("boot first"))
            dump_type(s)
          end

          def self.options = dump_type(@options ||= raise("boot first"))
        end
      RUBY
    end

    it "keeps the unseen binding beside an rvalue that is never truthy" do
      # `@verbose ||= false` answers `true` once another method stored `true`.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | false", "Dynamic[top]?"])
        class App
          def self.verbose = dump_type(@verbose ||= false)
          def self.label = dump_type(@label ||= nil)
        end
      RUBY
    end

    it "does not read a local the previous loop iteration wrote as raising" do
      # Runtime: `1`. The second iteration sees the `v = 1` the first one stored; the entry scope does not.
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top]"])
        def loop_guard
          i = 0
          while i < 3
            dump_type(v ||= raise("unset")) if i > 0
            v = 1
            i += 1
          end
        end
      RUBY
    end
  end

  describe "controls" do
    it "keeps the memoizing `||=` on the rvalue" do
      expect(dumped_types(<<~RUBY)).to eq(["App", %("s"?)])
        class App
          def self.default = dump_type(@default ||= new)
          def self.maybe = dump_type(@maybe ||= ("s" if rand > 0.5))
        end
      RUBY
    end

    it "keeps a bound target's truthy value past the guard" do
      # Runtime: `{ a: 1 }`; the `raise` never runs.
      expect(dumped_types(<<~RUBY)).to eq(["{ a: 1 }"])
        def settings
          conf = { a: 1 }
          dump_type(conf ||= raise("boot first"))
        end
      RUBY
    end
  end
end
