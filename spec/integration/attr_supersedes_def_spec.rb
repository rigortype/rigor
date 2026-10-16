# frozen_string_literal: true

require "spec_helper"

# Issue #1989 — a definer that is not a `def` (`attr_*`, `define_method`, `alias_method` / `alias`) written after a
# `def` of the same name replaces that method, so its return type must not come from the `def` body. Ruby 4.0.5's
# value of `.x` is in each example's comment; every quiet example is a correct program, and the reported ones are
# the positive controls where the `def` still answers. An example marked "guard" passes without the fix too.
RSpec.describe "a later non-def definer supersedes an earlier def for typing (#1989)", type: :runner do
  def undefined(source = nil, files: {}, config: {})
    analyze(source, files: files, config: config).diagnostics.select { |d| d.rule == "call.undefined-method" }
                                                 .map do |d|
      [File.basename(d.path),
       d.line]
    end
  end

  # Ruby: "s".
  it "types the reader from the attr_reader that follows the def" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = 1
        attr_reader :x
        def initialize = (@x = "s")
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: 1.
  it "keeps typing from a def that follows the attr_reader (control)" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 6]])
      class K
        attr_reader :x
        def x = 1
        def initialize = (@x = "s")
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: "d".
  it "does not type from a def a later define_method replaces" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = 1
        define_method(:x) { "d" }
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: "y" for both. Guard: the alias pass already gave the new name the old name's `def`.
  it "does not type from a def a later alias_method or alias replaces" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def y = "y"
        def x = 1
        alias_method :x, :y
      end
      class L
        def y = "y"
        def x = 1
        alias x y
      end
      K.new.x.upcase
      L.new.x.upcase
    RUBY
  end

  # Ruby: "y" for both (the aliased name is an attr reader, so no `def` body answers it).
  it "does not type from a def an alias of an attr reader replaces" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        attr_reader :y
        def x = 1
        alias_method :x, :y
        def initialize = (@y = "y")
      end
      class L
        attr_reader :y
        def x = 1
        alias x y
        def initialize = (@y = "y")
      end
      K.new.x.upcase
      L.new.x.upcase
    RUBY
  end

  # Ruby: "s".
  it "types the reader from an attr_accessor that follows the def" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = 1
        attr_accessor :x
        def initialize = (@x = "s")
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: 1.
  it "keeps typing the reader from the def when only an attr_writer follows (control)" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 5]])
      class K
        def x = 1
        attr_writer :x
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: NoMethodError (private method) — the visibility lint reports it; the receiver is not typed from the def.
  it "supersedes the def with a wrapped private attr_reader, keeping it private" do
    result = analyze(<<~RUBY)
      class K
        def x = 1
        private attr_reader :x
        def initialize = (@x = "s")
      end
      K.new.x.upcase
    RUBY
    rules = result.diagnostics.map { |d| [d.line, d.rule] }
    expect(rules).to include([6, "def.method-visibility-mismatch"])
    expect(rules).not_to include([6, "call.undefined-method"])
  end

  # Ruby: 1 without X in the environment, "s" with it; neither answer is certain, so neither call reports. Guard: the
  # possible attr_reader already made the name possible.
  it "does not answer from the def under a conditional attr_reader" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = 1
        if ENV["X"] then attr_reader :x end
        def initialize = (@x = "s")
      end
      K.new.x.upcase
      K.new.x.even?
    RUBY
  end

  # Ruby: "s".
  it "supersedes the def from a reopening later in the same file" do
    expect(undefined(<<~RUBY)).to eq([])
      class K
        def x = 1
      end
      class K
        attr_reader :x
        def initialize = (@x = "s")
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: 2.
  it "types from the last def when a def follows the attr_reader again (control)" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 6]])
      class K
        def x = 1
        attr_reader :x
        def x = 2
      end
      K.new.x.upcase
    RUBY
  end

  # Ruby: public for each — a `define_method` or an alias replacing a private `def` gives the name the running
  # default's or the old name's visibility, so the visibility lint must not read the `def`'s.
  it "does not keep a replaced private def's visibility for define_method or an alias" do
    result = analyze(<<~RUBY)
      class K
        private def x = 1
        define_method(:x) { 1 }
      end
      class L
        private def x = 1
        def y = 1
        alias_method :x, :y
      end
      class M
        private def x = 1
        def y = 1
        alias x y
      end
      K.new.x
      L.new.x
      M.new.x
    RUBY
    expect(result.diagnostics.map(&:rule)).not_to include("def.method-visibility-mismatch")
  end

  # Ruby: NoMethodError for each — the replacing definer is on another object (`O`, or the singleton), so the
  # instance `def` still answers (controls).
  it "keeps the def when the replacing definer is on another receiver or the singleton side" do
    expect(undefined(<<~RUBY)).to eq([["code.rb", 19], ["code.rb", 20], ["code.rb", 21]])
      class O; end
      class K
        def x = 1
        O.define_method(:x) { "o" }
      end
      class S
        def x = 1
        class << self
          attr_reader :x
        end
      end
      class T
        def x = 1
        class << self
          def y = "y"
          alias x y
        end
      end
      K.new.x.upcase
      S.new.x.upcase
      T.new.x.upcase
    RUBY
  end

  # Ruby: "s", whichever file is loaded first.
  it "carries the superseded def to a caller in another file" do
    files = {
      "k.rb" => <<~RUBY,
        class K
          def x = 1
          attr_reader :x
          def initialize = (@x = "s")
        end
      RUBY
      "use.rb" => <<~RUBY
        K.new.x.upcase
        K.new.x.size
      RUBY
    }
    expect(undefined(files: files)).to eq([])
  end

  # Ruby: "S" twice — `b.rb` loads `a.rb` first, so its own `def` and then its attr_reader replace `a.rb`'s `def`.
  # The sibling file's `def` must not stand in for the one this file replaced.
  def sibling_files(plain, superseding, caller_line: "K.new.x.upcase\n",
                    require_line: "require_relative \"#{File.basename(plain, '.rb')}\"\n")
    {
      plain => "class K\n  def x = 1\nend\n",
      superseding => "#{require_line}class K\n  def x = \"t\"\n  attr_reader :x\n  " \
                     "def initialize = (@x = \"s\")\n  def shout = x.upcase\nend\n#{caller_line}"
    }
  end

  it "does not type from a sibling file's def the file's attr_reader replaced" do
    expect(undefined(files: sibling_files("a.rb", "b.rb"))).to eq([])
  end

  # The superseding file sorts first here, and the call is in that file. A call in a third file that sorts after
  # both still reads the other file's `def`: the project fold is later-wins by file order (pre-existing).
  it "does not type from a sibling file's def at a call in the superseding file when it sorts first" do
    expect(undefined(files: sibling_files("b.rb", "a.rb"))).to eq([])
  end

  it "does not type from a sibling file's def at a caller in a third file" do
    files = sibling_files("a.rb", "b.rb", caller_line: "").merge("c.rb" => "require_relative \"b\"\nK.new.x.upcase\n")
    expect(undefined(files: files)).to eq([])
  end

  it "does not type an implicit-self call in the body from a sibling file's def" do
    expect(undefined(files: sibling_files("a.rb", "b.rb", caller_line: ""))).to eq([])
  end

  # Ruby: "S" when `a.rb` loads first, 1 otherwise; the load order is unknown, so the call declines.
  it "does not type from a sibling file's def without require_relative" do
    expect(undefined(files: sibling_files("a.rb", "b.rb", require_line: ""))).to eq([])
  end

  it "does not type from a sibling file's def under the fork pool" do
    expect(undefined(files: sibling_files("a.rb", "b.rb"), config: { "workers" => 2 })).to eq([])
  end
end
