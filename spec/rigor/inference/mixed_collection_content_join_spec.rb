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
  def diagnostics(source, sig: {})
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}), sig: sig).diagnostics
  end

  def dumped_types(source)
    diagnostics(source).filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def rules(source, prefix, sig: {})
    diagnostics(source, sig: sig).filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?(prefix)
    end
  end

  # The `def.` rules `Maker#call` draws, its body `body` and its hand-written signature `(params) -> ret`.
  def return_rules(body, ret, params: "")
    sig = { "maker.rbs" => "class Maker\n  def call: (#{params}) -> (#{ret})\nend\n" }
    arg = params.empty? ? "" : "(p)"
    rules("class Maker\n  def call#{arg}\n#{body.gsub(/^/, '    ')}  end\nend\n", "def.", sig: sig)
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
          .to eq(["Array[\"s\" | 1] | Hash[:k | Symbol, 1 | 2]"])
      end

      # An index store may reach either member. Read precisely, its value lands on the side it never reached, and a
      # hand-written signature rejects the member a guarded store on the other class made.
      it "keeps a Hash-keyed store off the Array member, which the signature accepts" do
        body = seams("x[:b] = \"t\" if x.is_a?(Hash)\n")[seam]
        ret = "Array[Integer] | Hash[Symbol, String]"
        expect(return_rules("x = gets ? [1] : { a: \"s\" }\n#{body}x\n", ret)).to be_empty
        # The control: the same store's value is still joined into the Hash member it reached.
        expect(return_rules("x = gets ? [1] : { a: \"s\" }\n#{body}x\n", "Array[Integer] | Hash[Symbol, Symbol]"))
          .to eq(["def.return-type-mismatch"])
      end

      it "floors a store whose index may reach either member on both sides" do
        body = seams("x[0] = 5 if x.is_a?(Array)\n")[seam]
        expect(return_rules("x = gets ? [1] : { a: \"s\" }\n#{body}x\n", "Array[Integer] | Hash[Symbol, String]"))
          .to be_empty
        body = seams("l[0] += 1 if l.is_a?(Array)\n")[seam]
        expect(rules("l = gets ? [1] : { a: 1 }\n#{body}puts \"3\" if l.is_a?(Array) && l[0] == 3\n", "flow."))
          .to be_empty
      end
    end
  end

  # The #586 reason the seam reads its seed before `widen_after_block`: the widening spells an empty `[]` as
  # `Array[untyped]`, which read back is a declared gradual arm. The mixed seed's Array member is read from the same
  # pre-widen seed, so an empty literal still contributes no element.
  it "adds no gradual arm for an empty Array member" do
    expect(dumped_types(<<~RUBY)).to eq(["Array[1] | Hash[:k, 2]"])
      e = gets ? [] : {}
      [0].each do
        e << 1 if e.is_a?(Array)
        e[:k] = 2 if e.is_a?(Hash)
      end
      dump_type(e)
    RUBY
  end

  it "keeps a Hash-keyed store off a declared parameter's Array member" do
    ret = "Array[Integer] | Hash[Symbol, String]"
    expect(return_rules("[0].each { p[:z] = \"q\" if p.is_a?(Hash) }\np\n", ret, params: ret)).to be_empty
  end

  it "keeps an each_with_object memo's Hash stores off its Array member" do
    expect(return_rules(<<~RUBY, "Array[Integer] | Hash[Integer, String]")).to be_empty
      r = [1, 2].each_with_object(gets ? [] : {}) { |v, acc| acc.is_a?(Array) ? acc << v : acc[v] = v.to_s }
      r
    RUBY
  end
end
