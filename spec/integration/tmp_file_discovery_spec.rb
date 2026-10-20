# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/analysis/buffer_binding"
require "rigor/configuration"

# Issue #2165 — `rigor check --tmp-file T --instead-of lib/a.rb lib/a.rb` (editor mode: a `buffer:` binding and the
# buffer's own path as the argument) discovered the buffer's file alone, so a class another file declares read as
# an external ancestor and the run reported what `rigor check lib/a.rb` over the same bytes does not. Each example
# compares the buffer run with a plain run over a tree holding the buffer's bytes, given the same argument.
RSpec.describe "editor --tmp-file mode discovers the project (#2165)", type: :runner do
  around do |example|
    Dir.mktmpdir("rigor-tmp-file-discovery-") { |dir| Dir.chdir(dir) { example.run } }
  end

  let(:caller_source) do
    <<~RUBY
      require "stringio"

      class Holder < Base
        def initialize = (@io = STDOUT)

        def dump
          return unless @io.is_a?(StringIO)

          log("dumping")
          @io.string
        end
      end
    RUBY
  end

  def configuration
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [File.expand_path("lib")], "workers" => 0))
  end

  def rows(runner)
    diagnostics = guarded_run(runner, ["lib/a.rb"]).diagnostics
    diagnostics.select { |d| d.path.end_with?("a.rb") }.map { |d| [d.line, d.rule, d.message] }
  end

  def plain_rows(bytes)
    File.write("lib/a.rb", bytes)
    rows(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
  end

  # The buffer run, with `on_disk` written to `lib/a.rb` and `bytes` in the buffer.
  def buffer_rows(bytes, on_disk: bytes)
    File.write("lib/a.rb", on_disk)
    File.write("buffer.rb", bytes)
    binding = Rigor::Analysis::BufferBinding.new(logical_path: "lib/a.rb", physical_path: File.expand_path("buffer.rb"))
    rows(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, buffer: binding))
  end

  before { FileUtils.mkdir_p("lib") }

  it "keeps the narrowing across a call to a callee another file declares" do
    File.write("lib/b.rb", "class Base\n  def log(message) = warn(message)\nend\n")
    expect(plain_rows(caller_source)).to eq([])
    expect(buffer_rows(caller_source)).to eq([])
  end

  # The positive control: the callee another file declares writes the variable, so both runs report.
  it "still reports when the callee another file declares writes the variable" do
    File.write("lib/b.rb", "class Base\n  def log(_message) = (@io = STDOUT)\nend\n")
    expect(plain_rows(caller_source).map(&:first)).to eq([10])
    expect(buffer_rows(caller_source)).to eq(plain_rows(caller_source))
  end

  # The buffer's file reaching discovery under another spelling than the binding's must still be read from the
  # buffer. On disk `log` writes `@io`; the buffer's `log` does not, so the narrowing holds in the buffer. Read from
  # disk under a second spelling, the file would be a second declarer of `Holder#log` and drop it.
  describe "with the buffer's file under another spelling" do
    let(:own_log) do
      caller_source.sub("class Holder < Base", "class Holder")
                   .sub("  def dump", "  def log(message) = warn(message)\n\n  def dump")
    end
    let(:writing_log) { own_log.sub("def log(message) = warn(message)", "def log(_message) = (@io = STDOUT)") }

    def run_with(logical, argument)
      File.write("buffer.rb", own_log)
      binding = Rigor::Analysis::BufferBinding.new(logical_path: logical, physical_path: File.expand_path("buffer.rb"))
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, buffer: binding)
      guarded_run(runner, [argument]).diagnostics.select { |d| d.path.end_with?("a.rb") }.map(&:rule)
    end

    before do
      File.write("lib/b.rb", "class Other\nend\n")
      File.write("lib/a.rb", writing_log)
    end

    it "reads it from the buffer when the argument and --instead-of are spelled differently" do
      expect(run_with(File.expand_path("lib/a.rb"), "lib/a.rb")).to eq([])
    end

    it "reads it from the buffer when it is reached through a symlinked root" do
      File.symlink(Dir.pwd, "link")
      linked = File.join(Dir.pwd, "link", "lib", "a.rb")
      expect(run_with(linked, linked)).to eq([])
    end

    # The positive control: the same runs report when the buffer's own `log` writes the variable.
    it "still reports when the buffer's own log writes the variable" do
      File.write("buffer.rb", writing_log)
      binding = Rigor::Analysis::BufferBinding.new(logical_path: File.expand_path("lib/a.rb"),
                                                   physical_path: File.expand_path("buffer.rb"))
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, buffer: binding)
      expect(guarded_run(runner, ["lib/a.rb"]).diagnostics.map(&:rule)).to include("call.undefined-method")
    end
  end
end
