# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #618 — `ExpressionTyper#try_local_def_dispatch` bound a same-named top-level `def` for EVERY
# implicit-self call, ahead of the receiver class's own methods and whatever `scope.self_type` said. A
# top-level `def` is a private method on `Object`, the last link of every MRO, so a class that carries the
# name wins at runtime and the top-level body is never reached; binding it first inverted that. The issue's
# repro is a struct member — a top-level `def text` typed the `text` inside
# `class Line < Struct.new(:text); def shout; text.upcase; end; end` as the def's `nil` and fired
# `undefined method 'upcase' for nil` on correct Ruby — but the inversion covered every source of a method
# name: `attr_reader`, an inherited `def`, an included module's `def`, an RBS declaration on the class.
#
# The veto is `ExpressionTyper#self_type_answers?`, and it is scoped to a `self` whose class is KNOWN. At
# genuine top level, and inside a block whose `self` is unmodelled, `scope.self_type` is nil and the
# historical binding stands untouched — #316's / #319's territory, pinned by the must-still-bind half below
# and by spec/rigor/analysis/toplevel_def_dsl_block_capture_spec.rb.
RSpec.describe "a class's own method beats a top-level def of the same name" do
  def diagnostics_for(files, signatures: {})
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new(config_for(dir, lib, signatures)),
        cache_store: nil
      ).run.diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def config_for(dir, lib, signatures)
    return { "paths" => [lib] } if signatures.empty?

    sig = File.join(dir, "sig")
    FileUtils.mkdir_p(sig)
    signatures.each { |name, source| File.write(File.join(sig, name), source) }
    { "paths" => [lib], "signature_paths" => [sig] }
  end

  def messages_for(...) = diagnostics_for(...).map(&:message)

  # The shadowing top-level def, in its own file so nothing about the repro depends on collocation.
  def shadow_source = <<~RUBY
    def text
      nil
    end
  RUBY

  def upcase_errors(source, signatures: {})
    messages_for({ "shadow.rb" => shadow_source, "subject.rb" => source }, signatures: signatures)
      .grep(/upcase/)
  end

  # --- the member / own-method wins (the issue's false positives) -------------------------------------

  it "reads a struct member declared by the `class X < Struct.new(...)` spelling" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Line < Struct.new(:text)
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a struct member declared by the constant spelling and reopened" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Point = Struct.new(:text)

      class Point
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a Data member declared by the constant spelling and reopened" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      Pt = Data.define(:text)

      class Pt
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads an attr_reader declared in a plain class" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Plain
        attr_reader :text

        def initialize(value)
          @text = value
        end

        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method inherited from a project superclass" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class Base
        def text
          "base"
        end
      end

      class Derived < Base
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method contributed by an included module" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      module Textual
        def text
          "mixin"
        end
      end

      class Mixed
        include Textual

        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a method the project's own RBS declares on the class" do
    signatures = { "widget.rbs" => <<~RBS }
      class Widget
        def text: () -> String
      end
    RBS

    expect(upcase_errors(<<~RUBY, signatures: signatures)).to be_empty
      class Widget
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "reads a class method from the class body's own singleton self" do
    expect(upcase_errors(<<~RUBY)).to be_empty
      class ClassSide
        def self.text
          "cls"
        end

        SHOUTED = text.upcase
      end
    RUBY
  end

  # --- must still bind: the top-level def is still the answer where nothing else defines the name --------
  #
  # Each of these is the paired positive of the silences above: the same top-level `def text` returning nil,
  # the same `.upcase` on it, and the diagnostic still fires — so none of the examples above can pass on a
  # build that merely stopped binding top-level defs (or stopped analyzing) altogether.

  it "still binds a top-level def inside a class that does not define the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Consumer
        def shout
          text.upcase
        end
      end
    RUBY
  end

  it "still binds a top-level def in a class BODY whose class does not define the name" do
    expect(upcase_errors(<<~RUBY)).not_to be_empty
      class Consumer
        SHOUTED = text.upcase
      end
    RUBY
  end

  it "still binds a top-level def collocated with its DSL-block call site" do
    collocated = <<~RUBY
      def text
        nil
      end

      RSpec.describe "y" do
        it "uses it" do
          text.upcase
        end
      end
    RUBY

    expect(messages_for({ "same.rb" => collocated }).grep(/upcase/)).not_to be_empty
  end

  it "still binds a top-level def called from genuine top-level code" do
    expect(upcase_errors("text.upcase\n")).not_to be_empty
  end

  # The RBS veto is own-class only, and this is what buys that restriction: an inherited-declaration test
  # would match every name on `Object` / `Kernel` / `Enumerable` and retract the binding v0.0.3 A exists for
  # (a helper `def select(...)` re-routed straight back through `Enumerable#select`). `Widget` is RBS-known
  # but declares nothing of its own, so `inspect` resolves only through `Object` — where the RBS return is
  # `String`, which is what makes this a discriminating assertion rather than a silence: a veto that counted
  # the ancestor would answer `String` and the `upcase` error would vanish.
  it "does not treat an ancestor's RBS declaration as the class's own" do
    signatures = { "widget.rbs" => <<~RBS }
      class Widget
      end
    RBS

    files = { "shadow.rb" => <<~SHADOW, "subject.rb" => <<~SUBJECT }
      def inspect
        nil
      end
    SHADOW
      class Widget
        def shout
          inspect.upcase
        end
      end
    SUBJECT

    expect(messages_for(files, signatures: signatures).grep(/upcase/)).not_to be_empty
  end
end
