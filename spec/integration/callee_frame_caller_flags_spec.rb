# frozen_string_literal: true

# A user-method body re-typed for its return ran under two thread-local flags its CALLER had set: the block-body
# threading suppression (a block fold, a `break` arm, a block joined with its `next` values) and the reflective-ivar
# repeat depth (a `for` body, a loop predicate). Both only widen, and the return memo's key had no term for either, so
# the first caller decided the return every later caller was served: `h.upcase` reported or not depending on whether a
# `for` body reached `h` first, down to the order of the file names. The callee frame now clears the repeat depth, and
# the threading suppression is a memo-key term (clearing it let folds nest; callee_fold_nesting_growth_spec.rb).
require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "a callee's return does not depend on its caller's frame flags", type: :runner do
  def rules(source)
    analyze(source).diagnostics.reject { |d| d.severity == :info }.map { |d| [d.line, d.qualified_rule] }
  end

  let(:undefined) { "call.undefined-method" }

  # `h` returns `1` whatever the caller's loop does: its body reads its own write.
  let(:ivar_callee) do
    <<~RUBY
      def h
        instance_variable_set(:@x, 1)
        @x
      end
    RUBY
  end

  # `g` returns `"s"`: its block's tail reads the local the block's first statement wrote.
  let(:fold_callee) do
    <<~RUBY
      def g
        [3].map { |e| v = "s"; v }.first
      end
    RUBY
  end

  # `callee`, then `in_frame` (which reaches the callee first, under the flag), then `out_call` outside any frame.
  def source(callee, in_frame, out_call)
    <<~RUBY
      class Foo
      #{callee}
        def in_frame
          #{in_frame}
        end

        def out_frame
          #{out_call}
        end
      end
    RUBY
  end

  def line_of(src, text) = src.lines.index { |line| line.include?(text) } + 1

  describe "the reflective-ivar repeat depth" do
    it "reports the call outside the loop after a `for` body reached the callee first" do
      src = source(ivar_callee, "for i in [1, 2]\n      h\n    end", "h.upcase")
      expect(rules(src)).to eq([[line_of(src, "h.upcase"), undefined]])
    end

    it "reports the call outside the loop after a `while` predicate reached the callee first" do
      src = source(ivar_callee, "while h\n      break\n    end", "h.upcase")
      expect(rules(src)).to eq([[line_of(src, "h.upcase"), undefined]])
    end

    it "gives the call inside the `for` body the same return" do
      src = source(ivar_callee, "for i in [1, 2]\n      h.upcase\n    end", "nil")
      expect(rules(src)).to eq([[line_of(src, "h.upcase"), undefined]])
    end

    it "restores the caller's depth after the callee frame" do
      # A literal-name write later in the same `for` body still joins the prior binding `0` into the new value. With
      # the depth left at zero after the call, it would bind the one pass's value alone.
      dump = lambda do |call|
        src = source(ivar_callee, "@n = 0\n    for i in [1, 2]\n      #{call}\n      instance_variable_set(:@n, @n + 1)\n      " \
                                  "Rigor.dump_type(@n)\n    end", "nil")
        analyze(src).diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
      end
      expect(dump.call("h")).to eq(["dump_type: 0 | Dynamic[top]"])
    end
  end

  describe "the block-body threading suppression" do
    {
      "a block fold" => "[1].map { |e| r = g; r }",
      "a `break` arm" => "[1].each { |e| break g }",
      "a block joined with its `next` values" => "[1].map { |e| next g if e; 2 }"
    }.each do |frame, in_frame|
      it "reports the call outside the block after #{frame} reached the callee first" do
        src = source(fold_callee, in_frame, "g.foo")
        expect(rules(src)).to eq([[line_of(src, "g.foo"), undefined]])
      end
    end
  end

  describe "across files" do
    around do |example|
      Dir.mktmpdir("rigor-callee-frame-flags-") { |dir| Dir.chdir(dir) { example.run } }
    end

    def rules_of_files(files)
      files.each do |relative, contents|
        FileUtils.mkdir_p(File.dirname(relative))
        File.write(relative, contents)
      end
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0))
      result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      result.diagnostics.reject { |d| d.severity == :info }.map { |d| [File.basename(d.path), d.qualified_rule] }
    end

    let(:callee_file) { "class Foo\n#{ivar_callee}end\n" }
    let(:in_frame) { "class Foo\n  def in_frame\n    for i in [1, 2]\n      h\n    end\n  end\nend\n" }
    let(:out_frame) { "class Foo\n  def out_frame\n    h.upcase\n  end\nend\n" }

    it "reports whichever file the run reaches first" do
      in_first = rules_of_files(
        "lib/0_callee.rb" => callee_file, "lib/a_in.rb" => in_frame, "lib/b_out.rb" => out_frame
      )
      expect(in_first).to eq([["b_out.rb", undefined]])
    end

    it "reports when the out-of-frame file comes first (the order that already reported)" do
      out_first = rules_of_files(
        "lib/0_callee.rb" => callee_file, "lib/a_out.rb" => out_frame, "lib/b_in.rb" => in_frame
      )
      expect(out_first).to eq([["a_out.rb", undefined]])
    end
  end
end
