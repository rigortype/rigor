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

  # The widened discovery reads the buffer's file through the binding: on disk `Holder` inherits from a class no file
  # declares, while the buffer makes it a `Base`.
  it "discovers the buffer's own file from the buffer's bytes" do
    File.write("lib/b.rb", "class Base\n  def log(message) = warn(message)\nend\n")
    expect(buffer_rows(caller_source, on_disk: caller_source.sub("< Base", "< Missing"))).to eq([])
  end
end
