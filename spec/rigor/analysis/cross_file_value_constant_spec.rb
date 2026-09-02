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

    it "DECLINES a boolean, so a cross-file feature flag does not warn at every guard that reads it" do
      # Publishing a boolean is pure cost: nothing dispatches on `true`, and a `Constant[false]` predicate
      # makes `flow.always-truthy-condition` fire on every `unless FLAG` in every OTHER file — a warning on
      # correct code, on the one idiom whose whole point is a constant that gets branched on.
      declaring = "ENABLED = false\n"
      reader = <<~RUBY
        def guard
          return "off" unless ENABLED

          "on"
        end
        Rigor.dump_type(ENABLED)
      RUBY
      expect(flow_warnings("b.rb" => declaring, "a.rb" => reader)).to eq([])
      expect(dumps("b.rb" => declaring, "a.rb" => reader)).to eq(["Dynamic[top]"])
    end

    it "still warns on a SAME-FILE boolean guard, where the author can see the declaration" do
      # The must-still-fire pairing for the decline above: the flow rule is untouched, and a decline that
      # silenced it everywhere would pass every other expectation in this file.
      source = <<~RUBY
        ENABLED = false

        def guard
          return "off" unless ENABLED

          "on"
        end
      RUBY
      expect(flow_warnings("b.rb" => source)).to eq(["b.rb:4"])
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
