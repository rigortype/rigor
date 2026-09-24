# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

# A block passed to an Enumerable method on an `IO`, `File` or `StringIO` instance.
#
# `ClosureEscapeAnalyzer` classified only the streams' line iteration (`each_line`, `each`, …, `foreach`) as
# non-escaping, so `io.each_with_index { ... }` skipped the loop-body re-narrowing that `io.each_line { ... }`
# gets: a local written in one `case` arm read its pre-loop value in a sibling arm, a block-level `return`
# dropped out of the method's return summary, and the caller's guard false-fired
# `flow.always-truthy-condition` (the PR #193 pattern through another selector). The eager Enumerable methods
# now share `each`'s classification. The Enumerator-returning ones (`chunk`, `slice_when`, …) run their block
# only when the Enumerator is consumed, so they stay `:unknown`.
RSpec.describe "Enumerable blocks on IO / File / StringIO", type: :runner do
  def always_truthy_lines(source)
    Dir.mktmpdir("rigor-stream-enumerable-") do |tmpdir|
      FileUtils.mkdir_p(File.join(tmpdir, "lib"))
      File.write(File.join(tmpdir, "lib", "scan.rb"), source)
      Dir.chdir(tmpdir) do
        configuration = Rigor::Configuration.new("paths" => ["lib"])
        result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
        result.diagnostics.select { |d| d.rule == "flow.always-truthy-condition" }.map(&:line)
      end
    end
  end

  def line_of(source, fragment)
    source.lines.index { |line| line.include?(fragment) } + 1
  end

  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  let(:eager_source) do
    <<~RUBY
      # frozen_string_literal: true
      require "stringio"

      class Scan
        def string_io_hit?(text)
          flag = false
          StringIO.new(text).each_with_index do |line, _index|
            case line
            when /a/ then flag = true
            when /b/ then return true if flag
            end
          end
          false
        end

        def file_hit?(path)
          flag = false
          File.open(path) do |file|
            file.each_with_index do |line, _index|
              case line
              when /a/ then flag = true
              when /b/ then return true if flag
              end
            end
          end
          false
        end

        def never?(text)
          flag = false
          StringIO.new(text).each_with_index do |_line, _index|
            return true if flag
          end
          false
        end

        def guard(text, path)
          return [] unless string_io_hit?(text)
          return [] unless file_hit?(path)
          return [] unless never?(text)

          [1]
        end
      end
    RUBY
  end

  let(:deferred_source) do
    <<~RUBY
      # frozen_string_literal: true
      require "stringio"

      class Lazy
        def file_hit?(path)
          armed = false
          hit = false
          groups = File.new(path).chunk { |_line| hit = armed }
          armed = true
          groups.to_a
          hit
        end

        def io_hit?(text)
          armed = false
          hit = false
          groups = StringIO.new(text).slice_when { |_a, _b| hit = armed }
          armed = true
          groups.to_a
          hit
        end

        def guard(path, text)
          return :file unless file_hit?(path)
          return :io unless io_hit?(text)

          :ok
        end
      end
    RUBY
  end

  # `never?` is the positive control: its guard really is always falsey, so the rule must still fire there on
  # the same receiver.
  it "re-narrows the loop body of each_with_index on a StringIO and a File" do
    expect(always_truthy_lines(eager_source)).to eq([line_of(eager_source, "unless never?")])
  end

  # The block runs when `to_a` consumes the Enumerator, after `armed` has changed, so `hit` is `true` at
  # runtime. Reading the block as if it ran inside `chunk` / `slice_when` would fold both guards to falsey.
  it "does not read a chunk or slice_when block as if it ran during the call" do
    expect(always_truthy_lines(deferred_source)).to be_empty
  end

  # A local the block writes now keeps its joined type after the call, exactly as after `each_line`, instead of
  # losing it — so a nil-receiver diagnostic can newly (and correctly) follow on an empty stream.
  it "types a local written in the block as each_line does" do
    types = dumped_types(<<~RUBY)
      require "stringio"
      io = StringIO.new(ARGV.first.to_s)
      header = nil
      io.each_with_index { |line, i| header = line if i.zero? }
      dump_type(header)
      first = nil
      io.each_line { |line| first ||= line }
      dump_type(first)
    RUBY

    expect(types).to eq(["String?", "String?"])
  end
end
