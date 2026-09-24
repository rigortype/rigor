# frozen_string_literal: true

require "spec_helper"

# A captured local whose seed is a mixed `Array | Hash` union, content-mutated in a block or a loop body. The
# slice-C block join and the loop seam's join rebuilt ONE carrier — the Hash one, `hashish?` being asked first —
# from the seed read before `widen_after_block`, and kept the Array member as the seed had it: an unwidened literal
# `Tuple`, so whatever the body did to it was gone. `x = gets ? [1] : { a: 1 }; [0].each { x.map!(&:to_s) if
# x.is_a?(Array) }` read `[1]`, and `x.first.upcase` drew `undefined method 'upcase' for 1` on correct code; a
# `y << 2` in the same place was lost too, and `y.size == 1` folded always-truthy.
#
# Each "does not fire" example is paired with a control in the same position that must still fire, so a seam that
# stopped typing the Array member at all would not pass.
RSpec.describe "content join over a mixed Array | Hash seed", type: :runner do
  def diagnostics(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix)
    diagnostics(source).filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix) }
  end

  # The body under each seam: a block, and the same statements as a `while` body.
  def seams(body)
    {
      block: "[0].each do\n#{body}end\n",
      loop: "i = 0\nwhile i < 2\n#{body}  i += 1\nend\n"
    }
  end

  %i[block loop].each do |seam|
    describe "the #{seam} seam" do
      it "keeps a rewrite of the Array member beside a store into the Hash member" do
        body = seams(<<~RUBY)[seam]
          x.map!(&:to_s) if x.is_a?(Array)
          x[:k] = 2 if x.is_a?(Hash)
        RUBY
        expect(rules("x = gets ? [1] : { a: 1 }\n#{body}x.first.upcase if x.is_a?(Array)\n",
                     "call.undefined-method")).to be_empty
        expect(rules("x = gets ? [1] : { a: 1 }\n#{body}puts \"s\" if x.is_a?(Array) && x[0] == \"1\"\n",
                     "flow.")).to be_empty
      end

      it "still reports the Array member's element under a value-preserving mutator in the same position" do
        body = seams(<<~RUBY)[seam]
          x.sort! if x.is_a?(Array)
          x[:k] = 2 if x.is_a?(Hash)
        RUBY
        expect(rules("x = gets ? [1] : { a: 1 }\n#{body}puts \"s\" if x.is_a?(Array) && x[0] == \"1\"\n",
                     "flow.")).to eq(["flow.always-truthy-condition"]) # the rule id names both polarities
      end

      it "joins an append into the Array member beside a rewrite of the Hash member" do
        body = seams(<<~RUBY)[seam]
          y.transform_values!(&:to_s) if y.is_a?(Hash)
          y << 2 if y.is_a?(Array)
        RUBY
        expect(rules("y = gets ? [1] : { a: 1 }\n#{body}puts \"one\" if y.is_a?(Array) && y.size == 1\n",
                     "flow.")).to be_empty
        expect(rules("y = gets ? [1] : { a: 1 }\n#{body}puts \"two\" if y.is_a?(Array) && y.last == 2\n",
                     "flow.")).to be_empty
        # The control: the append is joined, not floored, so a value neither arm holds still folds.
        expect(rules("y = gets ? [1] : { a: 1 }\n#{body}puts \"three\" if y.is_a?(Array) && y.last == 3\n",
                     "flow.")).to eq(["flow.always-truthy-condition"])
      end

      it "joins each member with its own class's evidence" do
        body = seams(<<~RUBY)[seam]
          z << "s" if z.is_a?(Array)
          z[:k] = 2 if z.is_a?(Hash)
        RUBY
        expect(dumped_types("z = gets ? [1] : { a: 1 }\n#{body}dump_type(z)\n"))
          .to eq(["Array[\"s\" | 1 | 2] | Hash[:k | Symbol, 1 | 2]"])
      end
    end
  end

  # The #586 reason the seam reads its seed before `widen_after_block`: the widening spells an empty `[]` as
  # `Array[untyped]`, which read back is a declared gradual arm. The mixed seed's Array member is read from the same
  # pre-widen seed, so an empty literal still contributes no element. (`2` is the `[]=` store: the seam cannot tell
  # which member a store reached, so a selector in both adder tables is evidence for both sides.)
  it "adds no gradual arm for an empty Array member" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[1 | 2] | Hash[:k, 2]"])
      e = gets ? [] : {}
      [0].each do
        e << 1 if e.is_a?(Array)
        e[:k] = 2 if e.is_a?(Hash)
      end
      dump_type(e)
    RUBY
  end
end
