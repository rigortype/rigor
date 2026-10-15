# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "rigor/cli/check_command"

# Issue #1550 — `module_function :name` copies the method in effect at the call onto the module's singleton, so a
# later `def name` redefines only the instance method. The singleton def-node table used to take the later def,
# and `Fmt.label.upcase` reported `upcase` undefined on the later def's Integer.
RSpec.describe "a named module_function call and a later redefinition (#1550)" do
  around do |example|
    Dir.mktmpdir("rigor-module-function-snapshot-") { |dir| Dir.chdir(dir) { example.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def check(*flags)
    out = StringIO.new
    err = StringIO.new
    argv = ["--no-ci-detect", "--no-stats", "--no-baseline", "--format", "json", *flags]
    Rigor::CLI::CheckCommand.new(argv: argv, out: out, err: err).run
    [out.string, err.string]
  end

  def undefined_messages(json)
    JSON.parse(json).fetch("diagnostics")
        .select { |diagnostic| diagnostic.fetch("rule") == "call.undefined-method" }
        .map { |diagnostic| diagnostic.fetch("message") }
  end

  before { write(".rigor.yml", "paths:\n  - lib\n") }

  # Ruby: `Fmt.label` is "one" and `K.new.label` is 2, the later def. The receiver of the second `upcase` is
  # the positive control that the instance side still reads the later def.
  it "types the singleton copy as the def before the call, and the instance method as the later def" do
    write("lib/fmt.rb", <<~RUBY)
      module Fmt
        def label; "one"; end
        module_function :label
        def label; 2; end
      end

      class K
        include Fmt
      end

      Fmt.label.upcase
      K.new.label.upcase
    RUBY

    expect(undefined_messages(check("--no-cache").first)).to eq(["undefined method `upcase' for 2"])
  end

  # Ruby: `Fmt.label` is "one" whichever file loads first — the reopening's def either precedes the def the
  # call copies or follows the call.
  it "keeps the snapshot when a reopening in another file redefines the method" do
    write("lib/fmt.rb", <<~RUBY)
      module Fmt
        def label; "one"; end
        module_function :label
      end
    RUBY
    write("lib/fmt_ext.rb", "module Fmt\n  def label; 2; end\nend\n")
    write("lib/use.rb", "Fmt.label.upcase\n")

    expect(undefined_messages(check("--no-cache").first)).to eq([])
  end

  # Ruby: `module_function :label` raises `NameError` when `fmt.rb` loads first, and copies the reopening's
  # def when `fmt_ext.rb` does. The copy declines rather than take either def.
  it "declines when no def precedes the call in its own body" do
    write("lib/fmt.rb", <<~RUBY)
      module Fmt
        module_function :label
        def label; 2; end
      end
    RUBY
    write("lib/fmt_ext.rb", "module Fmt\n  def label; 1.5; end\nend\n")
    write("lib/use.rb", "Fmt.label.upcase\n")

    expect(undefined_messages(check("--no-cache").first)).to eq([])
  end

  # An edit to the copied def's body reaches the call site on a warm `--incremental` run, as on a cold one.
  it "answers on a warm --incremental run what a --no-cache run answers after the copied def changes" do
    write("lib/fmt.rb", "module Fmt\n  def label; \"one\"; end\n  module_function :label\n  def label; 2; end\nend\n")
    write("lib/use.rb", "Fmt.label.upcase\n")
    _, prime_err = check("--incremental")
    expect(prime_err).to include("--incremental cold")

    write("lib/fmt.rb", "module Fmt\n  def label; 1.5; end\n  module_function :label\n  def label; 2; end\nend\n")
    edit_out, edit_err = check("--incremental")
    expect(edit_err).to match(/--incremental warm — re-analysed \d+ of \d+ files \(1 changed\)/)
    expect(edit_out).to eq(check("--no-cache").first)
    expect(undefined_messages(edit_out)).to eq(["undefined method `upcase' for 1.5"])
  end
end
