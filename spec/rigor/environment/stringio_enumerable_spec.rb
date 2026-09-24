# frozen_string_literal: true

# `StringIO` is `Enumerable[String]`, as `IO` is.
#
# CRuby's `ext/stringio/stringio.c` runs `rb_include_module(StringIO, rb_mEnumerable)` in `Init_stringio`, and
# `StringIO#each` yields the stream's lines. ruby/rbs declares `class StringIO` with no `include` (in
# `core/string_io.rbs` before 3.7, in `stdlib/stringio` from 3.7), so `StringIO.new(s).detect { ... }`, `.map`,
# `.each_with_index` and the rest of Enumerable's surface reported `call.undefined-method` on correct code, and
# `.select { ... }` resolved to `Kernel#select` and reported `call.wrong-arity`. `data/core_overlay/string_io.rbs`
# adds the mixin.
#
# This file lives under `spec/rigor/environment` because that is what CI's "RBS compatibility (RBS 3.x)" job runs.
require "spec_helper"

RSpec.describe "StringIO includes Enumerable[String]" do
  describe "the RBS definition" do
    let(:loader) { Rigor::Environment::RbsLoader.new(libraries: ["stringio"]) }

    def stringio_method(name)
      loader.instance_method(class_name: "StringIO", method_name: name)
    end

    # An include, not a prepend: behind the class, ahead of Object and Kernel, as at runtime.
    it "puts Enumerable in StringIO's ancestry between the class and Object" do
      ancestors = loader.instance_definition("StringIO").ancestors.ancestors.map { |a| a.name.to_s }
      expected_order = %w[::StringIO ::Enumerable ::Object ::Kernel]

      expect(ancestors & expected_order).to eq(expected_order)
    end

    it "binds Enumerable's element type to String" do
      detect = stringio_method(:detect)
      block_params = detect.method_types.filter_map(&:block).map { |b| b.type.required_positionals.first&.type.to_s }

      expect(detect.defined_in.to_s).to eq("::Enumerable")
      expect(block_params).to include("::String")
    end

    # A block-taking `select` is Enumerable's; before the mixin it fell through to `Kernel#select`, the IO
    # multiplexer.
    it "resolves select to Enumerable rather than Kernel" do
      expect(stringio_method(:select).defined_in.to_s).to eq("::Enumerable")
    end

    # The overlay adds the mixin and nothing else: it redeclares none of StringIO's own methods, so upstream's
    # signatures stand. (No StringIO method shares a name with Enumerable's, so this does not test ordering; the
    # ancestry example above does.)
    it "keeps StringIO's own iteration methods" do
      %i[each each_line each_char each_byte readlines].each do |name|
        expect(stringio_method(name).defined_in.to_s).to eq("::StringIO"), "#{name} left StringIO"
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

    # THE REPORTED HAZARD, with the positive control on the last line: a method neither StringIO nor
    # Enumerable declares still reports, so the silence above it is not a class degraded to `Dynamic[top]`.
    it "accepts Enumerable's methods on a StringIO and still reports an undefined one" do
      expect(error_lines(<<~RUBY)).to eq([[11, "call.undefined-method"]])
        require "stringio"
        io = StringIO.new(ARGV.first.to_s)
        io.detect { |line| line.start_with?("b") }
        io.map(&:chomp)
        io.select { |line| line.size > 1 }
        io.each_with_index { |line, i| puts "\#{i}: \#{line}" }
        io.each_slice(2).to_a
        io.to_a
        io.include?("x")
        io.first
        io.not_a_stringio_method
      RUBY
    end

    it "answers String elements" do
      expect(dumped_types(<<~RUBY)).to eq(["String?", "Array[String]", "Array[String]"])
        require "stringio"
        io = StringIO.new(ARGV.first.to_s)
        dump_type(io.detect { |line| line.empty? })
        dump_type(io.map { |line| line })
        dump_type(io.to_a)
      RUBY
    end

    # The inference-side counterpart of "keeps StringIO's own iteration methods": `each_line` still answers
    # upstream's declared `self`.
    it "keeps StringIO's own each_line" do
      expect(dumped_types(<<~RUBY)).to eq(["StringIO"])
        require "stringio"
        io = StringIO.new(ARGV.first.to_s)
        dump_type(io.each_line { |line| line })
      RUBY
    end
  end
end
