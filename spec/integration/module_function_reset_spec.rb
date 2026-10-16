# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

# Issue #1968 — a bare `public`, `private` or `protected` after a bare `module_function` ends the module_function
# mode, so a later `def` of a module function's name redefines only the instance method and the singleton keeps the
# def before the reset. Ruby 4.0.5's answer is in each example's comment.
RSpec.describe "a bare visibility call after a bare module_function (#1968)" do
  around do |example|
    Dir.mktmpdir("rigor-module-function-reset-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def undefined_messages(source)
    write(".rigor.yml", "paths:\n  - lib\n")
    write("lib/m.rb", source)
    out = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--no-cache", "--format", "json"]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: StringIO.new).run
    JSON.parse(out.string).fetch("diagnostics")
        .select { |diagnostic| diagnostic.fetch("rule") == "call.undefined-method" }
        .map { |diagnostic| diagnostic.fetch("message") }
  end

  # Ruby: `M.label` is 1, the module function's copy; the later `def label` after `public` is an instance method
  # only, so `M.label.upcase` raises.
  it "reports a call on the singleton copy made before a reset" do
    expect(undefined_messages(<<~RUBY)).to eq(["undefined method `upcase' for 1"])
      module M
        module_function
        def label = 1
        public
        def label = "x"
      end
      M.label.upcase
    RUBY
  end

  # Ruby: `G.label` is "x" in each. The `private` in a class-creating block runs with the new class as `self`, so the
  # later `def label` is still a module function. Each fails with the reset read as certain and the block entered
  # together; either half alone leaves it quiet, which the unit probes R7 and R3 pin.
  {
    "Class.new" => "Class.new(StandardError) do", "Struct.new" => "Struct.new(:l) do",
    "Data.define" => "Data.define(:v) do"
  }.each do |factory, opening|
    it "does not read a `private` in a #{factory} block as a reset" do
      expect(undefined_messages(<<~RUBY)).to eq([])
        module G
          module_function
          def label = 1
          K = #{opening}
            private
            def hidden = 0
          end
          def label = "x"
        end
        G.label.upcase
      RUBY
    end
  end

  # Ruby: `G.label` is "x": the block never runs, so the later `def label` is a module function. Whether it runs is
  # not read, so the singleton copy is uncertain and the call is not typed from the def before it.
  it "declines after a reset that may not run" do
    expect(undefined_messages(<<~RUBY)).to eq([])
      module G
        module_function
        def label = 1
        [1].each { private } if rand > 2
        def label = "x"
      end
      G.label.upcase
    RUBY
  end
end
