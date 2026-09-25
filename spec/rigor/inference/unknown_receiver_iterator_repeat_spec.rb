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
  def analyzed(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig)
  end

  def dumped_types(source, sig: {})
    analyzed(source, sig: sig).diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def dumped_type(source, sig: {})
    dumps = dumped_types(source, sig: sig)
    expect(dumps.size).to eq(1)
    dumps.first
  end

  # Every diagnostic but the dumps and the info-level notes — what a user would be shown.
  def reported(source, sig: {})
    analyzed(source, sig: sig).diagnostics
                              .reject { |d| d.severity == :info || d.rule.to_s == "call.unresolved-toplevel" }
                              .map { |d| d.rule.to_s }
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

    # A project `each_with_index` over an Enumerable: the rebind written on the last run reaches the
    # continuation, and the zero-run path keeps the pre-call `nil`. This is Array's reading too, and it is
    # new output here, where the `:unknown` drop to `Dynamic[top]` used to hide the nil.
    it "reports a nil the zero-run path keeps, as it does for an Array" do
      expect(reported(<<~RUBY)).to eq(["call.possible-nil-receiver"])
        #{shelf}
        label = nil
        Shelf.new(%w[a b]).each_with_index { |e, _i| label = "x" + e }
        label.upcase
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

  # The name is evidence only where Rigor cannot see the method. A method the project defines under a
  # catalogued name is the project's, and a once-yielding `select` / `find` / `each_with_object` typed from a
  # cross-iteration binding would add the `nil` a second run writes — a value no run of it reads.
  describe "a method the project defines under a catalogued name" do
    let(:vault) do
      <<~RUBY
        class Vault
          def select(key)
            yield(key.to_s)
          end
        end
      RUBY
    end

    it "keeps the entry scope for the block's value" do
      expect(dumped_type(<<~RUBY)).to eq('"pending"')
        #{vault}
        def take(key)
          buf = "pending"
          out = Vault.new.select(key) { |_k| taken = buf; buf = nil; taken }
          dump_type(out)
          out.upcase
        end
      RUBY
    end

    it "reports nothing on either shape of the reported case" do
      expect(reported(<<~RUBY)).to be_empty
        #{vault}
        def take(key)
          buf = "pending"
          out = Vault.new.select(key) { |_k| taken = buf; buf = nil; taken }
          out.upcase
        end

        def once_first
          first = true
          w = Vault.new.select(:a) { |_k| was = first; first = false; was ? 5 : nil }
          w + 1
        end
      RUBY
    end

    it "keeps the entry scope for an implicit-self call" do
      expect(reported(<<~RUBY)).to be_empty
        class Installer
          def find(name)
            yield(name)
          end

          def run
            pending = "fetch"
            label = find(:first) { |_n| current = pending; pending = nil; current }
            label.upcase
          end
        end
      RUBY
    end

    # `each_with_object` discards its block's value, so only a `break` arm reads the block's scope.
    it "keeps the entry scope for a break arm" do
      expect(dumped_type(<<~RUBY)).to eq("0 | :done")
        class Tally
          def each_with_object(memo) = yield(:only, memo)
        end

        def m(flag)
          seen = 0
          dump_type(Tally.new.each_with_object([]) { |_x, _m| break seen if flag; seen = 1; :done })
        end
      RUBY
    end

    it "keeps the entry scope for a method a project module contributes" do
      expect(dumped_type(<<~RUBY)).to eq("5")
        module Lookup
          def find(id) = yield(id)
        end

        class Repo
          include Lookup
        end

        first = true
        dump_type(Repo.new.find(1) { |_r| was = first; first = false; was ? 5 : nil })
      RUBY
    end

    it "keeps the entry scope for a singleton method the project defines" do
      expect(dumped_type(<<~RUBY)).to eq("5")
        class Repo
          def self.find(id) = yield(id)
        end

        first = true
        dump_type(Repo.find(1) { |_r| was = first; first = false; was ? 5 : nil })
      RUBY
    end

    it "keeps the entry scope for a method only the project's signature declares" do
      sig = { "vault.rbs" => <<~RBS }
        class Vault
          def select: [T] (Symbol) { (String) -> T } -> T
        end
      RBS
      expect(dumped_type(<<~RUBY, sig: sig)).to eq("5")
        class Vault
          def initialize = @n = 0
        end

        first = true
        dump_type(Vault.new.select(:a) { |_k| was = first; first = false; was ? 5 : nil })
      RUBY
    end

    it "still repeats for the same name on a receiver Rigor cannot see" do
      expect(dumped_type(<<~RUBY)).to eq("0 | 1 | Dynamic[top]")
        #{vault}
        def m(items)
          seen = 0
          dump_type(items.select { |x| break seen if x; seen = 1 })
        end
      RUBY
    end
  end
end
