# frozen_string_literal: true

# `Enumerable#detect(ifnone)` answers what `Enumerable#find(ifnone)` answers.
#
# CRuby binds both names to `enum_find`, so `detect(ifnone)` returns `ifnone.call` when no element matches.
# Upstream rbs declares `detect` as `(?Proc ifnone) { (Elem) -> boolish } -> Elem?`, dropping the fallback arm
# `find` carries, so `r = { a: 1 }.detect(-> { 0 }) { |k, v| v > 5 }` typed `[:a, 1]?` and `r + 1` reported
# `call.possible-nil-receiver` on correct code. `data/core_overlay/enumerable.rbs` prepends the ifnone arms.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job
# runs. Before rbs 4.1 `Array#detect` is Enumerable's too; rbs 4.1 and later alias it to `Array#find`.
require "spec_helper"

RSpec.describe "Enumerable#detect ifnone overloads" do
  describe "the RBS definition" do
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: []) }

    # [from the overlay?, required positionals, optional positionals] per overload, in dispatch order.
    def detect_overload_shapes
      loader.instance_method(class_name: "Enumerable", method_name: :detect).defs.map do |definition|
        function = definition.type.type
        [
          definition.member.location.buffer.name.to_s.include?("data/core_overlay/"),
          function.required_positionals.size,
          function.optional_positionals.size
        ]
      end
    end

    # The selector's strict pass skips an interface-typed parameter, so upstream's `(?Proc ifnone)` arm would win
    # a `Proc` argument if it came first. rbs unshifts a `| ...` continuation's overloads.
    it "tries the overlay's one-positional overloads before upstream's optional-Proc ones" do
      expect(detect_overload_shapes).to eq(
        [[true, 1, 0], [true, 1, 0], [true, 1, 0], [true, 1, 0], [false, 0, 1], [false, 0, 1]]
      )
    end

    # An `| ...` continuation with no base declaration raises `InvalidOverloadMethodError` and degrades the whole
    # module, and every includer's `detect` with it, to `Dynamic[top]`.
    it "leaves Enumerable and its includers buildable" do
      %w[Enumerable Array Hash Range Struct Enumerator Enumerator::Lazy].each do |name|
        expect(loader.instance_definition(name)).not_to be_nil, "#{name} failed to build"
      end
    end
  end

  describe "inference", type: :runner do
    def dumped_types(source)
      result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
      result.diagnostics.filter_map do |diagnostic|
        diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
      end
    end

    def error_lines(source)
      analyze(source).diagnostics.select { |diagnostic| diagnostic.severity == :error }.map do |diagnostic|
        [diagnostic.line, diagnostic.qualified_rule]
      end
    end

    # THE REPORTED HAZARD: every value below is `0` at runtime.
    it "no longer reports a nil receiver on detect's ifnone fallback" do
      expect(error_lines(<<~RUBY)).to be_empty
        n = Integer(ARGV.first)
        r = { a: 1 }.detect(-> { 0 }) { |k, v| v > 5 }
        r + 1
        s = (1..n).detect(-> { 0 }) { |e| e > 5 }
        s + 1
        t = [1, 2].each_slice(1).detect(-> { 0 }) { |x| false }
        t.size
        u = [3, 4].each_with_index.detect(-> { 0 }) { |x| false }
        u.size
        v = (1..n).lazy.detect(proc { 0 }) { |e| e > 5 }
        v + 1
      RUBY
    end

    # The paired control: the block-only form still answers `Elem?`, so its nil receiver still reports.
    it "still reports a nil receiver on a block-only detect" do
      expect(error_lines(<<~RUBY)).to eq([[3, "call.possible-nil-receiver"], [5, "call.possible-nil-receiver"]])
        n = Integer(ARGV.first)
        r = (1..n).detect { |e| e > 5 }
        r + 1
        s = { a: n }.detect { |k, v| v > 5 }
        s.size
      RUBY
    end

    # `nil` means no fallback, and any object answering `call` is one; upstream's `?Proc` parameter rejected both
    # with `call.argument-type-mismatch`. The surplus-argument line keeps a blanket stand-down from passing.
    it "accepts nil and any callable as the fallback, as find does" do
      expect(error_lines(<<~RUBY)).to eq([[8, "call.wrong-arity"]])
        n = Integer(ARGV.first)
        class Fallback
          def call = 0
        end
        (1..n).detect(nil) { |e| e > 5 }
        (1..n).detect(Fallback.new) { |e| e > 5 }
        (1..n).detect(method(:rand)) { |e| e > 5 }
        (1..n).detect(nil, nil) { |e| e > 5 }
      RUBY
    end

    it "answers find's type for every ifnone form" do
      detect_types, find_types = dumped_types(<<~RUBY).each_slice(2).to_a.transpose
        n = Integer(ARGV.first)
        h = { a: 1 }
        dump_type(h.detect(-> { 0 }) { |k, v| v > 5 })
        dump_type(h.find(-> { 0 }) { |k, v| v > 5 })
        dump_type((1..n).detect(-> { 0 }) { |e| e > 5 })
        dump_type((1..n).find(-> { 0 }) { |e| e > 5 })
        dump_type((1..n).detect(proc { 0 }))
        dump_type((1..n).find(proc { 0 }))
        dump_type((1..n).detect(method(:rand)) { |e| e > 5 })
        dump_type((1..n).find(method(:rand)) { |e| e > 5 })
        dump_type((1..n).detect { |e| e > 5 })
        dump_type((1..n).find { |e| e > 5 })
      RUBY

      expect([detect_types.size, detect_types]).to eq([5, find_types])
    end

    it "answers the fallback arm and keeps the block-only Elem?" do
      expect(dumped_types(<<~RUBY)).to eq(["Dynamic[top] | Integer", "Integer?", "Dynamic[top] | [:a, 1]"])
        n = Integer(ARGV.first)
        dump_type((1..n).detect(-> { 0 }) { |e| e > 5 })
        dump_type((1..n).detect { |e| e > 5 })
        dump_type({ a: 1 }.detect(-> { 0 }) { |k, v| v > 5 })
      RUBY
    end

    # rbs 4.1 and later resolve `Array#detect` to `Array#find`, which the overlay does not touch; earlier releases
    # route it through the overlay, which must give the same answers.
    it "keeps Array#detect's answer where Array#find's is" do
      detect_types, find_types = dumped_types(<<~RUBY).each_slice(2).to_a.transpose
        n = Integer(ARGV.first)
        dump_type([1, n].detect(-> { 0 }) { |e| e > 5 })
        dump_type([1, n].find(-> { 0 }) { |e| e > 5 })
        dump_type([1, n].detect { |e| e > 5 })
        dump_type([1, n].find { |e| e > 5 })
      RUBY

      expect([detect_types.size, detect_types]).to eq([2, find_types])
    end
  end
end
