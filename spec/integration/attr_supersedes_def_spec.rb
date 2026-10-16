# frozen_string_literal: true

require "spec_helper"

# Issue #1989 — a definer that is not a `def` (`attr_*`, `define_method`, `alias_method` / `alias`) written after a
# `def` of the same name replaces that method, so its return type must not come from the `def` body. Ruby 4.0.5's
# value of `.x` is in each example's comment; every quiet example is a correct program, and the reported ones are
# the positive controls where the `def` still answers.
RSpec.describe "a later non-def definer supersedes an earlier def for typing (#1989)", type: :runner do
  def undefined(source = nil, files: {})
    analyze(source, files: files).diagnostics.select { |d| d.rule == "call.undefined-method" }
                                 .map { |d| [File.basename(d.path), d.line] }
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

  # Ruby: "y" for both.
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

  # Ruby: 1 without X in the environment, "s" with it; neither answer is certain, so neither call reports.
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
end
