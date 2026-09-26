# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"

# #1363 — which global-variable spellings the scan colours `global.*`.
#
# `$~` and `$_` are frame-local: Ruby keeps them in the special-variable slot of the body that runs them, and a call
# into a method defined with `def` has a slot of its own. A read of one is not `global.read`, and a write binds only
# that slot, so it earns no label, as a local-variable write earns none — except in a `define_method` body, which runs
# on the slot of the body that defined it, shared with every sibling defined there, so a write stays `global.write`.
# `$!` is the exception of the dynamically enclosing rescue clause, an implicit argument of the running call rather
# than program state, so a read is not `global.read`; a `$@` read reads its backtrace as `e.backtrace` would, and an
# object-state read is never labelled. `$@ = bt` changes that object, which the rescuing frame observes, so it stays
# `global.write`. `$?` is the thread's, and a subprocess a callee runs sets it, so a read stays `global.read`. The
# spec is `docs/internal-spec/effect-summaries.md` § The special variables.
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

            def for_line
              for $_ in ["x"]; end
            end

            def rescue_into_line
              begin
                nil
              rescue => $_
                nil
              end
            end

            def write_global = ($counter = 1)
            def or_write_global = ($counter ||= 1)

            def multi_write_global
              $counter, rest = 1, 2
              rest
            end

            def for_global
              for $counter in [1]; end
            end

            def rescue_into_global
              begin
                nil
              rescue => $counter
                nil
              end
            end

            def set_rescued_backtrace = ($@ = ["x:1"])

            # A `define_method` block runs on this class body's slot, so these share one `$_` and one `$~`.
            define_method(:set_shared_line) { |line| $_ = line }
            define_method(:clear_shared_match) { $~ = nil }
            define_method(:or_write_shared_line) { $_ ||= "x" }
            define_method(:read_shared_line) { $_ }

            def self.define_nested
              define_method(:nested_set_shared_line) { |line| $_ = line }
              def nested_write_line = ($_ = "x")
            end
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

    it "does not colour one as a `for` or `rescue =>` target" do
      expect(proven("for_line")).to eq([])
      expect(proven("rescue_into_line")).to eq([])
    end

    it "keeps a write to an ordinary global as global.write, in every form" do
      expect(proven("write_global")).to eq(["global.write"])
      expect(proven("or_write_global")).to eq(["global.write"])
      expect(proven("multi_write_global")).to eq(["global.write"])
      expect(proven("for_global")).to eq(["global.write"])
      expect(proven("rescue_into_global")).to eq(["global.write"])
    end

    # The rescuing frame holds the exception `$@` names, often a caller's (`rescue => e` sees the new backtrace), so
    # the write reaches another frame.
    it "keeps a write to `$@` as global.write" do
      expect(proven("set_rescued_backtrace")).to eq(["global.write"])
    end
  end

  # `define_method(:set) { |v| $_ = v }` and `define_method(:get) { $_ }` in one class body: after `set("shared")`,
  # `get` answers `"shared"`, so a `%a{pure}` on `set` is a claim the write breaks.
  describe "in a define_method body, which shares the defining body's slot" do
    it "keeps a write to `$_` or `$~` as global.write, in every form" do
      expect(proven("set_shared_line")).to eq(["global.write"])
      expect(proven("clear_shared_match")).to eq(["global.write"])
      expect(proven("or_write_shared_line")).to eq(["global.write"])
    end

    it "keeps it for a define_method a method body runs, and not for a def nested there" do
      expect(proven("nested_set_shared_line")).to eq(["global.write"])
      expect(proven("nested_write_line")).to eq([])
    end

    # Most such reads are of a match the same body just ran, which the scan cannot tell from a sibling's write.
    it "still does not colour a read" do
      expect(proven("read_shared_line")).to eq([])
    end
  end
end
