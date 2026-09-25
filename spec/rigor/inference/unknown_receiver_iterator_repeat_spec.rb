# frozen_string_literal: true

require "spec_helper"

# Issue #1234 — whether a block call may run its block more than once decides whether the block is typed
# from a cross-iteration binding or from the call-site one. The answer came from `ClosureEscapeAnalyzer`,
# keyed on the receiver's class, so a `Dynamic` receiver and a project class outside the catalogue answered
# `:unknown` and kept the first iteration's pins.
#
# Two rules close it. A project class whose ancestry reaches a catalogued collection (`include Enumerable`,
# `< Array`) classifies through that entry, unless the project defines the method itself. A receiver that
# still classifies `:unknown` counts as repeating for the captured-binding pass when the method name is a
# catalogued iterator. Every example that moves is paired with one that must not.
RSpec.describe "an iterator on an unclassified receiver", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def dumped_type(source)
    dumps = dumped_types(source)
    expect(dumps.size).to eq(1)
    dumps.first
  end

  let(:shelf) do
    <<~RUBY
      class Shelf
        include Enumerable

        def initialize(items)
          @items = items
        end

        def each(&)
          @items.each(&)
        end
      end
    RUBY
  end

  describe "the name-based fallback for a Dynamic receiver" do
    # The break arm reads `seen` in the scope the block is typed under: `0` from the call-site binding,
    # `0 | 1` once a later run can see the `seen = 1` an earlier run wrote.
    it "types a catalogued iterator's block from the cross-iteration binding" do
      expect(dumped_type(<<~RUBY)).to eq("0 | 1 | Dynamic[top]")
        def m(items)
          seen = 0
          dump_type(items.find { |x| break seen if x; seen = 1 })
        end
      RUBY
    end

    it "keeps the call-site binding for a name the catalogue does not list" do
      expect(dumped_type(<<~RUBY)).to eq("0 | Dynamic[top]")
        def m(items)
          seen = 0
          dump_type(items.frobnicate { |x| break seen if x; seen = 1 })
        end
      RUBY
    end

    it "keeps the call-site binding for a run-once catalogue entry" do
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top] | true")
        def m(items)
          first = true
          dump_type(items.then { |x| break first if x; first = false })
        end
      RUBY
    end

    it "no longer folds a predicate on a counter the block rebinds" do
      result = analyze(<<~RUBY)
        def m(items)
          seen = 0
          r = items.all? { |x| seen += 1; seen == 1 }
          puts "one" if r
        end
      RUBY
      expect(result.diagnostics.map(&:rule).grep(/\Aflow\./)).to be_empty
    end
  end

  describe "a project class whose ancestry reaches a catalogued module" do
    it "types the block of an Enumerable method from the cross-iteration binding" do
      expect(dumped_type(<<~RUBY)).to eq("Array[Integer]")
        #{shelf}
        s = 0
        dump_type(Shelf.new([1, 2]).map { |x| s += 1; s })
      RUBY
    end

    # The statement pass reads the same classification: a `:non_escaping` block writes its rebinds back
    # through the ADR-56 fixpoint, where an `:unknown` one drops them to `Dynamic[top]`.
    it "writes the block's rebinds back after the call" do
      expect(dumped_type(<<~RUBY)).to eq("Integer")
        #{shelf}
        seen = 0
        Shelf.new([1]).find { |x| seen += 1; x }
        dump_type(seen)
      RUBY
    end

    it "classifies a subclass of a catalogued class through that class" do
      expect(dumped_type(<<~RUBY)).to eq("Integer")
        class Racks < Array
        end
        seen = 0
        Racks.new.select { |x| seen += 1; x }
        dump_type(seen)
      RUBY
    end

    it "does not classify a method the project defines itself" do
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        class Ledger
          include Enumerable

          def each = yield(1)

          def find(&block)
            @later = block
            nil
          end
        end
        seen = 0
        Ledger.new.find { |x| seen += 1; x }
        dump_type(seen)
      RUBY
    end

    it "does not classify a project class that reaches no catalogued ancestor" do
      expect(dumped_type(<<~RUBY)).to eq("Dynamic[top]")
        class Plain
          def find = yield(1)
        end
        seen = 0
        Plain.new.find { |x| seen += 1; x }
        dump_type(seen)
      RUBY
    end
  end
end
