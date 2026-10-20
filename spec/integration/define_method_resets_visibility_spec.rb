# frozen_string_literal: true

require "spec_helper"

# Issue #2013 — a `define_method(:x)` or an alias of `x` written after a private `def x` gives `x` the running
# default's or the old name's visibility, which the visibility walk does not read. The override rule must not read
# the replaced `def`'s visibility, and across files, where file order is not load order, the visibility lint must
# decline. Ruby 4.0.5's answer is in each example's comment; "control" examples still report.
RSpec.describe "a later define_method or alias resets a private def's visibility (#2013)", type: :runner do
  def reported(source = nil, files: {})
    rules = %w[def.override-visibility-reduced def.method-visibility-mismatch]
    analyze(source, files: files).diagnostics.select { |d| rules.include?(d.rule) }
                                 .map { |d| [File.basename(d.path), d.line, d.rule] }
  end

  def parent = "class P\n  def x = 1\nend\n"

  # Ruby: K.new.x is 3, 3 and 3 (public).
  it "does not report a reduced override that a later define_method, alias_method or alias replaces" do
    expect(reported(<<~RUBY)).to eq([])
      #{parent}
      class K < P
        private def x = 2
        define_method(:x) { 3 }
      end
      class L < P
        def y = 3
        private def x = 2
        alias_method :x, :y
      end
      class M < P
        def y = 3
        private def x = 2
        alias x y
      end
    RUBY
  end

  # Ruby: public with X in the environment, private without; neither answer is certain.
  it "does not report a reduced override under a conditional define_method" do
    expect(reported(<<~RUBY)).to eq([])
      #{parent}
      class K < P
        private def x = 2
        define_method(:x) { 3 } if ENV["X"]
      end
    RUBY
  end

  # Ruby: NoMethodError (private) for both (control).
  it "still reports a reduced override with no later definer, or one a later private :x settles" do
    expected = [["code.rb", 6, "def.override-visibility-reduced"], ["code.rb", 9, "def.override-visibility-reduced"]]
    expect(reported(<<~RUBY)).to eq(expected)
      #{parent}
      class K < P
        private def x = 2
      end
      class L < P
        private def x = 2
        define_method(:x) { 3 }
        private :x
      end
    RUBY
  end

  # Ruby: 3 whichever file loads last is public; the files leave it to load order, so the rule declines.
  it "does not report a reduced override when a sibling file's define_method replaces it, either file order" do
    %w[a.rb b.rb].permutation.each do |private_file, define_file|
      files = { "p.rb" => parent,
                private_file => "class K < P\n  private def x = 2\nend\n",
                define_file => "class K < P\n  define_method(:x) { 3 }\nend\n" }
      expect(reported(files: files)).to eq([])
    end
  end

  def private_def = "class K\n  def y = 2\n  private def x = 1\nend\n"

  # Ruby: 1 or NoMethodError depending on load order; the rule declines, either file order.
  it "does not report a private call when a sibling file's define_method may make the name public" do
    %w[a.rb b.rb].permutation.each do |private_file, define_file|
      files = { private_file => private_def, define_file => "class K\n  define_method(:x) { 1 }\nend\n",
                "use.rb" => "def t = K.new.x\n" }
      expect(reported(files: files)).to eq([])
    end
  end

  # Ruby: 2 or NoMethodError depending on load order; the rule declines, either file order and alias spelling.
  it "does not report a private call when a sibling file's alias may make the name public" do
    ["alias_method :x, :y", "alias x y"].product(%w[a.rb b.rb].permutation.to_a).each do |line, (private_file, other)|
      files = { private_file => private_def, other => "class K\n  #{line}\nend\n", "use.rb" => "def t = K.new.x\n" }
      expect(reported(files: files)).to eq([])
    end
  end

  # The call sits in the file holding the private def, whose own write folds over the sibling's contest.
  it "does not report a private call in the private def's own file when a sibling's define_method replaces it" do
    %w[a.rb b.rb].permutation.each do |private_file, define_file|
      files = { private_file => "#{private_def}def t = K.new.x\n",
                define_file => "class K\n  define_method(:x) { 1 }\nend\n" }
      expect(reported(files: files)).to eq([])
    end
  end

  # Ruby: NoMethodError (control) — the sibling's define_method is followed by a private :x, and a define_method on
  # another class replaces nothing of K's.
  it "still reports a private call when the sibling settles the name private or replaces another class's method" do
    files = { "a.rb" => private_def, "b.rb" => "class K\n  define_method(:x) { 1 }\n  private :x\nend\n",
              "c.rb" => "class L\n  define_method(:x) { 1 }\nend\n", "use.rb" => "def t = K.new.x\n" }
    expect(reported(files: files)).to eq([["use.rb", 1, "def.method-visibility-mismatch"]])
  end
end
