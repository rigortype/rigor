# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

# #1363 — which global-variable spellings the scan colours `global.*`.
#
# `$~` and `$_` are frame-local: Ruby keeps them in the special-variable slot of the body that runs them, which that
# body and the blocks it creates reach and no other method's frame does. A read of one is not `global.read`, and a
# write binds only that slot, so it earns no label, as a local-variable write earns none. `$!` and `$@` are the
# exception being rescued and its backtrace: no callee can make `$!` name another exception for its caller, so a read
# of either is not `global.read`, but `$@ = bt` sets that exception's backtrace, which the rescuing frame holds, so it
# stays `global.write`. `$?` is the thread's, and a subprocess a callee runs sets it, so a read stays `global.read`.
# The spec is `docs/internal-spec/effect-summaries.md` § The special variables.
RSpec.describe "effect labels for the special global variables" do
  def configuration
    data = { "paths" => ["lib"], "parallel" => { "workers" => 0 }, "effects" => {} }
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data))
  end

  let(:table) do
    Dir.mktmpdir("rigor-special-globals-") do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("lib")
        File.write("lib/specials.rb", <<~RUBY)
          class Specials
            def match_info = $~
            def last_line = $_
            def rescued = $!
            def rescued_backtrace = $@
            def last_status = $?
            def stream = $stdout

            def write_line = ($_ = "x")
            def clear_match = ($~ = nil)
            def or_write_line = ($_ ||= "x")
            def and_write_match = ($~ &&= nil)
            def append_line = ($_ += "x")

            def multi_write_line
              $_, rest = "x", 1
              rest
            end

            def nested_multi_write_match
              (rest, $~), other = [1, nil], 2
              [rest, other]
            end

            def write_global = ($counter = 1)
            def or_write_global = ($counter ||= 1)

            def multi_write_global
              $counter, rest = 1, 2
              rest
            end

            def set_rescued_backtrace = ($@ = ["x:1"])
          end
        RUBY

        runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
        guarded_run(runner, ["lib"])
        runner.effect_table
      end
    end
  end

  def proven(name)
    table["Specials##{name}"].proven.to_a
  end

  describe "reads" do
    it "does not colour a read of the frame-local `$~` or `$_`" do
      expect(proven("match_info")).to eq([])
      expect(proven("last_line")).to eq([])
    end

    it "does not colour a read of the rescued exception `$!` or its backtrace `$@`" do
      expect(proven("rescued")).to eq([])
      expect(proven("rescued_backtrace")).to eq([])
    end

    it "keeps a read of the thread's `$?` as global.read" do
      expect(proven("last_status")).to eq(["global.read"])
    end

    it "keeps a read of an ordinary global as global.read" do
      expect(proven("stream")).to eq(["global.read"])
    end
  end

  describe "writes" do
    it "does not colour a plain write to `$_` or `$~`" do
      expect(proven("write_line")).to eq([])
      expect(proven("clear_match")).to eq([])
    end

    it "does not colour an or-write, and-write or operator write to one" do
      expect(proven("or_write_line")).to eq([])
      expect(proven("and_write_match")).to eq([])
      expect(proven("append_line")).to eq([])
    end

    it "does not colour one as a multiple-assignment target, nested or not" do
      expect(proven("multi_write_line")).to eq([])
      expect(proven("nested_multi_write_match")).to eq([])
    end

    it "keeps a write to an ordinary global as global.write, in every form" do
      expect(proven("write_global")).to eq(["global.write"])
      expect(proven("or_write_global")).to eq(["global.write"])
      expect(proven("multi_write_global")).to eq(["global.write"])
    end

    # The rescuing frame holds the exception `$@` names, often a caller's (`rescue => e` sees the new backtrace), so
    # the write reaches another frame.
    it "keeps a write to `$@` as global.write" do
      expect(proven("set_rescued_backtrace")).to eq(["global.write"])
    end
  end
end
