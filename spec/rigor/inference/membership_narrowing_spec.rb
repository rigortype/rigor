# frozen_string_literal: true

require "spec_helper"

# Issue #606 slice 2 — `collection.include?(x)` narrowing `x` non-nil on the truthy edge. Kept in
# its own file (rather than beside slice 1's safe-nav chain examples) because the two slices are
# independent: this one can be reverted without touching the other.
#
# The proof lives entirely in the COLLECTION — if none of its elements can be nil, a true
# `include?` excludes a nil argument — so the must-not-narrow siblings are all about collections
# whose element story is unknown or admits nil. Pinned at the diagnostic level because the
# contract is the absence of a `call.possible-nil-receiver` false positive.
RSpec.describe "membership narrowing (#606 slice 2)" do
  def nil_receiver_diagnostics(source)
    Rigor::Analysis::Runner.new(configuration: Rigor::Configuration.new("paths" => []), cache_store: nil)
                           .run_source(source: source, path: "mem.rb")
                           .diagnostics
                           .select { |d| d.rule == "call.possible-nil-receiver" }
  end

  describe "must narrow" do
    # redmine app/controllers/reactions_controller.rb:59, modelled minimally: a `%w` constant
    # guard with an early return, and the protected use on the fall-through. This was the single
    # pure false positive in #574's arm C.
    it "narrows through a `%w` constant collection with an early return" do
      source = <<~RUBY
        REACTABLE = %w(Journal Issue).freeze
        def f(h)
          t = h ? "Journal" : nil
          unless REACTABLE.include?(t)
            return
          end
          t.upcase
        end
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end

    it "narrows through an inline array literal" do
      source = <<~RUBY
        def f(h)
          t = h ? "Journal" : nil
          return unless ["a", "b"].include?(t)

          t.upcase
        end
      RUBY
      expect(nil_receiver_diagnostics(source)).to be_empty
    end
  end

  describe "must NOT narrow" do
    # The defining negative: a true `include?` against this collection is exactly what a nil
    # argument produces.
    it "does not narrow when the collection itself contains nil" do
      source = <<~RUBY
        def f(h)
          t = h ? "Journal" : nil
          return unless ["a", nil].include?(t)

          t.upcase
        end
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end

    # "We do not know the elements" must not read as "no nil among them".
    it "does not narrow against an opaque collection" do
      source = <<~RUBY
        def f(h, list)
          t = h ? "Journal" : nil
          return unless list.include?(t)

          t.upcase
        end
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end

    # A false `include?` says nothing about the argument — a nil argument is simply not in the
    # list, which is what false means.
    it "does not narrow on the falsey edge" do
      source = <<~RUBY
        def f(h)
          t = h ? "Journal" : nil
          if ["a", "b"].include?(t)
            1
          else
            t.upcase
          end
        end
      RUBY
      expect(nil_receiver_diagnostics(source).size).to eq(1)
    end
  end

  describe "controls" do
    # Keeps the must-narrow group from passing because the rule stopped firing for an unrelated
    # reason.
    it "still fires on the same value with no membership guard at all" do
      source = <<~RUBY
        def f(h)
          t = h ? "Journal" : nil
          t.upcase
        end
      RUBY
      diags = nil_receiver_diagnostics(source)
      expect(diags.size).to eq(1)
      expect(diags.first.message).to eq("possible nil receiver: `upcase' is undefined on NilClass")
    end

    # `str.include?(literal)` belongs to `analyse_string_predicate`, which this slice must not
    # disturb: there the receiver is the bound value and the argument is the literal — the mirror
    # image of the shape above. Both diagnostics are correct and both must survive: the guard
    # `t.include?` is itself an unguarded call on a nilable receiver, and so is `t.upcase` after
    # it. A membership rule that keyed on the method name alone would have swallowed the second.
    it "leaves the String#include? predicate shape alone" do
      source = <<~RUBY
        def f(h)
          t = h ? "Journal" : nil
          return unless t.include?("a")

          t.upcase
        end
      RUBY
      expect(nil_receiver_diagnostics(source).map(&:method_name)).to eq(%w[include? upcase])
    end
  end
end
