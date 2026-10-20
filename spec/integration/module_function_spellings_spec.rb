# frozen_string_literal: true

require "spec_helper"

# Issue #2209 — a module that `extend`s itself makes `Es.two` private while `two` is a private instance method, unless
# some file makes `two` a module function, whose singleton copy is public. The deferred-ranges prescan read only the
# receiverless `module_function :two`. Each example's comment gives Ruby 4.0.5's answer to `Es.two(1, 2)`.
RSpec.describe "module_function spellings in a reopening (#2209)", type: :runner do
  def mismatches(reopening)
    files = { "es.rb" => "module Es\n  extend self\n  private def two(a, b) = a\nend\n",
              "use.rb" => "def b = Es.two(1, 2)\n" }
    files["es_mf.rb"] = "module Es\n  #{reopening}\nend\n" if reopening
    analyze(files: files).diagnostics.select { |d| d.rule == "def.method-visibility-mismatch" }
                         .map { |d| [File.basename(d.path), d.line] }
  end

  # Ruby: 1 for each. The last four are spellings whose names the prescan cannot read, so the rule declines.
  [
    "self.module_function :two", "send(:module_function, :two)", "send('module_function', 'two')",
    "__send__(:module_function, :two)", "self.send(:module_function, :two)",
    "self.module_function def two(a, b) = a", "send(:module_function, def two(a, b) = a)",
    "names = [:two]; send(:module_function, *names)", "n = :two; self.module_function n",
    "self.module_function; def two(a, b) = a", "send(:module_function); def two(a, b) = a"
  ].each do |spelling|
    it "does not report the singleton call after `#{spelling}`" do
      expect(mismatches(spelling)).to eq([])
    end
  end

  # Ruby: NoMethodError (private method) for the first two; `public_send` raises NoMethodError at the reopening,
  # since `module_function` is private (controls).
  [nil, "self.module_function :three", "public_send(:module_function, :two)"].each do |reopening|
    it "still reports the singleton call with #{reopening ? "`#{reopening}`" : 'no reopening'}" do
      expect(mismatches(reopening)).to eq([["use.rb", 1]])
    end
  end
end
