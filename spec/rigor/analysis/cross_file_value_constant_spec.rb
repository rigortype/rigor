# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #644 — a plain VALUE constant assigned in one file must type in another.
#
# `Scope#in_source_constants` is per-file and was never part of the project seed, so only class-shaped
# constants (a `class` / `module`, and the constant-assigned `Data.define` / `Struct.new` forms that register
# in the discovery pre-pass's class sources) crossed a file boundary; `FOO = :sym` read as `Dynamic[top]`
# everywhere else.
#
# Every positive assertion here is paired with the negative that discriminates it, because the whole design
# is a set of DECLINE rules — a spec that only checked "this one publishes" would pass with a rule that
# published everything, which is the false-positive direction this feature spends its budget avoiding.
RSpec.describe "cross-file value constants" do
  # Runs a project of `files` (name => source) and returns the `dump.type` messages in source order.
  def dumps(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      result = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]), cache_store: nil
      ).run
      result.diagnostics
            .select { |d| d.qualified_rule == "dump.type" }
            .sort_by { |d| [d.path, d.line] }
            .map { |d| d.message.delete_prefix("dump_type: ") }
    end
  end

  # The `flow.always-truthy-condition` sites, as `basename:line` — the rule a value-pinned constant can make
  # fire at a reader that was previously silent.
  def flow_warnings(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      result = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]), cache_store: nil
      ).run
      result.diagnostics
            .select { |d| d.qualified_rule == "flow.always-truthy-condition" }
            .map { |d| "#{File.basename(d.path)}:#{d.line}" }
            .sort
    end
  end

  describe "the issue's two repros" do
    it "types a bare `FOO = :sym` declared in a sibling file" do
      expect(dumps("b.rb" => "FOO = :sym\n",
                   "a.rb" => "Rigor.dump_type(FOO)\n")).to eq([":sym"])
    end

    it "types `Rails::LOG_LEVEL` from a `module Rails` in a sibling file" do
      expect(dumps("b.rb" => "module Rails\n  LOG_LEVEL = :debug\nend\n",
                   "a.rb" => "Rigor.dump_type(Rails::LOG_LEVEL)\n")).to eq([":debug"])
    end

    it "types the configuration-in-constants case the issue names (`DEFAULT_LIMIT = 50`)" do
      expect(dumps("b.rb" => "DEFAULT_LIMIT = 50\n",
                   "a.rb" => "Rigor.dump_type(DEFAULT_LIMIT)\n")).to eq(["50"])
    end
  end

  describe "the publishable literal kinds" do
    it "publishes each frozen scalar literal by value" do
      declaring = <<~RUBY
        SYM = :s
        INT = 7
        FLT = 0.5
      RUBY
      reader = <<~RUBY
        Rigor.dump_type(SYM)
        Rigor.dump_type(INT)
        Rigor.dump_type(FLT)
      RUBY
      expect(dumps("b.rb" => declaring, "a.rb" => reader)).to eq([":s", "7", "0.5"])
    end

    it "publishes a boolean, and withholds the truthiness warning its readers would otherwise get" do
      # A boolean IS published — the value is real and dispatch may use it. What it must not do is fuel
      # `flow.always-truthy-condition` at a reader whose author never opened the declaration: a feature flag
      # read in ten files would put the warning in all ten. `PublishedConstantGuard` withholds the firing
      # without withdrawing the value, which is the ADR-58 carrier discipline ("a consumer may only ever
      # withhold a firing").
      declaring = "ENABLED = false\n"
      reader = <<~RUBY
        def guard
          return "off" unless ENABLED

          "on"
        end
        Rigor.dump_type(ENABLED)
      RUBY
      expect(dumps("b.rb" => declaring, "a.rb" => reader)).to eq(["false"])
      expect(flow_warnings("b.rb" => declaring, "a.rb" => reader)).to eq([])
    end

    it "DECLINES the mutable and placeholder rvalues, which stay `Dynamic[top]`" do
      # The must-not-fire half. A String / Array / Hash literal is mutable (a sibling file's `NAME << "x"` or
      # `LIST.push` moves the value a published type would pin, and only the DECLARING file's mutation census
      # can see that), the composite two additionally carry the HashShape / Tuple hazard, and `nil` at
      # declaration position is a placeholder far more often than a genuine `NilClass`.
      declaring = <<~RUBY
        NAME = "hello"
        LIST = [1, 2]
        CONF = { a: 1 }
        LATER = nil
        COMPUTED = ENV.fetch("X", nil)
      RUBY
      reader = <<~RUBY
        Rigor.dump_type(NAME)
        Rigor.dump_type(LIST)
        Rigor.dump_type(CONF)
        Rigor.dump_type(LATER)
        Rigor.dump_type(COMPUTED)
      RUBY
      expect(dumps("b.rb" => declaring, "a.rb" => reader)).to eq(["Dynamic[top]"] * 5)
    end

    it "leaves the DECLARING file's own reading untouched — same-file stays value-pinned" do
      # The must-still-succeed pairing for the declines above: a rule that dropped these names from the
      # per-file table too would satisfy every cross-file expectation in this file and break real typing.
      declaring = <<~RUBY
        NAME = "hello"
        LIST = [1, 2]
        Rigor.dump_type(NAME)
        Rigor.dump_type(LIST)
      RUBY
      expect(dumps("b.rb" => declaring)).to eq(['"hello"', "[1, 2]"])
    end
  end

  describe "reassignment" do
    it "keeps a constant two files both assign gradual, and its single-file sibling precise" do
      files = {
        "b.rb" => "DUP = :first\nONLY = :kept\n",
        "c.rb" => "DUP = :second\n",
        "a.rb" => "Rigor.dump_type(DUP)\nRigor.dump_type(ONLY)\n"
      }
      # `ONLY` is the must-still-succeed pairing: it proves the `DUP` decline is the cross-file conflict rule
      # and not the whole table failing to publish in a three-file project.
      expect(dumps(files)).to eq(["Dynamic[top]", ":kept"])
    end

    it "keeps a constant assigned twice in ONE file gradual" do
      files = {
        "b.rb" => "TWICE = :one\nTWICE = :two\nONLY = :kept\n",
        "a.rb" => "Rigor.dump_type(TWICE)\nRigor.dump_type(ONLY)\n"
      }
      expect(dumps(files)).to eq(["Dynamic[top]", ":kept"])
    end

    it "keeps a constant gradual when the SECOND file's rvalue is unfoldable" do
      # The write attribution is collected over every assignment, not only the publishable ones, precisely so
      # an unfoldable write suppresses a foldable one. Without that, `LEVEL` would publish `:debug` while the
      # program actually runs whatever `c.rb` computed.
      files = {
        "b.rb" => "LEVEL = :debug\n",
        "c.rb" => "LEVEL = ENV.fetch(\"LEVEL\", nil)\n",
        "a.rb" => "Rigor.dump_type(LEVEL)\n"
      }
      expect(dumps(files)).to eq(["Dynamic[top]"])
    end
  end

  describe "the truthiness family (PublishedConstantGuard)" do
    let(:config) { "module AppConfig\n  MODE = :production\n  PAGE = 25\nend\nENV_NAME = :development\n" }

    it "withholds every shape whose constancy rests on a constant declared in another file" do
      reader = <<~RUBY
        def production?
          AppConfig::MODE == :production
        end

        def banner
          AppConfig::MODE == :production ? "prod" : "other"
        end

        def paged
          raise "too big" if AppConfig::PAGE > 100

          AppConfig::PAGE
        end

        def present
          return "none" unless AppConfig::PAGE

          "some"
        end

        def local_env?
          %i[development test].include?(ENV_NAME) ? "local" : "remote"
        end

        def maybe_skip
          return "skip" unless production?

          "run"
        end
      RUBY
      # Receiver, argument, bare-predicate and ONE interprocedural hop (`production?`), all withheld.
      expect(flow_warnings("b.rb" => config, "a.rb" => reader)).to eq([])
    end

    it "keeps firing when the constant is declared in the reader's OWN file" do
      # The must-still-fire pairing: the guard turns on "another file", not on "a constant". A gate that
      # silenced the rule outright would satisfy every expectation above and destroy a real rule.
      source = <<~RUBY
        LOCAL_MODE = :production
        LOCAL_FLAG = false

        def compare
          LOCAL_MODE == :production ? "prod" : "other"
        end

        def guard
          return "off" unless LOCAL_FLAG

          "on"
        end
      RUBY
      expect(flow_warnings("b.rb" => source)).to eq(["b.rb:5", "b.rb:9"])
    end

    it "keeps firing on a constant-free predicate in a project that publishes constants" do
      # The second must-still-fire: the rule is untouched for everything that is not constant-rooted, even
      # in a file whose project seeds a published table.
      reader = <<~RUBY
        def plain
          x = 1
          x ? "always" : "never"
        end

        def flagged
          flag = false
          return "off" unless flag

          "on"
        end
      RUBY
      expect(flow_warnings("b.rb" => config, "a.rb" => reader)).to eq(["a.rb:3", "a.rb:8"])
    end
  end

  describe "write forms the conflict rule must see" do
    # Each of these is a SECOND assignment to a name another file publishes. If the census cannot see the
    # form, the name publishes a value the program does not have — the conflict rule bypassed rather than a
    # precision loss. `KEPT` is the must-still-publish control in every case: it proves the `Dynamic[top]`
    # is this rule and not the whole table failing.
    def duel(second_writer)
      dumps("b.rb" => "LIMIT = 50\nKEPT = :kept\n",
            "c.rb" => second_writer,
            "a.rb" => "Rigor.dump_type(LIMIT)\nRigor.dump_type(KEPT)\n")
    end

    it "sees `self::LIMIT =` inside the namespace it targets" do
      expect(dumps("b.rb" => "module N\n  LIMIT = 50\nend\nKEPT = :kept\n",
                   "c.rb" => "module N\n  self::LIMIT = 7\nend\n",
                   "a.rb" => "Rigor.dump_type(N::LIMIT)\nRigor.dump_type(KEPT)\n"))
        .to eq(["Dynamic[top]", ":kept"])
    end

    it "sees a constant target under a multiple assignment" do
      expect(duel("LIMIT, OTHER = 7, 8\n")).to eq(["Dynamic[top]", ":kept"])
    end

    it "sees the inner write of an assignment chain" do
      expect(duel("OUTER = LIMIT = 7\n")).to eq(["Dynamic[top]", ":kept"])
    end

    it "sees an operator / `||=` / `&&=` constant write" do
      expect(duel("LIMIT += 1\n")).to eq(["Dynamic[top]", ":kept"])
      expect(duel("LIMIT ||= 7\n")).to eq(["Dynamic[top]", ":kept"])
      expect(duel("LIMIT &&= 7\n")).to eq(["Dynamic[top]", ":kept"])
    end
  end

  describe "lexical resolution" do
    it "does not let a top-level constant answer a nested read that has its own" do
      files = {
        "b.rb" => "KEY = :top\nmodule Inner\n  KEY = :nested\nend\n",
        "a.rb" => "module Inner\n  Rigor.dump_type(KEY)\nend\nRigor.dump_type(KEY)\n"
      }
      expect(dumps(files)).to eq([":nested", ":top"])
    end
  end
end
