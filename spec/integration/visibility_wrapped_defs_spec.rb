# frozen_string_literal: true

require "spec_helper"

# Issues #1911, #1819, #1633 — the visibility lints read a `def` or `attr_*` wrapped in a visibility call with that
# call's visibility. Ruby 4.0.5's answer for each shape is in the comment; the reported shapes are true positives
# (Ruby raises NoMethodError on the call), the quiet ones are correct programs.
RSpec.describe "visibility lints over wrapped defs and attrs (#1911, #1819, #1633)", type: :runner do
  def rules(source = nil, files: {})
    lints = %w[def.method-visibility-mismatch def.override-visibility-reduced]
    analyze(source, files: files).diagnostics.select { |d| lints.include?(d.rule) }
                                 .map { |d| [File.basename(d.path), d.line, d.rule] }
  end

  def mismatch(line, path = "code.rb") = [path, line, "def.method-visibility-mismatch"]

  it "reports a call to a wrapped private def, endless or not, and not to the def after it (#1911, #1819)" do
    expect(rules(<<~RUBY)).to eq([mismatch(7), mismatch(8)])
      class Vault
        private def kp; end
        private def secret = 1
        def open = 2
      end

      Vault.new.kp
      Vault.new.secret
      Vault.new.open
    RUBY
  end

  # Ruby: `w=` and `x` are private, `r` protected (a protected call from outside raises too, but the rule
  # reports only private, as it does for a protected def).
  it "reports a call to a private attr member (#1911)" do
    expect(rules(<<~RUBY)).to eq([mismatch(10), mismatch(11)])
      class Box
        protected attr_reader :r
        private attr_accessor :x

        private

        attr_writer :w
      end

      Box.new.w = 1
      Box.new.x
      Box.new.r
    RUBY
  end

  # Ruby: `foo` is public.
  it "is quiet on `public def` under a bare `private`, and still reports the def after it (#1633)" do
    expect(rules(<<~RUBY)).to eq([mismatch(8)])
      class K
        private
        public def foo = 1
        def bar = 1
      end

      K.new.foo
      K.new.bar
    RUBY
  end

  # Ruby: `Base#foo` is private, so `Sub#foo` reduces nothing.
  it "does not report a private override of a wrapped private def (#1633)" do
    expect(rules(<<~RUBY)).to eq([])
      class Base
        private def foo = 1
      end

      class Sub < Base
        private

        def foo = 2
      end
    RUBY
  end

  it "reports a wrapped private override of a public def (control)" do
    expect(rules(<<~RUBY)).to eq([["code.rb", 6, "def.override-visibility-reduced"]])
      class Base
        def foo = 1
      end

      class Sub < Base
        private def foo = 2
      end
    RUBY
  end

  # Ruby: the condition is false, so `K#x` is the public first def; `public(*[])` is a bare `public`, so `L#a` is
  # public. The walk records each private and contested, so neither is reported.
  it "is quiet on a conditional wrapped def and after a splatted toggle" do
    expect(rules(<<~RUBY)).to eq([])
      class K
        def x = 1
        private def x = 2 if RUBY_VERSION < "3"
      end

      class L
        private

        public(*[])
        def a = 1
      end

      K.new.x
      L.new.a
    RUBY
  end

  it "reads each file's running default for a class reopened in another file" do
    files = {
      "a.rb" => "class R\n  private\n\n  def a = 1\nend\n",
      "b.rb" => "class R\n  def b = 1\n  private def c = 1\nend\n",
      "use.rb" => "R.new.a\nR.new.b\nR.new.c\n"
    }
    expect(rules(files: files)).to eq([mismatch(1, "use.rb"), mismatch(3, "use.rb")])
  end
end
